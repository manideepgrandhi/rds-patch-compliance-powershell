# src/Data.ps1 - -SaveData (collection side) and -Merge (offline). Port of save_data, merge_files,
# check_data_file, merge_main and lib/merge.jq. The data file format is IDENTICAL to the Bash tool
# (schema "rds_patch_compliance_data" version 1, minor 1), so files move freely in both directions:
# Bash-saved files merge here, PowerShell-saved files merge in Bash.

$script:DataSchema = 'rds_patch_compliance_data'
$script:DataSchemaVersion = 1

# ---------------------------------------------------------------------------------------------- save
# Save-PcrData (Bash save_data): raw rows (before display filters) per account, or all accounts in one FILE
function Save-PcrData {
    param($Raw)
    $O = $script:O; $now = $script:Run.Now
    $off = Get-PcrTzOffset $O.Tz $now; $abbr = Get-PcrTzAbbr $O.Tz $now
    $utc = Format-PcrEpoch $now "yyyy-MM-dd'T'HH:mm:ss'Z'"; $day = Format-PcrEpoch $now 'yyyyMMdd'
    if ($O.SaveDataFile) { Save-PcrDataFile $Raw $O.SaveDataFile '' $off $abbr $utc; return }
    foreach ($a in @($Raw['meta']['accounts'])) {
        $id = [string]$a['account']
        if ($id -notmatch '^[0-9]{12}$') { continue }
        $dir = if ($O.OutputDir) { $O.OutputDir } else { '.' }
        Save-PcrDataFile $Raw (Join-Path $dir "rds_patch_${id}_$day.json") $id $off $abbr $utc
    }
}
# Save-PcrDataFile: one data file; $Acct = '' keeps every account
function Save-PcrDataFile {
    param($Raw, [string]$File, [string]$Acct, [long]$Off, [string]$Abbr, [string]$Utc)
    $m = $Raw['meta']; $now = $script:Run.Now
    $mine = { param($x) $Acct -eq '' -or [string]$x -eq $Acct }
    $d = New-JqObject ([ordered]@{
            schema = $script:DataSchema; schema_version = [long]$script:DataSchemaVersion; schema_minor = [long]1; script_version = $script:ScriptVersion
            collected_epoch = [long]$now; collected_at = $Utc; collected_utc = $m['generated_utc']; collected_local = $m['generated_local']
            tz = $script:O.Tz; tz_abbr = $Abbr; tz_offset = [long]$Off
            read_only = 'describe calls + sts get-caller-identity + iam list-account-aliases only'
            accounts = @(foreach ($a in @($m['accounts'])) { if (& $mine $a['account']) { New-JqObject ([ordered]@{ account = $a['account']; profile = $a['profile']; name = $(if (Test-JqTruthy (Get-JqField $a 'name')) { $a['name'] } else { '' }); collected_epoch = [long]$now; collected_at = $Utc }) } })
            settings = (New-JqObject ([ordered]@{ max_behind = $m['max_behind']; warn_days = $m['warn_days']; filters = $m['filters']; oracle_any_patch_line = $m['oracle_any_patch_line']
                        region_discovery = $m['region_discovery']; lifecycle_api = $m['lifecycle_api']; aws_calls = $m['aws_calls'] }))
            regions = (Get-JqUnique @(foreach ($r in @($Raw['rows'])) { if (& $mine $r['account_id']) { $r['region'] } }))
            region_status = @(foreach ($x in @($m['region_status'])) { if ($null -ne $x -and (& $mine $x['account'])) { $x } })
            globals = @(foreach ($x in @($m['globals'])) { if ($null -ne $x -and (& $mine $x['account'])) { $x } })
            global_lookup = @(foreach ($x in @($m['global_lookup'])) { if ($null -ne $x -and (& $mine $x['account'])) { $x } })
            rows = @(foreach ($r in @($Raw['rows'])) { if (& $mine $r['account_id']) { $r } })
            errors = @(foreach ($x in @($Raw['errors'])) { if ($null -ne $x -and ((& $mine $x['account']) -or $x['account'] -eq '-' -or $x['account'] -eq '')) { $x } })
        })
    Write-PcrFile $File ((ConvertTo-JqJson $d) + "`n")
}

# ---------------------------------------------------------------------------------------------- inputs
# Test-PcrDataFile (Bash is_data_file): a JSON object with schema = rds_patch_compliance_data
function Test-PcrDataFile {
    param([string]$Path)
    try { $d = Read-JqJsonFile $Path; return ((Test-JqObject $d) -and (Get-JqField $d 'schema') -eq $script:DataSchema) } catch { return $false }
}
# Resolve-PcrMergeFiles (Bash merge_files): files, wildcards and directories (every data file in it)
function Resolve-PcrMergeFiles {
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($a in $script:O.MergeArgs) {
        if (Test-Path -LiteralPath $a -PathType Container) {
            $hits = @()
            $files = [string[]]@(Get-ChildItem -LiteralPath $a -Filter '*.json' -File | ForEach-Object { $_.FullName }); [Array]::Sort($files, [System.StringComparer]::Ordinal)
            foreach ($x in $files) { if (Test-PcrDataFile $x) { $hits += $x } else { Write-PcrInfo "Skipping $x (not a -SaveData file)" } }
            if ($hits.Count -eq 0) { Stop-Pcr 3 "No -SaveData JSON file in directory: $a" }
            $hits | ForEach-Object { $out.Add($_) }
        }
        elseif (Test-Path -LiteralPath $a -PathType Leaf) { $out.Add($a) }
        elseif ($a -match '[*?[]') {
            $hits = [string[]]@(Get-ChildItem -Path $a -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
            if ($hits.Count -eq 0) { Stop-Pcr 3 "No file matches: $a" }
            [Array]::Sort($hits, [System.StringComparer]::Ordinal); $hits | ForEach-Object { $out.Add($_) }
        }
        else { Stop-Pcr 3 "File not found: $a" }
    }
    return , $out.ToArray()
}
# Read-PcrDataFile (Bash check_data_file): schema 1 from -SaveData, or exit 3 with the reason
function Read-PcrDataFile {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { Stop-Pcr 3 "Cannot read $File" }
    $text = [System.IO.File]::ReadAllText($File)
    $head = $text.Substring(0, [Math]::Min(300, $text.Length))
    if ($head -match '(?i)<!doctype html|<html') { Stop-Pcr 3 "$File is an HTML report, not a data file. Re-run the report in that account with -SaveData and merge the rds_patch_<account>_<date>.json file" }
    try { $d = ConvertFrom-JqJson $text } catch { Stop-Pcr 3 "$File is not valid JSON (truncated or not a -SaveData file)" }
    if (-not (Test-JqObject $d)) { Stop-Pcr 3 "$File is not a patch compliance data file (schema `"$script:DataSchema`" expected; write one with -SaveData)" }
    if ((Get-JqField $d 'schema') -ne $script:DataSchema) {
        if ((Test-JqTruthy (Get-JqField $d 'meta')) -and (Test-JqTruthy (Get-JqField $d 'summary')) -and (Test-JqTruthy (Get-JqField $d 'rows'))) { Stop-Pcr 3 "$File is a -Format json report, not a -SaveData file; re-run with -SaveData" }
        Stop-Pcr 3 "$File is not a patch compliance data file (schema `"$script:DataSchema`" expected; write one with -SaveData)"
    }
    $sv = Get-JqField $d 'schema_version'
    if (-not (Test-JqNumber $sv)) { Stop-Pcr 3 "$File has no schema_version; re-run the report with -SaveData" }
    $svt = Format-JqNumber $sv
    if (-not $d.Contains('rows') -or -not (Test-JqArray $d['rows']) -or -not $d.Contains('accounts') -or -not (Test-JqArray $d['accounts']) -or @($d['accounts']).Count -eq 0 -or -not (Test-JqNumber (Get-JqField $d 'collected_epoch'))) {
        Stop-Pcr 3 "$File is missing accounts / rows / collected_epoch (schema v$svt); re-run the report with -SaveData"
    }
    if ($sv -lt $script:DataSchemaVersion) { Stop-Pcr 3 "$File uses old data schema $svt; re-run v$script:ScriptVersion with -SaveData" }
    if ($sv -gt $script:DataSchemaVersion) { Stop-Pcr 3 "$File uses newer data schema $svt (this script reads $script:DataSchemaVersion); update Invoke-RdsPatchCompliance.ps1" }
    return , $d
}

# ---------------------------------------------------------------------------------------------- merge.jq
# Update-OracleCount (jq ora_recount): re-count Oracle targets for the merge's patch-line rule
function Update-OracleCount {
    param($Row, [bool]$Any)
    if (-not ([string]$Row['engine']).StartsWith('oracle') -or $null -eq $Row['versions_behind'] -or $null -eq (Get-OracleVersionInfo $Row['current_version'])) { return , $Row }
    $cp = Get-OracleVersionInfo $Row['current_version']; $ck = Get-OracleKey $Row['current_version']
    $nv = @(@(Get-JqField $Row 'newer_versions') | Where-Object { $null -ne $_ })
    $ex = @(@(Get-JqField $Row 'excluded_targets') | Where-Object { $null -ne $_ })
    $pool = Get-JqUnique (@($nv) + @($ex | Where-Object { [regex]::IsMatch([string]$_['reason'], 'different patch line') } | ForEach-Object { $_['version'] }))
    $d = foreach ($v in $pool) {
        $tp = Get-OracleVersionInfo $v; $k = Get-OracleKey $v
        if ($null -eq $tp) { @{ v = $v; inc = ($nv -ccontains $v) } }
        elseif ($tp.line -ceq $cp.line) { @{ v = $v; inc = ((Compare-JqValue $k $ck) -gt 0) } }
        elseif ($Any) { @{ v = $v; inc = ((Compare-JqValue $k $ck) -ge 0) } }
        else { @{ v = $v; inc = $false; x = "excluded $v (different patch line $(Get-LineLabel $tp.line); current is $(Get-LineLabel $cp.line))" } }
    }
    $newer = @(Sort-JqBy @($d | Where-Object { $_.inc }) { param($x) $k = Get-OracleKey $x.v; if ($null -eq $k) { $k = @() }; , @(, $k + @($x.v)) } | ForEach-Object { $_.v })
    $r = Copy-JqObject $Row
    $r['newer_versions'] = $newer; $r['versions_behind'] = [long]$newer.Count
    $r['latest_minor_version'] = if ($newer.Count) { $newer[-1] } else { $Row['current_version'] }
    $r['excluded_targets'] = @($ex | Where-Object { -not [regex]::IsMatch([string]$_['reason'], 'different patch line') }) + @(foreach ($x in $d) { if ($x.x) { New-JqObject ([ordered]@{ version = $x.v; reason = $x.x }) } })
    if ($null -ne $r['default_auto_upgrade_target'] -and $newer -cnotcontains $r['default_auto_upgrade_target']) { $r['default_auto_upgrade_target'] = $null }
    return , $r
}
# Merge-PcrData (lib/merge.jq): $Inputs = @(@{i; label; d}); $Mb = MaxBehind or $null; $Oal = $true or $null
function Merge-PcrData {
    param([object[]]$Inputs, $Mb, $Oal)
    $utc = { param($e) Format-PcrUtc $e }
    $all = @(foreach ($f in $Inputs) {
            foreach ($a in @($f.d['accounts'])) {
                $ce = Get-JqField $a 'collected_epoch'; if (-not (Test-JqTruthy $ce)) { $ce = $f.d['collected_epoch'] }
                @{ account = $a['account']; profile = $a['profile']; name = $(if (Test-JqTruthy (Get-JqField $a 'name')) { $a['name'] } else { '' }); collected_epoch = $ce; i = $f.i; label = $f.label }
            }
        })
    $groups = @(foreach ($g in (Group-JqBy $all { param($x) , @($x.account) })) { , (Sort-JqBy $g { param($x) , @($x.collected_epoch, $x.i) }) })
    $use = @{}; foreach ($g in $groups) { $use["$($g[-1].account)|$($g[-1].i)"] = $true }
    $known = Get-JqUnique @($all | ForEach-Object { $_.account })
    $used = { param($acct, $f) [bool]$use["$acct|$($f.i)"] }
    $keep = @(foreach ($g in $groups) { $g[-1] })
    $rows = @(foreach ($f in $Inputs) { foreach ($r in @($f.d['rows'])) { if ($null -ne $r -and (& $used $r['account_id'] $f)) { $r } } })
    $M = if ($null -ne $Mb) { [long]$Mb } else { Get-JqMax @(foreach ($f in $Inputs) { $x = Get-JqField (Get-JqField $f.d 'settings') 'max_behind'; if (Test-JqTruthy $x) { $x } else { [long]2 } }) }
    $oalOn = if (Test-JqTruthy $Oal) { $Oal } else { [bool]@($Inputs | Where-Object { Test-JqTruthy (Get-JqField (Get-JqField $_.d 'settings') 'oracle_any_patch_line') }).Count }
    $outRows = @(foreach ($r in $rows) {
            $x = Update-OracleCount $r $oalOn
            if ($null -ne $x['versions_behind'] -and $x['compliance_status'] -ne 'UNKNOWN') {
                $x = Copy-JqObject $x; $x['compliance_status'] = if ($x['versions_behind'] -gt $M) { 'NON-COMPLIANT' } else { 'COMPLIANT' }
            }
            , $x
        })
    $rs = @(foreach ($f in $Inputs) { foreach ($x in @(Get-JqField $f.d 'region_status')) { if ($null -ne $x -and (& $used $x['account'] $f)) { $x } } })
    $gl = @(foreach ($f in $Inputs) { foreach ($x in @(Get-JqField $f.d 'globals')) { if ($null -ne $x -and (& $used $x['account'] $f)) { $x } } })
    $glk = @(foreach ($f in $Inputs) {
            if ($f.d.Contains('global_lookup')) { foreach ($x in @($f.d['global_lookup'])) { if ($null -ne $x -and (& $used $x['account'] $f)) { $x } } }
            else {
                foreach ($a in @($f.d['accounts'])) {
                    if (& $used $a['account'] $f) {
                        $sv = Get-JqField $f.d 'script_version'; if (-not (Test-JqTruthy $sv)) { $sv = '?' }
                        New-JqObject ([ordered]@{ account = $a['account']; profile = $a['profile']; region = ''; status = 'unknown'; count = [long]0; message = "data file saved by v$sv without global database data" })
                    }
                }
            }
        })
    $errs = @(foreach ($f in $Inputs) { foreach ($x in @(Get-JqField $f.d 'errors')) { if ($null -ne $x -and ((& $used $x['account'] $f) -or $known -cnotcontains $x['account'])) { $x } } })
    $errs = Get-JqUniqueBy $errs { param($x) , @($x['account'], $x['profile'], $x['region'], $x['call'], $x['message']) }
    $regions = Get-JqUnique (@($rows | ForEach-Object { $_['region'] }) + @($rs | ForEach-Object { $_['region'] }))
    $lifecycle = $true; foreach ($f in $Inputs) { $v = Get-JqField (Get-JqField $f.d 'settings') 'lifecycle_api'; if (-not (Test-JqTruthy $(if (Test-JqTruthy $v) { $v } else { $true }))) { $lifecycle = $false } }
    $newest = (Sort-JqBy @($Inputs) { param($f) , @($f.d['collected_epoch'], $f.i) })[-1].d
    $tz = New-JqObject ([ordered]@{ tz = $(if (Test-JqTruthy (Get-JqField $newest 'tz')) { $newest['tz'] } else { 'UTC' }); tz_abbr = $(if (Test-JqTruthy (Get-JqField $newest 'tz_abbr')) { $newest['tz_abbr'] } else { 'UTC' }); tz_offset = $(if (Test-JqTruthy (Get-JqField $newest 'tz_offset')) { $newest['tz_offset'] } else { [long]0 }) })
    $sources = @(foreach ($f in $Inputs) {
            $acc = @($f.d['accounts'] | ForEach-Object { $_['account'] })
            New-JqObject ([ordered]@{ file = $f.label; collected_epoch = $f.d['collected_epoch']; collected_utc = (& $utc $f.d['collected_epoch']); script_version = (Get-JqField $f.d 'script_version')
                    used = @($acc | Where-Object { & $used $_ $f }); superseded = @($acc | Where-Object { -not (& $used $_ $f) }) })
        })
    $sup = @(foreach ($g in $groups) {
            $k = $g[-1]
            if ($g.Count -lt 2) { continue }
            foreach ($x in $g[0..($g.Count - 2)]) { @{ account = $x.account; kept = $k.label; kept_utc = (& $utc $k.collected_epoch); dropped = $x.label; dropped_utc = (& $utc $x.collected_epoch); same_time = ($x.collected_epoch -eq $k.collected_epoch) } }
        })
    return @{
        accounts = @(foreach ($k in $keep) { New-JqObject ([ordered]@{ account = $k.account; profile = $k.profile; name = $k.name; collected_epoch = $k.collected_epoch; collected_utc = (& $utc $k.collected_epoch); source = $k.label }) })
        rows = $outRows; region_status = $rs; globals = $gl; global_lookup = $glk; errors = $errs; regions = $regions
        max_behind = $M; lifecycle_api = $lifecycle; oracle_any_patch_line = [bool]$oalOn; tz = $tz; sources = $sources; superseded = $sup
    }
}
# Invoke-PcrMerge (Bash merge_main): read, check and merge the files, then finalize and write like a scan
function Invoke-PcrMerge {
    $O = $script:O; $now = $script:Run.Now
    $files = Resolve-PcrMergeFiles
    $inputs = @(); $i = 0
    foreach ($f in $files) {
        $d = Read-PcrDataFile $f
        $inputs += @{ i = $i; label = (Split-Path -Leaf $f); d = $d }
        Write-PcrInfo "Input $($i + 1): $f (collected $($d['collected_at']), account(s) $(@($d['accounts'] | ForEach-Object { "$($_['account']) ($($_['profile']))" }) -join ', '))"
        $i++
    }
    $mb = if ($O.MaxBehindSet) { $O.MaxBehind } else { $null }
    $oal = if ($O.OracleAnyLine) { $true } else { $null }
    $m = Merge-PcrData $inputs $mb $oal
    foreach ($s in $m.superseded) {
        if ($s.same_time) { Write-PcrInfo "Account $($s.account): in $($s.dropped) and $($s.kept) with the same collection time; using $($s.kept) (given later)" }
        else { Write-PcrInfo "Account $($s.account): using newer $($s.kept) ($($s.kept_utc)); ignoring older $($s.dropped) ($($s.dropped_utc))" }
    }
    if ($O.TzSet) { $real = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); $tz = $O.Tz; $abbr = Get-PcrTzAbbr $O.Tz $real; $off = Get-PcrTzOffset $O.Tz $real }
    else { $tz = $m.tz['tz']; $abbr = $m.tz['tz_abbr']; $off = [long]$m.tz['tz_offset']; $O.Tz = $tz }
    $O.MaxBehind = [long]$m.max_behind
    $script:Run.Stamp = Format-PcrEpoch $now 'yyyyMMdd_HHmmss' $off
    $loc = { param($e) (Format-PcrEpoch $e 'yyyy-MM-dd HH:mm' $off) + ' ' + $abbr }
    $meta = New-JqObject ([ordered]@{
            script = $script:ScriptName; version = $script:ScriptVersion; generated_utc = (Format-PcrUtc $now); generated_local = (& $loc $now)
            tz = $tz; host = [System.Net.Dns]::GetHostName()
            accounts = @(foreach ($a in $m.accounts) { , (Join-JqObject $a ([ordered]@{ collected_local = (& $loc $a['collected_epoch']) })) })
            regions = $m.regions; tag_columns = @(); max_behind = $m.max_behind; warn_days = [long]$O.WarnDays; filters = (Get-PcrFilters); filters_text = (Get-PcrFiltersText)
            region_discovery = (New-JqObject ([ordered]@{ mode = 'merge'; probe_parallel = $null })); region_status = $m.region_status; globals = $m.globals; global_lookup = $m.global_lookup
            aws_calls = [long]0; aws_failures = [long]0; lifecycle_api = $m.lifecycle_api; oracle_any_patch_line = $m.oracle_any_patch_line
            merge = (New-JqObject ([ordered]@{ files = [long]$i; basis = 'merge time'; sources = @(foreach ($s in $m.sources) { , (Join-JqObject $s ([ordered]@{ collected_local = (& $loc $s['collected_epoch']) })) }) }))
        })
    $raw = New-JqObject ([ordered]@{ meta = $meta; rows = $m.rows; errors = $m.errors })
    $report = Complete-Report $raw $now $O.MaxBehind $O.WarnDays $O.NcOnly $O.AccountNames
    return @{ Report = $report; Files = $i }
}

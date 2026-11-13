# src/Compliance.ps1 - the compliance rule and the report model. Port of lib/compliance.jq modes "rows" and
# "finalize" (the rendering modes are in Render.ps1). Every field name, order and rule is the same as the jq,
# so -Format json / -SaveData files are interchangeable with the Bash tool.
#
# Rule: versions_behind = number of valid MINOR upgrade targets RDS returns for the current version
# (describe-db-engine-versions --engine E --engine-version V: ValidUpgradeTarget[] with IsMajorVersionUpgrade=false,
# same major line, Oracle same patch line). COMPLIANT if <= MaxBehind, NON-COMPLIANT otherwise, UNKNOWN if the
# lookup failed or the current version is not returned (deprecated).

$script:InScope = '^(aurora-postgresql|aurora-mysql|postgres|mysql|mariadb|sqlserver-(ee|se|ex|web)|oracle-(ee|se2|ee-cdb|se2-cdb)|docdb|neptune)$'

# ---------------------------------------------------------------------------------------------- small helpers
# Join-JqObject: jq "$a + {k: v}" (copy; existing keys keep their position, new keys go to the end)
function Join-JqObject {
    param($Object, $Add)
    $o = Copy-JqObject $Object
    foreach ($k in $Add.Keys) { $o[[string]$k] = $Add[$k] }
    return , $o
}
# ConvertTo-GlobRegex (jq glob2re): '*' and '?' wildcards, everything else literal
function ConvertTo-GlobRegex {
    param([string]$Glob)
    $e = [regex]::Replace($Glob, '([.+^$(){}|\[\]\\])', '\$1')
    return '^' + $e.Replace('*', '.*').Replace('?', '.') + '$'
}
# Test-GlobMatch (jq gmatch): no globs = match; else any glob matches (case-insensitive)
function Test-GlobMatch {
    param([AllowNull()]$Value, [AllowNull()][object[]]$Globs)
    if ($null -eq $Globs -or $Globs.Count -eq 0) { return $true }
    $v = if ($null -eq $Value) { '' } else { [string]$Value }
    foreach ($g in $Globs) { if ([regex]::IsMatch($v, (ConvertTo-GlobRegex $g), 'IgnoreCase')) { return $true } }
    return $false
}
# Get-DayPart (jq day / utc_day): first 10 characters of a date, or $null
function Get-DayPart { param([AllowNull()]$V) if ($null -eq $V -or ($V -is [string] -and $V -eq '')) { return $null } $s = ConvertTo-JqText $V; return $s.Substring(0, [Math]::Min(10, $s.Length)) }
# Get-IstText (jq ist_of): AWS UTC timestamp -> "YYYY-mm-dd HH:MM IST" (fixed +05:30, as in the Bash tool)
function Get-IstText {
    param([AllowNull()]$V)
    if ($null -eq $V -or ($V -is [string] -and $V -eq '')) { return $null }
    $s = ConvertTo-JqText $V; $e = ConvertFrom-PcrIsoUtc ($s.Substring(0, [Math]::Min(19, $s.Length)) + 'Z')
    if ($null -eq $e) { return $null }
    return (Format-PcrEpoch ($e + 19800) 'yyyy-MM-dd HH:mm') + ' IST'
}
# Get-UtcText (jq utc_of): "2026-11-20T20:00:00+00:00" -> "2026-11-20 20:00 UTC"
function Get-UtcText {
    param([AllowNull()]$V)
    if ($null -eq $V -or ($V -is [string] -and $V -eq '')) { return $null }
    $s = ConvertTo-JqText $V; $s = $s.Substring(0, [Math]::Min(16, $s.Length))
    return ([regex]::new('T').Replace($s, ' ', 1)) + ' UTC'
}
# Get-DaysFrom (jq days_from): whole days from "now" to a YYYY-MM-DD date (floor), or $null
function Get-DaysFrom {
    param([AllowNull()]$Day, [long]$Now)
    if ($null -eq $Day) { return $null }
    $e = ConvertFrom-PcrIsoUtc ([string]$Day + 'T00:00:00Z')
    if ($null -eq $e) { return $null }
    return [long][Math]::Floor(($e - $Now) / 86400)
}
# Convert-MaintWindow (jq shift_win): "sun:20:00-sun:20:30" shifted by $Minutes (330 = IST)
function Convert-MaintWindow {
    param([AllowNull()]$Window, [int]$Minutes)
    if ($null -eq $Window -or $Window -eq '') { return '' }
    $days = @('sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat')
    $parts = foreach ($p in ([string]$Window).Split('-')) {
        $x = $p.Split(':')
        $t = (([array]::IndexOf($days, $x[0].ToLowerInvariant())) * 1440 + [int]$x[1] * 60 + [int]$x[2] + $Minutes) % 10080
        '{0}:{1:00}:{2:00}' -f $days[[Math]::Floor($t / 1440)], [Math]::Floor(($t % 1440) / 60), ($t % 60)
    }
    return ($parts -join '-')
}
# New-PendingItem (jq pend_item): one pending maintenance action -> structured + readable text
function New-PendingItem {
    param($D, [string]$On)
    $desc = Get-JqField $D 'Description'; if ($null -eq $desc) { $desc = '' }
    $opt = Get-JqField $D 'OptInStatus'; if ($null -eq $opt) { $opt = '' }
    $p = New-JqObject ([ordered]@{
            action = (Get-JqField $D 'Action'); on = $On; description = $desc; opt_in_status = $opt
            auto_applied_after = (Get-DayPart (Get-JqField $D 'AutoAppliedAfterDate')); forced_apply = (Get-DayPart (Get-JqField $D 'ForcedApplyDate'))
            current_apply = (Get-DayPart (Get-JqField $D 'CurrentApplyDate'))
            auto_applied_after_ist = (Get-IstText (Get-JqField $D 'AutoAppliedAfterDate')); forced_apply_ist = (Get-IstText (Get-JqField $D 'ForcedApplyDate'))
            auto_applied_after_utc = (Get-UtcText (Get-JqField $D 'AutoAppliedAfterDate')); forced_apply_utc = (Get-UtcText (Get-JqField $D 'ForcedApplyDate'))
        })
    $bits = @()
    if (Test-JqTruthy $p.auto_applied_after) { $bits += "auto-apply $($p.auto_applied_after)" }
    if (Test-JqTruthy $p.forced_apply) { $bits += "forced $($p.forced_apply)" }
    if ($p.opt_in_status -ne '') { $bits += "opt-in: $($p.opt_in_status)" }
    $txt = [string]$p.action + $(if ($On -ne '') { ' on ' + $On } else { '' }) + ' (' + $(if ($bits.Count -eq 0) { 'no date, optional' } else { $bits -join ', ' }) + ')'
    if ($desc -ne '') { $txt += ' - ' + $(if ($desc.Length -gt 60) { $desc.Substring(0, 57) + '...' } else { $desc }) }
    $p['text'] = $txt
    return , $p
}

# ---------------------------------------------------------------------------------------------- rows
# New-ComplianceRows (jq mode "rows"): one region's describe-* data -> report rows.
#   $Clusters / $Instances / $Pma: AWS lists; $Ev: "engine|version" -> {ok, error, returned, major, targets};
#   $Lc: engine -> {majors: [...]}; $Filters: {engines, identifiers}
function New-ComplianceRows {
    param([string]$Account, [string]$ProfileName, [string]$Region, [object[]]$Clusters, [object[]]$Instances, [object[]]$Pma,
        $Ev, $Lc, $Filters, [long]$Now, [long]$MaxBehind, [long]$WarnDays, [bool]$OracleAny)
    $ix = @{}; foreach ($i in $Instances) { $ix[[string]$i['DBInstanceIdentifier']] = $i }
    # pending actions per resource ARN (sorted by ARN like jq group_by)
    $pairs = @(foreach ($p in $Pma) { foreach ($d in @(Get-JqField $p 'PendingMaintenanceActionDetails')) { if ($null -ne $d) { @{ arn = $p['ResourceIdentifier']; d = $d } } } })
    $pc = New-JqObject
    foreach ($g in (Group-JqBy $pairs { param($x) , @($x.arn) })) { $pc[[string]$g[0].arn] = @(foreach ($x in $g) { $x.d }) }

    $res = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $Clusters) {
        if ([string]$c['Engine'] -cnotmatch $script:InScope) { continue }
        $eng = [string]$c['Engine']
        $rtype = if ($eng -eq 'docdb') { 'docdb-cluster' } elseif ($eng -eq 'neptune') { 'neptune-cluster' } elseif ($eng.StartsWith('aurora')) { 'aurora-cluster' } else { 'multi-az-cluster' }
        $mem = @(Get-JqField $c 'DBClusterMembers' | Where-Object { $null -ne $_ })
        $cAuto = Get-JqField $c 'AutoMinorVersionUpgrade'
        # jq: (.AutoMinorVersionUpgrade // null) != null - "false // null" is null in jq, so only a true cluster value counts
        $auto = @(if ((Test-JqTruthy $cAuto) -and -not $eng.StartsWith('aurora')) { @($cAuto) }
        else { @(foreach ($m in $mem) { $v = Get-JqField $ix[[string]$m['DBInstanceIdentifier']] 'AutoMinorVersionUpgrade'; if ($null -ne $v) { $v } }) })
        $res.Add(@{
                kind = 'cluster'; id = $c['DBClusterIdentifier']; arn = $c['DBClusterArn']; engine = $eng; version = $c['EngineVersion']; rtype = $rtype
                window = $(if ($null -ne (Get-JqField $c 'PreferredMaintenanceWindow')) { $c['PreferredMaintenanceWindow'] } else { '' })
                tags = (Get-TagObject $c)
                members = @(foreach ($m in $mem) { @{ id = $m['DBInstanceIdentifier']; writer = (Test-JqTruthy (Get-JqField $m 'IsClusterWriter')) } })
                auto = $auto
                member_arns = @(foreach ($m in $mem) { $a = Get-JqField $ix[[string]$m['DBInstanceIdentifier']] 'DBInstanceArn'; if ($null -ne $a) { @{ id = $m['DBInstanceIdentifier']; arn = $a } } })
            })
    }
    foreach ($i in $Instances) {
        $cid = Get-JqField $i 'DBClusterIdentifier'; if ($null -ne $cid -and $cid -ne '') { continue }
        if ([string]$i['Engine'] -cnotmatch $script:InScope) { continue }
        $a = Get-JqField $i 'AutoMinorVersionUpgrade'
        $res.Add(@{
                kind = 'instance'; id = $i['DBInstanceIdentifier']; arn = $i['DBInstanceArn']; engine = [string]$i['Engine']; version = $i['EngineVersion']; rtype = 'instance'
                window = $(if ($null -ne (Get-JqField $i 'PreferredMaintenanceWindow')) { $i['PreferredMaintenanceWindow'] } else { '' })
                tags = (Get-TagObject $i); members = @(); auto = @(if ($null -ne $a) { $a }); member_arns = @()
            })
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    $selCache = @{}
    foreach ($r in $res) {
        if (-not (Test-GlobMatch $r.engine $Filters.engines)) { continue }
        $idOk = $false; foreach ($n in (@($r.id) + @($r.members | ForEach-Object { $_.id }))) { if (Test-GlobMatch $n $Filters.identifiers) { $idOk = $true; break } }
        if (-not $idOk) { continue }
        $e = Get-JqField $Ev ($r.engine + '|' + $r.version)
        if ($null -eq $e) { $e = New-JqObject ([ordered]@{ ok = $false; error = 'no lookup' }) }
        $ok = (Get-JqField $e 'ok') -eq $true
        $deprecated = $ok -and ((Get-JqField $e 'returned') -ne $true)
        $known = $ok -and ((Get-JqField $e 'returned') -eq $true)
        $eMajor = Get-JqField $e 'major'
        $major = if (Test-JqTruthy $eMajor) { $eMajor } else { Get-DerivedMajor $r.version $r.engine }
        $eTargets = @(Get-JqField $e 'targets' | Where-Object { $null -ne $_ })
        # same engine + version in one region = same lookup result, so the target selection is computed once
        $selKey = $r.engine + '|' + $r.version
        $sel = $selCache[$selKey]
        if ($null -eq $sel) { $sel = Select-MinorTarget $eTargets $r.engine $r.version $(if (Test-JqTruthy $eMajor) { $eMajor } else { $null }) $OracleAny; $selCache[$selKey] = $sel }
        $tg = @($sel.targets)
        $newer = @($sel.versions)
        $autoTargets = @(foreach ($t in $tg) { if ((Get-JqField $t 'AutoUpgrade') -eq $true) { $t['EngineVersion'] } })
        $autoTarget = if ($autoTargets.Count) { $autoTargets[-1] } else { $null }
        $majorTargets = @($eTargets | Where-Object { (Get-JqField $_ 'IsMajorVersionUpgrade') -eq $true }).Count
        $behind = if ($known) { [long]$newer.Count } else { $null }
        $status = if (-not $known) { 'UNKNOWN' } elseif ($behind -le $MaxBehind) { 'COMPLIANT' } else { 'NON-COMPLIANT' }
        $l = Get-JqField $Lc $r.engine
        $lcs = @(foreach ($mj in @(Get-JqField $l 'majors')) { if ($null -ne $mj -and (Compare-JqValue (Get-JqField $mj 'MajorEngineVersion') $major) -eq 0) { @(Get-JqField $mj 'SupportedEngineLifecycles') | Where-Object { $null -ne $_ } } })
        $std = @(foreach ($x in $lcs) { if ([regex]::IsMatch([string]$x['LifecycleSupportName'], 'standard', 'IgnoreCase')) { , (Get-DayPart (Get-JqField $x 'LifecycleSupportEndDate')) } })
        $std = if ($std.Count) { $std[0] } else { $null }
        $ext = @(foreach ($x in $lcs) { if ([regex]::IsMatch([string]$x['LifecycleSupportName'], 'extended', 'IgnoreCase')) { , (Get-DayPart (Get-JqField $x 'LifecycleSupportEndDate')) } })
        $ext = if ($ext.Count) { $ext[0] } else { $null }
        $days = Get-DaysFrom $std $Now
        $svc = Get-PcrService $r.engine
        $sflag = if ($null -eq $l) { if ($svc -ne 'rds') { "n/a (no lifecycle API for $($r.engine))" } else { 'unknown (lifecycle lookup unavailable)' } }
        elseif ($null -eq $std) { "unknown (AWS lists no lifecycle dates for $($r.engine) $(ConvertTo-JqText $major))" }
        elseif ($days -lt 0) { 'past standard support (Extended Support charges)' }
        elseif ($days -le $WarnDays) { "standard support ends in $days days" }
        else { 'ok' }
        $pend = @(foreach ($d in @(Get-JqField $pc ([string]$r.arn))) { if ($null -ne $d) { New-PendingItem $d $(if ($r.kind -eq 'cluster') { 'cluster' } else { '' }) } }) +
        @(foreach ($m in $r.member_arns) { foreach ($d in @(Get-JqField $pc ([string]$m.arn))) { if ($null -ne $d) { New-PendingItem $d ('member ' + $m.id) } } })
        $auto = if ($r.auto.Count -eq 0) { 'unknown' } elseif (@($r.auto | Where-Object { $_ -ne $true }).Count -eq 0) { 'true' } elseif (@($r.auto | Where-Object { $_ -ne $false }).Count -eq 0) { 'false' } else { 'mixed' }
        $latest = if ($newer.Count) { $newer[-1] } else { $r.version }
        $notes = @()
        if (-not $ok) { $notes += "version lookup failed: $(if ($null -ne (Get-JqField $e 'error')) { $e['error'] } else { 'unknown' })" }
        if ($deprecated) { $notes += "current version not returned by describe-db-engine-versions (deprecated or not offered in $Region); no valid upgrade targets known" }
        foreach ($x in $sel.excluded) { $notes += $x['reason'] }
        if ($auto -eq 'false') { $notes += 'auto minor upgrade is off' } elseif ($auto -eq 'mixed') { $notes += 'auto minor upgrade is off on some members' }
        $gpr = @(if ($r.rtype -eq 'aurora-cluster') { foreach ($k in $pc.Keys) { if ($k -match ':global-cluster:') { New-JqObject ([ordered]@{ garn = $k; d = $pc[$k] }) } } })
        $rows.Add((New-JqObject ([ordered]@{
                        account_id = $Account; profile = $ProfileName; region = $Region; resource_type = $r.rtype; identifier = $r.id
                        members = (@($r.members | ForEach-Object { $_.id + $(if ($_.writer) { ' (writer)' } else { '' }) }) -join ', ')
                        member_count = [long]@($r.members).Count
                        engine = $r.engine; major_version = $major; current_version = $r.version
                        latest_minor_version = $(if ($known) { $latest } else { $null })
                        versions_behind = $behind; newer_versions = $newer; default_auto_upgrade_target = $autoTarget; major_upgrade_targets = [long]$majorTargets
                        excluded_targets = @($sel.excluded); version_warnings = @($sel.warnings)
                        compliance_status = $status; auto_minor_upgrade = $auto
                        standard_support_end = $std; extended_support_end = $ext; support_days_left = $days; support_flag = $sflag
                        past_standard_support = $sflag.StartsWith('past'); nearing_end_of_support = $sflag.StartsWith('standard support ends')
                        deprecated_version = $deprecated
                        pending_actions_count = [long]$pend.Count; pending_actions = (@($pend | ForEach-Object { $_['text'] }) -join '; '); pending_actions_detail = $pend
                        maint_window_utc = $r.window; maint_window_ist = (Convert-MaintWindow $r.window 330)
                        tags = $r.tags; arn = $r.arn
                        global_pending_raw = $gpr
                        note = ($notes -join '; ')
                    })))
    }
    return , $rows.ToArray()
}
# Get-TagObject (jq tags_obj): TagList [{Key, Value}] -> {Key: Value}
function Get-TagObject {
    param($Resource)
    $o = New-JqObject
    foreach ($t in @(Get-JqField $Resource 'TagList')) { if ($null -ne $t) { $o[[string]$t['Key']] = Get-JqField $t 'Value' } }
    return , $o
}
# Get-PcrService (jq svc_of): docdb / neptune have their own API for engine versions, the rest is rds
function Get-PcrService { param([string]$Engine) switch ($Engine) { 'docdb' { 'docdb' } 'neptune' { 'neptune' } default { 'rds' } } }

# ---------------------------------------------------------------------------------------------- finalize
# Get-StatusRank (jq st_rank) / Get-RegionRank (jq region_rank): sort weights
function Get-StatusRank { param($S) switch ($S) { 'NON-COMPLIANT' { 0 } 'UNKNOWN' { 1 } 'COMPLIANT' { 2 } default { 3 } } }
function Get-RegionRank { param($S) switch ($S) { 'databases' { 0 } 'error' { 1 } 'empty' { 2 } default { 3 } } }
# Get-Pct (jq pct): one decimal, half away from zero; 0 when the total is 0
function Get-Pct {
    param([double]$A, [double]$B)
    if ($B -eq 0) { return [long]0 }
    return [Math]::Round($A * 1000 / $B, [MidpointRounding]::AwayFromZero) / 10
}
# Get-StatusCounts (jq counts): {total, compliant, non_compliant, unknown}
function Get-StatusCounts {
    param([object[]]$Rows)
    $c = 0; $n = 0; $u = 0
    foreach ($r in $Rows) { switch ($r['compliance_status']) { 'COMPLIANT' { $c++ } 'NON-COMPLIANT' { $n++ } 'UNKNOWN' { $u++ } } }
    return (New-JqObject ([ordered]@{ total = [long]@($Rows).Count; compliant = [long]$c; non_compliant = [long]$n; unknown = [long]$u }))
}
# Get-RegionCounts (jq region_counts): counts + pct / pending / past standard support
function Get-RegionCounts {
    param([object[]]$Rows)
    $Rows = @($Rows)
    $c = Get-StatusCounts $Rows
    $c['pct_compliant'] = if ($Rows.Count -eq 0) { $null } else { Get-Pct $c.compliant $Rows.Count }
    $c['with_pending'] = [long]@($Rows | Where-Object { $_['pending_actions_count'] -gt 0 }).Count
    $s = [long]0; foreach ($r in $Rows) { $s += $r['pending_actions_count'] }; $c['pending_total'] = $s
    $c['past_standard_support'] = [long]@($Rows | Where-Object { $_['past_standard_support'] -eq $true }).Count
    return , $c
}
# Update-RowDates (jq refresh_row): days to support end / maintenance counted from "now" (collection AND merge)
function Update-RowDates {
    param($Row, [long]$Now, [long]$WarnDays)
    $r = Copy-JqObject $Row
    if ($null -ne (Get-JqField $r 'standard_support_end')) {
        $days = Get-DaysFrom $r['standard_support_end'] $Now
        $r['support_days_left'] = $days
        $r['support_flag'] = if ($days -lt 0) { 'past standard support (Extended Support charges)' } elseif ($days -le $WarnDays) { "standard support ends in $days days" } else { 'ok' }
    }
    $sf = [string]$r['support_flag']
    $r['past_standard_support'] = $sf.StartsWith('past'); $r['nearing_end_of_support'] = $sf.StartsWith('standard support ends')
    $r['pending_actions_detail'] = @(foreach ($p in @($r['pending_actions_detail'])) {
            if ($null -eq $p) { continue }
            $m = Get-JqMin @(@($p['current_apply'], $p['auto_applied_after'], $p['forced_apply']) | Where-Object { $null -ne $_ })
            , (Join-JqObject $p ([ordered]@{ next_date = $m; days_until = (Get-DaysFrom $m $Now) }))
        })
    $nx = Get-JqMin @($r['pending_actions_detail'] | ForEach-Object { $_['next_date'] } | Where-Object { $null -ne $_ })
    $r['next_maintenance'] = $nx; $r['days_until_maintenance'] = Get-DaysFrom $nx $Now
    return , $r
}
# Add-GlobalInfo (jq annotate_globals): Aurora global database role / pending actions / notes per row
function Add-GlobalInfo {
    param($Report)
    $ls = New-JqObject; foreach ($x in @(Get-JqField $Report.meta 'global_lookup')) { if ($null -ne $x) { $ls[[string]$x['account']] = $x['status'] } }
    $gm = New-JqObject
    foreach ($g in @(Get-JqField $Report.meta 'globals')) { if ($null -eq $g) { continue }; foreach ($m in @($g['members'])) { $gm[[string]$m['arn']] = @{ id = $g['id']; garn = $g['arn']; role = $m['role'] } } }
    $Report['rows'] = @(foreach ($row in @($Report['rows'])) {
            if ($row['resource_type'] -ne 'aurora-cluster') { $x = Join-JqObject $row ([ordered]@{ global_cluster = ''; global_role = ''; global_arn = $null }) }
            else {
                $st = Get-JqField $ls ([string]$row['account_id']); if (-not (Test-JqTruthy $st)) { $st = 'unknown' }
                if ($st -ne 'ok' -and $st -ne 'not-needed') { $x = Join-JqObject $row ([ordered]@{ global_cluster = $null; global_role = 'unknown'; global_arn = $null }) }
                else {
                    $m = Get-JqField $gm ([string]$row['arn']); if ($null -eq $m) { $m = @{ id = ''; garn = $null; role = '' } }
                    $x = Join-JqObject $row ([ordered]@{ global_cluster = $m.id; global_role = $m.role; global_arn = $m.garn })
                }
            }
            $pd = @(foreach ($p in @($x['pending_actions_detail'])) { if ($null -ne $p -and -not ([string]$p['on']).StartsWith('global ')) { $p } })
            if (Test-JqTruthy $x['global_arn']) {
                foreach ($gp in @(Get-JqField $x 'global_pending_raw')) { if ($null -ne $gp -and $gp['garn'] -eq $x['global_arn']) { foreach ($d in @($gp['d'])) { $pd += , (New-PendingItem $d ('global ' + $x['global_cluster'])) } } }
            }
            $x['pending_actions_detail'] = $pd
            $x['pending_actions_count'] = [long]$pd.Count
            $x['pending_actions'] = (@($pd | ForEach-Object { $_['text'] }) -join '; ')
            $gc = Get-JqField $x 'global_cluster'
            if ($null -ne $gc -and $gc -ne '') {
                $keep = @(([string]$x['note']).Split('; ') | Where-Object { $_ -ne '' -and -not $_.StartsWith('Aurora global database') })
                $keep += "Aurora global database $gc ($($x['global_role'])): automatic minor version upgrade does not apply to global database members"
                if ($x['engine'] -eq 'aurora-mysql') {
                    $keep += 'upgrade the secondary clusters first, then the primary, to the same version' + $(if ($x['global_role'] -eq 'secondary' -and $x['member_count'] -eq 0) { '; headless secondary: add an instance before a minor upgrade' } else { '' })
                }
                else { $keep += 'Aurora PostgreSQL: modify-global-cluster upgrades every member in one managed minor upgrade' }
                $x['note'] = $keep -join '; '
            }
            elseif ($x['global_role'] -eq 'unknown') {
                $keep = @(([string]$x['note']).Split('; ') | Where-Object { $_ -ne '' -and -not $_.StartsWith('global database membership') })
                $x['note'] = (@($keep) + 'global database membership unknown') -join '; '
            }
            , $x
        })
}
# Get-GlobalSummary (jq global_summary): one entry per Aurora global database (members, worst status, mismatch)
function Get-GlobalSummary {
    param($Report)
    $gi = New-JqObject; foreach ($g in @(Get-JqField $Report.meta 'globals')) { if ($null -ne $g) { $gi["$($g['account'])|$($g['id'])"] = $g } }
    $grows = @($Report['rows'] | Where-Object { $null -ne $_['global_cluster'] -and $_['global_cluster'] -ne '' })
    $out = foreach ($g in (Group-JqBy $grows { param($r) , @($r['account_id'], $r['global_cluster']) })) {
        $meta = Get-JqField $gi "$($g[0]['account_id'])|$($g[0]['global_cluster'])"
        $mem = @(foreach ($r in $g) {
                New-JqObject ([ordered]@{ account_id = $r['account_id']; region = $r['region']; identifier = $r['identifier']; role = $r['global_role']; current_version = $r['current_version']
                        latest_minor_version = $r['latest_minor_version']; versions_behind = $r['versions_behind']; compliance_status = $r['compliance_status']; headless = ($r['member_count'] -eq 0); scanned = $true })
            })
        foreach ($m in @(Get-JqField $meta 'members')) {
            if ($null -eq $m) { continue }
            if (@($g | Where-Object { $_['arn'] -eq $m['arn'] }).Count -eq 0) {
                $mem += , (New-JqObject ([ordered]@{ account_id = $g[0]['account_id']; region = $m['region']; identifier = $m['cluster']; role = $m['role']; current_version = $null
                            latest_minor_version = $null; versions_behind = $null; compliance_status = 'NOT SCANNED'; headless = $null; scanned = $false }))
            }
        }
        $mem = Get-JqSortedBy $mem { param($m) , @($(if ($m['role'] -eq 'primary') { 0 } else { 1 }), $m['region']) }
        $sc = @($mem | Where-Object { $_['scanned'] })
        $versions = Get-JqUnique @($sc | ForEach-Object { , $_['current_version'] })
        $mismatch = $false
        foreach ($vg in (Group-JqBy $sc { param($m) , @($m['current_version']) })) { if ((Get-JqUnique @($vg | ForEach-Object { $_['compliance_status'] })).Count -gt 1) { $mismatch = $true } }
        $pending = Get-JqUnique @(foreach ($r in $g) { foreach ($p in @($r['pending_actions_detail'])) { if ($null -ne $p -and ([string]$p['on']).StartsWith('global ')) { $p['text'] } } })
        $worst = Get-JqSortedBy @($sc | ForEach-Object { $_['compliance_status'] }) { param($s) Get-StatusRank $s }
        $an = Get-JqField $g[0] 'account_name'; if ($null -eq $an) { $an = '' }
        , (New-JqObject ([ordered]@{
                    account_id = $g[0]['account_id']; account_name = $an; global_cluster = $g[0]['global_cluster']; engine = $g[0]['engine']
                    global_status = (Get-JqField $meta 'status'); members = $mem; member_count = [long]$sc.Count; not_scanned = [long]@($mem | Where-Object { -not $_['scanned'] }).Count
                    overall_status = $(if ($worst.Count) { $worst[0] } else { $null }); versions = $versions; version_differs = ($versions.Count -gt 1)
                    region_status_mismatch = $mismatch; pending = $pending
                }))
    }
    return , (Get-JqSortedBy @($out) { param($x) , @((Get-StatusRank $x['overall_status']), $x['account_id'], $x['global_cluster']) })
}
# Get-RegionBreakdown (jq region_breakdown): one entry per account + region checked (incl. empty / error)
function Get-RegionBreakdown {
    param($Report)
    $by = @{}
    foreach ($g in (Group-JqBy @($Report['rows']) { param($r) , @($r['account_id'], $r['region']) })) { $by["$($g[0]['account_id'])|$($g[0]['region'])"] = $g }
    $all = @(@(Get-JqField $Report.meta 'region_status') | Where-Object { $null -ne $_ }) + @(foreach ($r in @($Report['rows'])) { New-JqObject ([ordered]@{ account = $r['account_id']; profile = $r['profile']; region = $r['region']; status = 'scanned' }) })
    $list = foreach ($x in (Get-JqUniqueBy $all { param($s) , @($s['account'], $s['region']) })) {
        $g = $by["$($x['account'])|$($x['region'])"]; if ($null -eq $g) { $g = @() }
        $ne = [long]@($Report['errors'] | Where-Object { $_['account'] -eq $x['account'] -and $_['region'] -eq $x['region'] }).Count
        $st = if ($ne -gt 0 -or $x['status'] -eq 'probe-error') { 'error' } elseif (@($g).Count -gt 0 -or $x['status'] -eq 'databases') { 'databases' } else { 'empty' }
        $e = New-JqObject ([ordered]@{ account_id = $x['account']; profile = $x['profile']; region = $x['region']; status = $st; skipped = ($x['status'] -eq 'empty')
                probe_instances = (Get-JqField $x 'probe_instances'); probe_clusters = (Get-JqField $x 'probe_clusters'); errors = $ne })
        $rc = Get-RegionCounts $g
        foreach ($k in $rc.Keys) { $e[$k] = $rc[$k] }
        , $e
    }
    return , (Get-JqSortedBy @($list) { param($x) , @((Get-RegionRank $x['status']), $x['account_id'], $x['region']) })
}
# Get-AccountBreakdown (jq account_breakdown): one entry per account
function Get-AccountBreakdown {
    param($Report, [object[]]$Regs)
    $list = foreach ($a in @(Get-JqField $Report.meta 'accounts')) {
        if ($null -eq $a) { continue }
        $g = @($Report['rows'] | Where-Object { $_['account_id'] -eq $a['account'] })
        $cu = Get-JqField $a 'collected_utc'; if (-not (Test-JqTruthy $cu)) { $cu = $Report.meta['generated_utc'] }
        $nm = Get-JqField $a 'name'; if (-not (Test-JqTruthy $nm)) { $nm = '' }
        $src = Get-JqField $a 'source'; if (-not (Test-JqTruthy $src)) { $src = $null }
        $e = New-JqObject ([ordered]@{ account_id = $a['account']; profile = $a['profile']; account_name = $nm; collected_utc = $cu; source = $src
                regions_with_databases = [long]@($Regs | Where-Object { $_['account_id'] -eq $a['account'] -and $_['status'] -eq 'databases' }).Count
                errors = [long]@($Report['errors'] | Where-Object { $_['account'] -eq $a['account'] }).Count })
        $rc = Get-RegionCounts $g
        foreach ($k in $rc.Keys) { $e[$k] = $rc[$k] }
        , $e
    }
    return , (Get-JqSortedBy @($list) { param($x) $x['account_id'] })
}
# Complete-Report (jq mode "finalize"): names, refreshed dates, globals, filters, sort, summary
#   $Report = {meta, rows, errors}; returns {meta, rows, errors, summary}
function Complete-Report {
    param($Report, [long]$Now, [long]$MaxBehind, [long]$WarnDays, [bool]$NcOnly, $AccountNames)
    $r = Copy-JqObject $Report
    $r['meta'] = Copy-JqObject $r['meta']
    $r['meta']['accounts'] = @(foreach ($a in @(Get-JqField $r['meta'] 'accounts')) {
            if ($null -eq $a) { continue }
            $cn = Get-JqField $AccountNames ([string]$a['account'])
            $nm = if ($null -ne $cn -and $cn -ne '') { $cn } else { $x = Get-JqField $a 'name'; if (Test-JqTruthy $x) { $x } else { '' } }
            , (Join-JqObject $a ([ordered]@{ name = $nm }))
        })
    $an = @{}; foreach ($a in $r['meta']['accounts']) { $an[[string]$a['account']] = $a['name'] }
    $r['rows'] = @(foreach ($row in @($r['rows'])) {
            if ($null -eq $row) { continue }
            $x = Update-RowDates $row $Now $WarnDays
            $x.Remove('upgrade_command')   # files saved before v1.4.0 carry it
            $nm = $an[[string]$x['account_id']]; $x['account_name'] = if ($null -ne $nm) { $nm } else { '' }
            , $x
        })
    $r['errors'] = @(@(Get-JqField $r 'errors') | Where-Object { $null -ne $_ })
    Add-GlobalInfo $r
    $gs = Get-GlobalSummary $r
    $regs = Get-RegionBreakdown $r
    $all = @($r['rows'])
    $shown = @($all | Where-Object { -not $NcOnly -or $_['compliance_status'] -eq 'NON-COMPLIANT' })
    $shown = Get-JqSortedBy $shown { param($x) $vb = $x['versions_behind']; if ($null -eq $vb) { $vb = -1 }; , @($x['engine'], (Get-StatusRank $x['compliance_status']), (-1 * $vb), (ConvertTo-AsciiLower $x['identifier']), $x['account_id'], $x['region']) }
    $cnt = Get-StatusCounts $all
    $acts = @(foreach ($x in $all) { foreach ($p in @($x['pending_actions_detail'])) { if ($null -ne $p) { $p['action'] } } })
    $pba = New-JqObject
    $pbaList = Get-JqSortedBy @(foreach ($g in (Group-JqBy $acts { param($a) , @($a) })) { @{ key = $g[0]; value = [long]$g.Count } }) { param($e) , @((-1 * $e.value), $e.key) }
    foreach ($e in $pbaList) { $pba[[string]$e.key] = $e.value }
    $engines = foreach ($g in (Group-JqBy $all { param($x) , @($x['engine']) })) {
        $c = Get-StatusCounts $g
        $e = New-JqObject ([ordered]@{ engine = $g[0]['engine']; anchor = ('eng-' + [regex]::Replace([string]$g[0]['engine'], '[^A-Za-z0-9]', '-')) })
        foreach ($k in $c.Keys) { $e[$k] = $c[$k] }
        $e['pct_compliant'] = Get-Pct $c.compliant @($g).Count
        $majors = foreach ($m in (Group-JqBy $g { param($x) , @($x['major_version']) })) {
            $mc = Get-StatusCounts $m
            $mo = New-JqObject ([ordered]@{ major = $m[0]['major_version'] })
            foreach ($k in $mc.Keys) { $mo[$k] = $mc[$k] }
            $mo['latest_minor'] = Get-LatestVersion @($m | ForEach-Object { , $_['latest_minor_version'] }) ([string]$m[0]['engine'])
            $sse = @($m | ForEach-Object { $_['standard_support_end'] } | Where-Object { $null -ne $_ })
            $mo['standard_support_end'] = if ($sse.Count) { $sse[0] } else { $null }
            $mo['support_flag'] = $m[0]['support_flag']
            , $mo
        }
        $sortedM = Get-JqSortedBy @($majors) { param($x) , (Get-VersionKey $x['major']) }
        [array]::Reverse($sortedM)
        $e['majors'] = $sortedM
        , $e
    }
    $s = New-JqObject
    foreach ($k in $cnt.Keys) { $s[$k] = $cnt[$k] }
    $s['pct_compliant'] = Get-Pct $cnt.compliant $cnt.total
    $s['shown'] = [long]$shown.Count; $s['max_behind'] = [long]$MaxBehind; $s['warn_days'] = [long]$WarnDays
    $s['past_standard_support'] = [long]@($all | Where-Object { $_['past_standard_support'] -eq $true }).Count
    $s['nearing_end_of_support'] = [long]@($all | Where-Object { $_['nearing_end_of_support'] -eq $true }).Count
    $s['auto_minor_off'] = [long]@($all | Where-Object { $_['auto_minor_upgrade'] -eq 'false' -or $_['auto_minor_upgrade'] -eq 'mixed' }).Count
    $s['with_pending'] = [long]@($all | Where-Object { $_['pending_actions_count'] -gt 0 }).Count
    $pt = [long]0; foreach ($x in $all) { $pt += $x['pending_actions_count'] }; $s['pending_total'] = $pt
    $s['pending_by_action'] = $pba
    $s['deprecated'] = [long]@($all | Where-Object { $_['deprecated_version'] -eq $true }).Count
    $s['errors'] = [long]@($r['errors']).Count
    $s['globals'] = $gs; $s['global_databases'] = [long]$gs.Count
    $gmc = [long]0; foreach ($g in $gs) { $gmc += $g['member_count'] }; $s['global_members'] = $gmc
    $s['global_unknown'] = [long]@($all | Where-Object { $_['global_role'] -eq 'unknown' }).Count
    $gl = Get-JqField $r['meta'] 'global_lookup'; $s['global_lookup'] = @(if ($null -ne $gl) { $gl })
    $s['regions'] = @(foreach ($x in $regs) { $nm = $an[[string]$x['account_id']]; , (Join-JqObject $x ([ordered]@{ account_name = $(if ($null -ne $nm) { $nm } else { '' }) })) })
    $s['accounts'] = Get-AccountBreakdown $r $regs
    $tot = New-JqObject ([ordered]@{ account_id = 'ALL'; profile = ''; region = 'All regions'; status = ''; errors = [long]@($r['errors']).Count })
    $rc = Get-RegionCounts $all; foreach ($k in $rc.Keys) { $tot[$k] = $rc[$k] }
    $s['regions_total'] = $tot
    $rd = Get-JqField $r['meta'] 'region_discovery'
    $mode = Get-JqField $rd 'mode'; if (-not (Test-JqTruthy $mode)) { $mode = 'explicit' }
    $empties = @($regs | Where-Object { $_['status'] -eq 'empty' })
    $s['region_overview'] = New-JqObject ([ordered]@{
            mode = $mode; probe_parallel = (Get-JqField $rd 'probe_parallel'); checked = [long]$regs.Count
            with_databases = [long]@($regs | Where-Object { $_['status'] -eq 'databases' }).Count; empty = [long]$empties.Count
            error = [long]@($regs | Where-Object { $_['status'] -eq 'error' }).Count
            empty_regions = @(foreach ($g in (Group-JqBy $empties { param($x) , @($x['account_id']) })) { New-JqObject ([ordered]@{ account_id = $g[0]['account_id']; regions = @($g | ForEach-Object { $_['region'] }) }) })
        })
    $s['engines'] = @($engines)
    $r['rows'] = $shown
    $r['summary'] = $s
    return , $r
}
# ConvertTo-AsciiLower (jq ascii_downcase): only A-Z change
function ConvertTo-AsciiLower { param([AllowNull()]$S) if ($null -eq $S) { return $null } return [regex]::Replace([string]$S, '[A-Z]', { param($m) $m.Value.ToLowerInvariant() }) }

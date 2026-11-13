# src/Collect.ps1 - the scan: profiles -> accounts -> regions -> rows. Port of precheck, default_region,
# collect_versions, collect_region, discover_regions / probe_region, collect_profile, collect_globals and
# build_report. Everything is kept in memory (the Bash tool writes small JSON files to a work dir instead).

# ---------------------------------------------------------------------------------------------- pre-checks
# Test-PcrPrereq (Bash precheck): the back end must be usable before any call is made
function Test-PcrPrereq {
    if ($PSVersionTable.PSVersion.Major -lt 7) { Stop-Pcr 2 "PowerShell 7.2+ required (found $($PSVersionTable.PSVersion))" }
    if (-not (Test-Path -LiteralPath $script:PagePath)) { Stop-Pcr 2 "Library missing: $script:PagePath" }
    if ($script:O.AwsBackend -eq 'Cli') {
        if (-not (Get-Command aws -CommandType Application -ErrorAction SilentlyContinue)) { Stop-Pcr 2 'AWS CLI not found in PATH (install AWS CLI v2, or use -AwsBackend AwsTools)' }
        $v = (& aws --version 2>&1) -join ' '
        $m = [regex]::Match($v, 'aws-cli/([0-9]+)')
        if (-not $m.Success) { Stop-Pcr 2 "Cannot determine AWS CLI version: $v" }
        if ([int]$m.Groups[1].Value -lt 2) { Stop-Pcr 2 "AWS CLI v2 required (found $(($v -split ' ')[0]))" }
        return
    }
    foreach ($mod in 'AWS.Tools.Common', 'AWS.Tools.RDS', 'AWS.Tools.EC2', 'AWS.Tools.SecurityToken') {
        if (-not (Get-Module -ListAvailable -Name $mod)) { Stop-Pcr 2 "$mod not installed (Install-Module $mod -Scope CurrentUser)" }
    }
    Import-Module AWS.Tools.Common, AWS.Tools.RDS, AWS.Tools.EC2, AWS.Tools.SecurityToken -ErrorAction Stop -Verbose:$false
    foreach ($mod in 'AWS.Tools.IdentityManagement', 'AWS.Tools.DocDB', 'AWS.Tools.Neptune') {   # optional: alias / docdb / neptune versions
        if (Get-Module -ListAvailable -Name $mod) { Import-Module $mod -ErrorAction SilentlyContinue -Verbose:$false }
        else { Write-PcrDebug "$mod not installed: that lookup is skipped (account alias / DocumentDB / Neptune versions show UNKNOWN)" }
    }
}

# Get-PcrDefaultRegion (Bash default_region): env AWS_REGION / AWS_DEFAULT_REGION, else the profile's region
function Get-PcrDefaultRegion {
    param([string]$ProfileName)
    $r = if ($env:AWS_REGION) { $env:AWS_REGION } elseif ($env:AWS_DEFAULT_REGION) { $env:AWS_DEFAULT_REGION } else { '' }
    if ($r) { return $r }
    if ($script:O.AwsBackend -eq 'Cli') {
        $a = @('configure', 'get', 'region'); if ($ProfileName) { $a += @('--profile', $ProfileName) }
        $x = (& aws @a 2>$null) -join ''
        if ($LASTEXITCODE -eq 0) { return $x.Trim() } else { return '' }
    }
    try {
        $chain = [Amazon.Runtime.CredentialManagement.CredentialProfileStoreChain]::new()
        $p = $null
        if ($chain.TryGetProfile($(if ($ProfileName) { $ProfileName } else { 'default' }), [ref]$p) -and $p.Region) { return $p.Region.SystemName }
    }
    catch { Write-PcrDebug "profile region lookup failed: $_" }
    return ''
}
# Test-PcrEngineWanted (Bash engine_wanted): -Engine globs (case-insensitive); none = every engine
function Test-PcrEngineWanted {
    param([string]$Engine)
    if ($script:O.Engines.Count -eq 0) { return $true }
    foreach ($g in $script:O.Engines) { if ([System.Management.Automation.WildcardPattern]::new($g, 'IgnoreCase').IsMatch($Engine)) { return $true } }
    return $false
}
# Add-PcrError (Bash add_error): one entry of the report's error list
function Add-PcrError {
    param([string]$Account, [string]$ProfileName, [string]$Region, [string]$Call, [string]$Message)
    $script:Run.Errors.Add((New-JqObject ([ordered]@{ account = $Account; profile = $(if ($ProfileName) { $ProfileName } else { 'default' }); region = $Region; call = $Call; message = $Message })))
}

# ---------------------------------------------------------------------------------------------- versions
# Get-PcrVersionData (Bash collect_versions): valid upgrade targets per (engine, current version, region) and
# lifecycle dates per (engine, region); cached across profiles. Returns @{ ev = {...}; lc = {...} }
function Get-PcrVersionData {
    param([string]$ProfileName, [string]$Region, [object[]]$Clusters, [object[]]$Instances)
    $pl = if ($ProfileName) { $ProfileName } else { 'default' }
    $pairs = @(foreach ($x in @($Instances) + @($Clusters)) {
            $e = Get-JqField $x 'Engine'; $v = Get-JqField $x 'EngineVersion'
            if ($null -ne $e -and $e -ne '' -and $null -ne $v -and $v -ne '') { , @($e, $v) }
        })
    $ev = New-JqObject; $lc = New-JqObject
    foreach ($pv in (Get-JqUnique $pairs)) {
        $engine = [string]$pv[0]; $ver = [string]$pv[1]
        if ($engine -cnotmatch $script:InScope -or -not (Test-PcrEngineWanted $engine)) { continue }
        $svc = Get-PcrService $engine
        $ck = "$Region|$engine|$ver"
        if (-not $script:Run.EvCache.ContainsKey($ck)) {
            $r = Invoke-PcrAws $ProfileName $Region "$svc describe-db-engine-versions" @{ engine = $engine; 'engine-version' = $ver } -Soft
            if ($r.ok) {
                $x = @(@(Get-JqField $r.data 'DBEngineVersions') | Where-Object { $null -ne $_ -and $_['Engine'] -ceq $engine -and $_['EngineVersion'] -ceq $ver })
                $x = if ($x.Count) { $x[0] } else { $null }
                $major = Get-JqField $x 'MajorEngineVersion'
                if (-not (Test-JqTruthy $major)) {
                    $fam = Get-JqField $x 'DBParameterGroupFamily'; if (-not (Test-JqTruthy $fam)) { $fam = '' }
                    $major = [regex]::Replace([string]$fam, '^[A-Za-z-]+', ''); if ($major -eq '') { $major = $null }
                }
                $targets = @(foreach ($t in @(Get-JqField $x 'ValidUpgradeTarget')) {
                        if ($null -eq $t) { continue }
                        New-JqObject ([ordered]@{ Engine = (Get-JqField $t 'Engine'); EngineVersion = (Get-JqField $t 'EngineVersion'); IsMajorVersionUpgrade = (Get-JqField $t 'IsMajorVersionUpgrade'); AutoUpgrade = (Get-JqField $t 'AutoUpgrade') })
                    })
                $val = New-JqObject ([ordered]@{ ok = $true; error = $null; returned = ($null -ne $x); major = $major; targets = $targets })
                if ($null -eq $x) { Write-PcrWarn "[$pl/$Region] $engine $ver is not returned by describe-db-engine-versions (deprecated / not offered here); its servers are UNKNOWN" }
            }
            else {
                Write-PcrWarn "[$pl/$Region] engine-version lookup for $engine $ver failed ($($r.err)); its servers are UNKNOWN"
                $val = New-JqObject ([ordered]@{ ok = $false; error = $r.err; returned = $false; major = $null; targets = @() })
            }
            $script:Run.EvCache[$ck] = $val
        }
        $ev["$engine|$ver"] = $script:Run.EvCache[$ck]
        if ($svc -ne 'rds') { continue }
        $lk = "$Region|$engine"
        if (-not $script:Run.LcCache.ContainsKey($lk) -and -not $script:Run.LcUnsupported) {
            $r = Invoke-PcrAws $ProfileName $Region 'rds describe-db-major-engine-versions' @{ engine = $engine } -Soft
            if ($r.ok) {
                $script:Run.LcCache[$lk] = New-JqObject ([ordered]@{ majors = @(foreach ($m in @(Get-JqField $r.data 'DBMajorEngineVersions')) {
                                if ($null -ne $m) { New-JqObject ([ordered]@{ MajorEngineVersion = (Get-JqField $m 'MajorEngineVersion'); SupportedEngineLifecycles = (Get-JqField $m 'SupportedEngineLifecycles') }) } }) })
            }
            else {
                if ($r.err -like '*nvalid choice*') {
                    $script:Run.LcUnsupported = $true
                    $what = if ($script:O.AwsBackend -eq 'Cli') { 'AWS CLI' } else { 'AWS.Tools.RDS' }   # Cli: the Bash wording
                    $fix = if ($script:O.AwsBackend -eq 'Cli') { 'the CLI' } else { 'the module' }
                    Write-PcrWarn "This $what has no 'rds describe-db-major-engine-versions' (upgrade $fix); support end dates show 'unknown'"
                }
                else { Write-PcrWarn "[$pl/$Region] lifecycle lookup for $engine failed ($($r.err)); support end dates show 'unknown'" }
                $script:Run.LcCache[$lk] = $null
            }
        }
        if ($script:Run.LcCache.ContainsKey($lk) -and $null -ne $script:Run.LcCache[$lk]) { $lc[$engine] = $script:Run.LcCache[$lk] }
    }
    return @{ ev = $ev; lc = $lc }
}

# ---------------------------------------------------------------------------------------------- one region
# Invoke-PcrRegionScan (Bash collect_region): clusters, instances, pending actions, versions -> rows
function Invoke-PcrRegionScan {
    param([string]$ProfileName, [string]$Account, [string]$Region)
    $pl = if ($ProfileName) { $ProfileName } else { 'default' }
    $rc = Invoke-PcrAws $ProfileName $Region 'rds describe-db-clusters'
    if (-not $rc.ok) { Add-PcrError $Account $ProfileName $Region 'rds describe-db-clusters' $rc.err; return }
    $ri = Invoke-PcrAws $ProfileName $Region 'rds describe-db-instances'
    if (-not $ri.ok) { Add-PcrError $Account $ProfileName $Region 'rds describe-db-instances' $ri.err; return }
    $clusters = @(@(Get-JqField $rc.data 'DBClusters') | Where-Object { $null -ne $_ })
    $instances = @(@(Get-JqField $ri.data 'DBInstances') | Where-Object { $null -ne $_ })
    $rp = Invoke-PcrAws $ProfileName $Region 'rds describe-pending-maintenance-actions'
    if ($rp.ok) { $pma = @(@(Get-JqField $rp.data 'PendingMaintenanceActions') | Where-Object { $null -ne $_ }) }
    else { Add-PcrError $Account $ProfileName $Region 'rds describe-pending-maintenance-actions' "$($rp.err) (pending_actions shown as 0)"; $pma = @() }
    Write-PcrInfo "[$pl/$Region] $($clusters.Count) cluster(s), $($instances.Count) instance(s), $($pma.Count) resource(s) with pending maintenance"
    $vd = Get-PcrVersionData $ProfileName $Region $clusters $instances
    $rows = New-ComplianceRows -Account $Account -ProfileName $pl -Region $Region -Clusters $clusters -Instances $instances -Pma $pma `
        -Ev $vd.ev -Lc $vd.lc -Filters (Get-PcrFilters) -Now $script:Run.Now -MaxBehind $script:O.MaxBehind -WarnDays $script:O.WarnDays -OracleAny $script:O.OracleAnyLine
    foreach ($w in $rows) {
        foreach ($x in @($w['version_warnings'])) { if ($x) { Write-PcrDebug "[$pl/$Region] $($w['identifier']): $x" } }
        foreach ($x in @($w['excluded_targets'])) { if ($x) { Write-PcrDebug "[$pl/$Region] $($w['identifier']): $($x['reason'])" } }
        $script:Run.Rows.Add($w)
        $script:Run.RowKeys.Add("p$($script:Run.ProfileIdx)/$Region/rows.json")   # Bash: find WORK -name rows.json | sort
    }
    $summary = @(foreach ($g in (Group-JqBy $rows { param($r) , @($r['compliance_status']) })) { "$($g[0]['compliance_status'])=$($g.Count)" }) -join ' '
    Write-PcrInfo "[$pl/$Region] $(if ($summary) { $summary } else { 'no matching servers' })"
}

# ---------------------------------------------------------------------------------------------- discovery (-AllRegions)
# Invoke-PcrDiscovery (Bash discover_regions): probe every region, -ProbeParallel at a time
# (ForEach-Object -Parallel runspaces; 1 = in this runspace). Returns region -> probe result
function Invoke-PcrDiscovery {
    param([string]$ProfileName, [string]$Account, [string[]]$Regions)
    $pl = if ($ProfileName) { $ProfileName } else { 'default' }
    $n = $script:O.ProbeParallel
    Write-PcrInfo "[$pl] discovery: probing $($Regions.Count) region(s), $n at a time"
    $backend = $script:O.AwsBackend; $to = $script:O.AwsTimeout; $ma = $script:O.MaxAttempts
    if ($n -le 1 -or $Regions.Count -le 1) {
        $results = foreach ($r in $Regions) { & $script:ProbeBlock $backend $ProfileName $r $to $ma }
    }
    else {
        $probeText = $script:ProbeBlock.ToString()
        $results = $Regions | ForEach-Object -ThrottleLimit $n -Parallel {
            $sb = [scriptblock]::Create($using:probeText)
            & $sb $using:backend $using:ProfileName $_ $using:to $using:ma
        }
    }
    $by = @{}
    foreach ($x in @($results)) { if ($x) { $by[$x.region] = $x } }
    foreach ($r in $Regions) {
        $script:Run.AwsCalls += 2   # the probes ran in other runspaces: count their calls here
        if (-not $by.ContainsKey($r)) {
            $by[$r] = [pscustomobject]@{ region = $r; instances = $null; clusters = $null; errors = @(@{ call = 'rds discovery probe'; message = 'probe produced no result' }) }
        }
        foreach ($e in @($by[$r].errors)) {
            if (-not $e) { continue }
            $script:Run.AwsFails++
            Write-PcrError "[$pl/$r] discovery probe '$($e.call)' failed: $($e.message)"
            Add-PcrError $Account $ProfileName $r $e.call "$($e.message) (region scanned in full anyway)"
        }
    }
    return $by
}
# Add-PcrRegionStatus (Bash region_status): how a region was handled (scanned | databases | empty | probe-error)
function Add-PcrRegionStatus {
    param([string]$Account, [string]$ProfileName, [string]$Region, [string]$Status, $Probe)
    $o = New-JqObject ([ordered]@{ account = $Account; profile = $(if ($ProfileName) { $ProfileName } else { 'default' }); region = $Region; status = $Status })
    if ($null -ne $Probe) { $o['probe_instances'] = $Probe.instances; $o['probe_clusters'] = $Probe.clusters }
    $script:Run.RegionStatus.Add($o)
}

# ---------------------------------------------------------------------------------------------- one profile
# Invoke-PcrProfileScan (Bash collect_profile): credentials, account, name, regions, scan, global databases
function Invoke-PcrProfileScan {
    param([string]$ProfileName)
    $O = $script:O; $pl = if ($ProfileName) { $ProfileName } else { 'default' }
    $base = if ($O.Regions.Count) { $O.Regions[0] } else { Get-PcrDefaultRegion $ProfileName }
    if (-not $base) {
        if ($O.AllRegions) { $base = 'us-east-1' }
        else { Add-PcrError '-' $ProfileName '-' 'region' 'no region given and profile has none'; return $false }
    }
    $sts = Invoke-PcrAws $ProfileName $base 'sts get-caller-identity'
    if (-not $sts.ok) {
        $hint = if ($sts.err -match 'sso' -or $sts.err -match '[Ee]xpired') { " (run: aws sso login$(if ($ProfileName) { " --profile $ProfileName" }))" } else { '' }
        Add-PcrError '-' $ProfileName '-' 'sts get-caller-identity' "credentials invalid: $($sts.err)$hint"
        return $false
    }
    $account = [string]$sts.data['Account']
    Write-PcrInfo "Profile ${pl}: account $account ($($sts.data['Arn']))"
    $aname = Get-JqField $O.AccountNames $account
    if (-not $aname) {   # IAM account alias: optional, read-only; denied / none = number only
        $al = Invoke-PcrAws $ProfileName $base 'iam list-account-aliases' -Soft
        if ($al.ok) {
            $first = @(Get-JqField $al.data 'AccountAliases')
            $aname = if ($first.Count -and $null -ne $first[0]) { [regex]::Replace([string]$first[0], '[\x00-\x1f]', '') } else { '' }
            if ($aname.Length -gt 64) { $aname = $aname.Substring(0, 64) }
        }
        else { Write-PcrDebug "Account alias for $account not available (iam:ListAccountAliases)"; $aname = '' }
    }
    $script:Run.Accounts.Add((New-JqObject ([ordered]@{ account = $account; profile = $pl; name = [string]$aname })))
    if ($O.AllRegions) {
        $rr = Invoke-PcrAws $ProfileName $base 'ec2 describe-regions'
        if (-not $rr.ok) { Add-PcrError $account $ProfileName '-' 'ec2 describe-regions' $rr.err; return $true }
        $regions = [string[]]@(@(Get-JqField $rr.data 'Regions') | ForEach-Object { $_['RegionName'] })
        [Array]::Sort($regions, [System.StringComparer]::Ordinal)
    }
    elseif ($O.Regions.Count) { $regions = @($O.Regions) }
    else { $regions = @($base) }
    $probes = $null
    if ($O.AllRegions -and $O.Discover -and $regions.Count) { $probes = Invoke-PcrDiscovery $ProfileName $account $regions }
    foreach ($region in $regions) {
        $script:Run.RegionsSeen.Add($region)
        $st = 'scanned'; $pf = $null
        if ($O.AllRegions -and $O.Discover) {
            $pf = $probes[$region]
            $st = if (@($pf.errors | Where-Object { $_ }).Count -gt 0) { 'probe-error' } elseif (([long]$pf.instances + [long]$pf.clusters) -gt 0) { 'databases' } else { 'empty' }
        }
        Add-PcrRegionStatus $account $ProfileName $region $st $pf
        if ($st -eq 'empty') { Write-PcrDebug "[$pl/$region] discovery: no DB instance or cluster; skipped"; continue }
        Invoke-PcrRegionScan $ProfileName $account $region
    }
    Invoke-PcrGlobalScan $ProfileName $account $base
    return $true
}
# Invoke-PcrGlobalScan (Bash collect_globals): one describe-global-clusters per account, only when an Aurora
# cluster was found. A failure is a warning: those clusters show global database "unknown".
function Invoke-PcrGlobalScan {
    param([string]$ProfileName, [string]$Account, [string]$Region)
    $pl = if ($ProfileName) { $ProfileName } else { 'default' }
    $st = 'ok'; $msg = ''; $n = [long]0
    if (@($script:Run.Rows | Where-Object { $_['account_id'] -eq $Account -and $_['profile'] -eq $pl -and $_['resource_type'] -eq 'aurora-cluster' }).Count -eq 0) { $st = 'not-needed' }
    else {
        $g = Invoke-PcrAws $ProfileName $Region 'rds describe-global-clusters' -Soft
        if ($g.ok) {
            $list = @(@(Get-JqField $g.data 'GlobalClusters') | Where-Object { $null -ne $_ })
            foreach ($x in $list) {
                $script:Run.Globals.Add((New-JqObject ([ordered]@{
                                account = $Account; id = $x['GlobalClusterIdentifier']; arn = $x['GlobalClusterArn']
                                engine = $(if (Test-JqTruthy (Get-JqField $x 'Engine')) { $x['Engine'] } else { '' })
                                version = $(if (Test-JqTruthy (Get-JqField $x 'EngineVersion')) { $x['EngineVersion'] } else { '' })
                                status = $(if (Test-JqTruthy (Get-JqField $x 'Status')) { $x['Status'] } else { '' })
                                members = @(foreach ($m in @(Get-JqField $x 'GlobalClusterMembers')) {
                                        if ($null -eq $m) { continue }
                                        $parts = ([string]$m['DBClusterArn']).Split(':')
                                        New-JqObject ([ordered]@{ arn = $m['DBClusterArn']; region = $parts[3]; cluster = $parts[-1]; role = $(if ((Get-JqField $m 'IsWriter') -eq $true) { 'primary' } else { 'secondary' }) })
                                    })
                            })))
            }
            $n = [long]$list.Count
            Write-PcrInfo "[$pl] $n Aurora global database(s)"
        }
        else {
            $st = 'error'; $msg = $g.err
            Write-PcrWarn "[$pl/$Region] rds describe-global-clusters failed: $msg (Aurora clusters show global database `"unknown`")"
        }
    }
    $script:Run.GlobalLookup.Add((New-JqObject ([ordered]@{ account = $Account; profile = $pl; region = $Region; status = $st; message = $msg; count = $n })))
}

# ---------------------------------------------------------------------------------------------- report assembly
# New-PcrRawReport (Bash build_report, before finalize): {meta, rows, errors}
function New-PcrRawReport {
    $O = $script:O; $now = $script:Run.Now
    $regs = Get-JqUnique @($script:Run.RegionsSeen)
    $meta = New-JqObject ([ordered]@{
            script = $script:ScriptName; version = $script:ScriptVersion
            generated_utc = (Format-PcrUtc $now); generated_local = (Format-PcrLocal $now $O.Tz); tz = $O.Tz; host = [System.Net.Dns]::GetHostName()
            accounts = @($script:Run.Accounts); regions = $regs; tag_columns = @(); max_behind = [long]$O.MaxBehind; warn_days = [long]$O.WarnDays
            filters = (Get-PcrFilters); filters_text = (Get-PcrFiltersText)
            region_discovery = (New-JqObject ([ordered]@{ mode = $O.RegionMode; probe_parallel = $(if ($O.RegionMode -eq 'discover') { [long]$O.ProbeParallel } else { $null }) }))
            region_status = @($script:Run.RegionStatus); globals = @($script:Run.Globals); global_lookup = @($script:Run.GlobalLookup)
            aws_calls = [long]$script:Run.AwsCalls; aws_failures = [long]$script:Run.AwsFails; lifecycle_api = (-not $script:Run.LcUnsupported)
            oracle_any_patch_line = [bool]$O.OracleAnyLine
        })
    # row order = Bash `find "$WORK" -name rows.json | sort`: profile index, then region (byte order), stable inside one region
    $n = $script:Run.Rows.Count
    $keys = [string[]]::new($n); $sorted = [int[]]::new($n)
    for ($i = 0; $i -lt $n; $i++) { $keys[$i] = $script:Run.RowKeys[$i] + [char]0 + $i.ToString('D9'); $sorted[$i] = $i }   # index suffix = stable
    [Array]::Sort($keys, $sorted, [System.StringComparer]::Ordinal)
    $rows = @(foreach ($i in $sorted) { $script:Run.Rows[$i] })
    return (New-JqObject ([ordered]@{ meta = $meta; rows = $rows; errors = @($script:Run.Errors) }))
}

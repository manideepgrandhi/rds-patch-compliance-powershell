# src/Aws.ps1 - read-only AWS access. Two interchangeable back ends return the SAME response shape
# (the JSON the AWS CLI prints), so everything after this file is back-end neutral:
#   AwsTools (default): AWS.Tools cmdlets (Get-RDSDBCluster ...). SDK objects are flattened to plain
#                       ordered objects; DateTime -> "yyyy-MM-ddTHH:mm:ss+00:00"; unset fields are left out.
#   Cli               : the AWS CLI v2, exactly as the Bash tool calls it (also how the tests feed the shared mock).
# Only describe / list / get calls exist here. Nothing can modify AWS.

# Call name (as the Bash tool and the error list call it) -> AWS.Tools cmdlet + response wrapper key
$script:AwsOps = @{
    'sts get-caller-identity'                 = @{ Cmd = 'Get-STSCallerIdentity'; Wrap = $null; Module = 'AWS.Tools.SecurityToken'; Op = 'GetCallerIdentity' }
    'iam list-account-aliases'                = @{ Cmd = 'Get-IAMAccountAlias'; Wrap = 'AccountAliases'; Module = 'AWS.Tools.IdentityManagement'; Op = 'ListAccountAliases' }
    'ec2 describe-regions'                    = @{ Cmd = 'Get-EC2Region'; Wrap = 'Regions'; Module = 'AWS.Tools.EC2'; Op = 'DescribeRegions' }
    'rds describe-db-clusters'                = @{ Cmd = 'Get-RDSDBCluster'; Wrap = 'DBClusters'; Module = 'AWS.Tools.RDS'; Op = 'DescribeDBClusters' }
    'rds describe-db-instances'               = @{ Cmd = 'Get-RDSDBInstance'; Wrap = 'DBInstances'; Module = 'AWS.Tools.RDS'; Op = 'DescribeDBInstances' }
    'rds describe-pending-maintenance-actions' = @{ Cmd = 'Get-RDSPendingMaintenanceAction'; Wrap = 'PendingMaintenanceActions'; Module = 'AWS.Tools.RDS'; Op = 'DescribePendingMaintenanceActions' }
    'rds describe-global-clusters'            = @{ Cmd = 'Get-RDSGlobalCluster'; Wrap = 'GlobalClusters'; Module = 'AWS.Tools.RDS'; Op = 'DescribeGlobalClusters' }
    'rds describe-db-engine-versions'         = @{ Cmd = 'Get-RDSDBEngineVersion'; Wrap = 'DBEngineVersions'; Module = 'AWS.Tools.RDS'; Op = 'DescribeDBEngineVersions' }
    'docdb describe-db-engine-versions'       = @{ Cmd = 'Get-DOCDBEngineVersion'; Wrap = 'DBEngineVersions'; Module = 'AWS.Tools.DocDB'; Op = 'DescribeDBEngineVersions' }
    'neptune describe-db-engine-versions'     = @{ Cmd = 'Get-NPTDBEngineVersion'; Wrap = 'DBEngineVersions'; Module = 'AWS.Tools.Neptune'; Op = 'DescribeDBEngineVersions' }
    'rds describe-db-major-engine-versions'   = @{ Cmd = 'Get-RDSDBMajorEngineVersion'; Wrap = 'DBMajorEngineVersions'; Module = 'AWS.Tools.RDS'; Op = 'DescribeDBMajorEngineVersions' }
}
# Only these SDK properties are copied (the fields the report reads; keeps --KeepWorkdir dumps small)
$script:SdkKeep = [System.Collections.Generic.HashSet[string]]::new([string[]]@(
        'Account', 'Arn', 'UserId', 'RegionName', 'Endpoint', 'OptInStatus',
        'DBClusterIdentifier', 'DBClusterArn', 'Engine', 'EngineVersion', 'PreferredMaintenanceWindow', 'TagList', 'Key', 'Value',
        'DBClusterMembers', 'DBInstanceIdentifier', 'IsClusterWriter', 'AutoMinorVersionUpgrade', 'DBInstanceArn',
        'ResourceIdentifier', 'PendingMaintenanceActionDetails', 'Action', 'Description', 'AutoAppliedAfterDate', 'ForcedApplyDate', 'CurrentApplyDate',
        'MajorEngineVersion', 'DBParameterGroupFamily', 'ValidUpgradeTarget', 'IsMajorVersionUpgrade', 'AutoUpgrade',
        'SupportedEngineLifecycles', 'LifecycleSupportName', 'LifecycleSupportStartDate', 'LifecycleSupportEndDate',
        'GlobalClusterIdentifier', 'GlobalClusterArn', 'Status', 'GlobalClusterMembers', 'IsWriter'))

# ---------------------------------------------------------------------------------------------- SDK -> CLI shape
# ConvertFrom-PcrSdkObject: an AWS SDK object (or a test double) -> ordered object with the CLI's field names
function ConvertFrom-PcrSdkObject {
    param($Obj, [int]$Depth = 0)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [string] -or $Obj -is [bool] -or (Test-JqNumber $Obj)) { return $Obj }
    if ($Obj -is [datetime]) {
        $d = if ($Obj.Kind -eq [System.DateTimeKind]::Local) { $Obj.ToUniversalTime() } else { $Obj }   # SDK v4: UTC; Unspecified = UTC
        return $d.ToString("yyyy-MM-dd'T'HH:mm:ss'+00:00'", $script:Inv)
    }
    if ($Obj -is [DateTimeOffset]) { return $Obj.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'+00:00'", $script:Inv) }
    if ($Obj.GetType().FullName -eq 'Amazon.Runtime.ConstantClass' -or ($Obj.GetType().BaseType -and $Obj.GetType().BaseType.FullName -eq 'Amazon.Runtime.ConstantClass')) { return [string]$Obj.Value }
    if ($Obj -is [System.Collections.IDictionary]) {
        $o = New-JqObject; foreach ($k in $Obj.Keys) { if ($script:SdkKeep.Contains([string]$k) -and $null -ne $Obj[$k]) { $o[[string]$k] = ConvertFrom-PcrSdkObject $Obj[$k] ($Depth + 1) } }
        return , $o
    }
    if ($Obj -is [System.Collections.IEnumerable]) { return , @(foreach ($x in $Obj) { , (ConvertFrom-PcrSdkObject $x ($Depth + 1)) }) }
    if ($Depth -gt 8) { return [string]$Obj }
    $o = New-JqObject
    $type = $Obj.GetType()
    foreach ($p in $Obj.PSObject.Properties) {
        if (-not $script:SdkKeep.Contains($p.Name)) { continue }
        # SDK v3 (AWS.Tools 4.x) has non-nullable bools/dates: ask the internal IsSetX() so an unset field stays absent (like the CLI)
        $isSet = $type.GetMethod("IsSet$($p.Name)", [System.Reflection.BindingFlags]'Instance,NonPublic,Public')
        if ($isSet -and $isSet.GetParameters().Count -eq 0) { try { if (-not $isSet.Invoke($Obj, $null)) { continue } } catch { Write-Debug "IsSet failed: $_" } }
        $v = $p.Value
        if ($null -eq $v) { continue }
        $o[$p.Name] = ConvertFrom-PcrSdkObject $v ($Depth + 1)
    }
    return , $o
}

# ---------------------------------------------------------------------------------------------- client settings
# Get-PcrClientConfig: per-service SDK config with the -AwsTimeout / -MaxAttempts settings (standard retry mode).
# Regional services (RDS, DocDB, Neptune, EC2) also sign for $Region explicitly: with an endpoint override
# (AWS_ENDPOINT_URL, a VPC endpoint, the test endpoint) the SDK would otherwise guess the signing region from
# the URL. STS / IAM keep the SDK default (IAM is global and signs for us-east-1).
function Get-PcrClientConfig {
    param([string]$Module, [string]$Region)
    $type = switch ($Module) {
        'AWS.Tools.RDS' { 'Amazon.RDS.AmazonRDSConfig' } 'AWS.Tools.EC2' { 'Amazon.EC2.AmazonEC2Config' }
        'AWS.Tools.SecurityToken' { 'Amazon.SecurityToken.AmazonSecurityTokenServiceConfig' } 'AWS.Tools.IdentityManagement' { 'Amazon.IdentityManagement.AmazonIdentityManagementServiceConfig' }
        'AWS.Tools.DocDB' { 'Amazon.DocDB.AmazonDocDBConfig' } 'AWS.Tools.Neptune' { 'Amazon.Neptune.AmazonNeptuneConfig' }
    }
    $t = $type -as [type]
    if (-not $t) { return $null }
    $c = $t::new()
    $c.Timeout = [TimeSpan]::FromSeconds($script:O.AwsTimeout)
    $c.MaxErrorRetry = [Math]::Max(0, $script:O.MaxAttempts - 1)
    try { $c.RetryMode = [Amazon.Runtime.RequestRetryMode]::Standard } catch { Write-Debug "RetryMode not settable: $_" }
    if ($Region -and $Module -in 'AWS.Tools.RDS', 'AWS.Tools.EC2', 'AWS.Tools.DocDB', 'AWS.Tools.Neptune') { $c.AuthenticationRegion = $Region }
    return $c
}
# Format-PcrAwsError: error text in the AWS CLI's words ("An error occurred (Code) when calling the Op operation: msg")
function Format-PcrAwsError {
    param($ErrorRecord, [string]$Op)
    $ex = $ErrorRecord.Exception
    while ($ex -and $ex.InnerException -and -not ($ex.PSObject.Properties['ErrorCode'] -and $ex.ErrorCode)) { $ex = $ex.InnerException }
    $msg = if ($ex.PSObject.Properties['ErrorCode'] -and $ex.ErrorCode) { "An error occurred ($($ex.ErrorCode)) when calling the $Op operation: $($ex.Message)" }
    else {
        # a service error with no error code (e.g. HTTP 400 with an empty body): the CLI prints the HTTP status
        $svc = $ErrorRecord.Exception
        while ($svc -and -not ($svc -is [Amazon.Runtime.AmazonServiceException])) { $svc = $svc.InnerException }
        if ($svc -and [int]$svc.StatusCode -gt 0) {
            $reason = [System.Net.Http.HttpResponseMessage]::new($svc.StatusCode).ReasonPhrase
            "An error occurred ($([int]$svc.StatusCode)) when calling the $Op operation: $reason"
        }
        else { [string]$ErrorRecord.Exception.Message }
    }
    return (Compress-PcrError $msg)
}
# Compress-PcrError (Bash: tr -s '\n' ' ' | sed ...): one line, no "aws: [ERROR]: ", at most 400 characters
function Compress-PcrError {
    param([AllowNull()][string]$Text)
    $t = ([string]$Text) -replace "`r", '' -replace "`n", ' ' -replace ' {2,}', ' '
    $t = $t.Replace('aws: [ERROR]: ', '').Trim()
    if ($t.Length -gt 400) { $t = $t.Substring(0, 400) + '...' }
    return $t
}

# ---------------------------------------------------------------------------------------------- one call
# Invoke-PcrAws: one read-only call -> @{ ok; data (CLI-shaped); err }. Counts calls / failures like aws_call.
#   -Soft: a supplementary lookup (version / lifecycle / alias / globals): a failure is logged at DEBUG only
function Invoke-PcrAws {
    param([string]$ProfileName, [string]$Region, [string]$Call, [hashtable]$Params = @{}, [switch]$Soft)
    $script:Run.AwsCalls++
    $pl = if ($ProfileName) { $ProfileName } else { 'default' }
    $shown = @(foreach ($k in 'engine', 'engine-version') { if ($Params.ContainsKey($k)) { " --$k $($Params[$k])" } }) -join ''
    Write-PcrDebug "[$pl/$Region] aws $Call$shown"   # same text as the Bash debug line
    $res = if ($script:O.AwsBackend -eq 'Cli') { Invoke-PcrAwsCli $ProfileName $Region $Call $Params } else { Invoke-PcrAwsTools $ProfileName $Region $Call $Params }
    if ($res.ok) {
        if ($script:Run.WorkDir) { Save-PcrRaw $pl $Region $Call $Params $res.data }
        return $res
    }
    if (-not $res.err) { $res.err = 'invalid or empty response' }
    $rcText = if ($null -ne $res.rc) { $res.rc } else { 255 }
    if ($Soft) { Write-PcrDebug "[$pl/$Region] 'aws $Call' failed (rc=$rcText): $($res.err)"; return $res }
    $script:Run.AwsFails++
    Write-PcrError "[$pl/$Region] 'aws $Call' failed (rc=$rcText): $($res.err)"
    return $res
}
# Save-PcrRaw: -KeepWorkdir keeps every raw response (one JSON file per call) for debugging
function Save-PcrRaw {
    param([string]$ProfileName, [string]$Region, [string]$Call, [hashtable]$Params, $Data)
    $name = ("{0}_{1}_{2}_{3}" -f $ProfileName, $Region, $Call, (@($Params.Values) -join '_')) -replace '[^A-Za-z0-9._-]', '_'
    $script:Run.RawSeq++
    try { [System.IO.File]::WriteAllText((Join-Path $script:Run.WorkDir ('{0:0000}_{1}.json' -f $script:Run.RawSeq, $name)), (ConvertTo-JqJson $Data)) } catch { Write-Debug "raw save failed: $_" }
}
# Invoke-PcrAwsTools: the AWS.Tools back end
function Invoke-PcrAwsTools {
    param([string]$ProfileName, [string]$Region, [string]$Call, [hashtable]$Params)
    $op = $script:AwsOps[$Call]
    $a = @{ ErrorAction = 'Stop' }
    if ($Region) { $a.Region = $Region }
    if ($ProfileName) { $a.ProfileName = $ProfileName }
    $cfg = Get-PcrClientConfig $op.Module $Region
    if ($cfg) { $a.ClientConfig = $cfg }
    if ($Params.ContainsKey('engine')) { $a.Engine = $Params.engine }
    if ($Params.ContainsKey('engine-version')) { $a.EngineVersion = $Params['engine-version'] }
    if ($Call -eq 'ec2 describe-regions') { }   # enabled regions only (no -AllRegion), like the CLI default
    try {
        $out = @(& $op.Cmd @a)
    }
    catch [System.Management.Automation.CommandNotFoundException] {
        return @{ ok = $false; err = "Invalid choice: $($op.Cmd) is not available (install / update $($op.Module))"; missing = $true; rc = 252 }
    }
    catch { $e = Format-PcrAwsError $_ $op.Op; return @{ ok = $false; err = $e; rc = $(if ($e.StartsWith('An error occurred (')) { 254 } else { 255 }) } }   # the AWS CLI's exit codes
    if ($null -eq $op.Wrap) {
        $o = if ($out.Count) { ConvertFrom-PcrSdkObject $out[0] } else { New-JqObject }
        return @{ ok = $true; data = $o }
    }
    $items = @(foreach ($x in $out) { , (ConvertFrom-PcrSdkObject $x) })
    $d = New-JqObject; $d[$op.Wrap] = $items
    return @{ ok = $true; data = $d }
}
# Get-PcrCliBase: the AWS CLI argument prefix (same flags as the Bash aws_base)
function Get-PcrCliBase {
    param([string]$ProfileName, [string]$Region)
    $a = @('--output', 'json', '--no-cli-pager', '--cli-connect-timeout', [string]$script:O.AwsTimeout, '--cli-read-timeout', [string]$script:O.AwsTimeout)
    if ($ProfileName) { $a += @('--profile', $ProfileName) }
    if ($Region) { $a += @('--region', $Region) }
    return , $a
}
# Invoke-PcrAwsCli: the AWS CLI back end (aws must be on PATH)
function Invoke-PcrAwsCli {
    param([string]$ProfileName, [string]$Region, [string]$Call, [hashtable]$Params)
    $a = (Get-PcrCliBase $ProfileName $Region) + $Call.Split(' ')
    foreach ($k in @('engine', 'engine-version')) { if ($Params.ContainsKey($k)) { $a += @("--$k", [string]$Params[$k]) } }
    $env:AWS_PAGER = ''; $env:AWS_MAX_ATTEMPTS = [string]$script:O.MaxAttempts
    if (-not $env:AWS_RETRY_MODE) { $env:AWS_RETRY_MODE = 'standard' }
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $outText = (& aws @a 2>$errFile) -join "`n"
        $rc = $LASTEXITCODE
        $errText = [System.IO.File]::ReadAllText($errFile)
    }
    catch { return @{ ok = $false; err = (Compress-PcrError $_.Exception.Message); rc = 127 } }
    finally { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }
    if ($rc -eq 0) {
        try { $data = ConvertFrom-JqJson $outText; return @{ ok = $true; data = $data } } catch { Write-Debug "bad JSON: $_" }
    }
    $e = Compress-PcrError $errText
    if (-not $e) { $e = "exit $rc, invalid or empty JSON output" }
    return @{ ok = $false; err = $e; rc = $rc }
}

# ---------------------------------------------------------------------------------------------- region discovery probe
# The probe is a self-contained script block (no module state) so it runs unchanged inside
# ForEach-Object -Parallel runspaces. Two one-page calls (max 20 records, no paging) per region.
$script:ProbeBlock = {
    param([string]$Backend, [string]$ProfileName, [string]$Region, [int]$Timeout, [int]$MaxAttempts)
    # One: one probe call ('i' = instances, 'c' = clusters) -> @{ n = count or $null; e = error text }
    function One([string]$Kind) {
        try {
            if ($Backend -eq 'Cli') {
                $args2 = @('--output', 'json', '--no-cli-pager', '--cli-connect-timeout', [string]$Timeout, '--cli-read-timeout', [string]$Timeout)
                if ($ProfileName) { $args2 += @('--profile', $ProfileName) }
                $args2 += @('--region', $Region)
                $args2 += if ($Kind -eq 'i') { @('rds', 'describe-db-instances', '--max-records', '20', '--query', 'length(DBInstances)', '--no-paginate') }
                else { @('rds', 'describe-db-clusters', '--max-records', '20', '--query', 'length(DBClusters)', '--no-paginate') }
                $ef = [System.IO.Path]::GetTempFileName()
                try { $o = (& aws @args2 2>$ef) -join ''; $rc = $LASTEXITCODE; $et = [System.IO.File]::ReadAllText($ef) } finally { Remove-Item -LiteralPath $ef -Force -ErrorAction SilentlyContinue }
                $o = $o -replace '\s', ''
                if ($rc -eq 0 -and $o -match '^[0-9]+$') { return @{ n = [long]$o; e = '' } }
                $e = (($et -replace "`r", '' -replace "`n", ' ' -replace ' {2,}', ' ').Replace('aws: [ERROR]: ', '')).Trim()
                if (-not $e) { $e = "exit $rc, not a number: $($o.Substring(0, [Math]::Min(80, $o.Length)))" }
                if ($e.Length -gt 400) { $e = $e.Substring(0, 400) + '...' }
                return @{ n = $null; e = $e }
            }
            $p = @{ Region = $Region; MaxRecord = 20; NoAutoIteration = $true; ErrorAction = 'Stop' }
            if ($ProfileName) { $p.ProfileName = $ProfileName }
            $cfg = [Amazon.RDS.AmazonRDSConfig]::new(); $cfg.Timeout = [TimeSpan]::FromSeconds($Timeout); $cfg.MaxErrorRetry = [Math]::Max(0, $MaxAttempts - 1); $cfg.AuthenticationRegion = $Region
            $p.ClientConfig = $cfg
            $items = if ($Kind -eq 'i') { @(Get-RDSDBInstance @p) } else { @(Get-RDSDBCluster @p) }
            return @{ n = [long]$items.Count; e = '' }
        }
        catch {
            $ex = $_.Exception; while ($ex.InnerException -and -not $ex.PSObject.Properties['ErrorCode']) { $ex = $ex.InnerException }
            $op = if ($Kind -eq 'i') { 'DescribeDBInstances' } else { 'DescribeDBClusters' }
            $m = if ($ex.PSObject.Properties['ErrorCode'] -and $ex.ErrorCode) { "An error occurred ($($ex.ErrorCode)) when calling the $op operation: $($ex.Message)" } else { $_.Exception.Message }
            if ($m.Length -gt 400) { $m = $m.Substring(0, 400) + '...' }
            return @{ n = $null; e = $m }
        }
    }
    $i = One 'i'; $c = One 'c'
    $errs = @()
    if ($i.e) { $errs += @{ call = 'rds describe-db-instances (discovery probe)'; message = $i.e } }
    if ($c.e) { $errs += @{ call = 'rds describe-db-clusters (discovery probe)'; message = $c.e } }
    [pscustomobject]@{ region = $Region; instances = $i.n; clusters = $c.n; errors = $errs }
}

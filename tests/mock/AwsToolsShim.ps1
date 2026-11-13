# tests/mock/AwsToolsShim.ps1 - test double for the AWS.Tools back end.
# Defines global functions with the AWS.Tools cmdlet names (functions win over cmdlets in PowerShell
# command lookup). Each one asks the shared mock `aws` (tests/mock/aws) for the same data and turns the
# CLI JSON into REAL AWS SDK model objects (Amazon.RDS.Model.DBCluster ...) by reflection, so the
# report's SDK -> CLI-shape conversion (ConvertFrom-PcrSdkObject) is exercised end to end.
# Service errors are thrown as real SDK service exceptions with ErrorCode set, like AWS.Tools does.
# Limitation: global functions are not visible inside ForEach-Object -Parallel runspaces, so use
# -ProbeParallel 1 (or explicit regions) with this shim.

Import-Module AWS.Tools.Common, AWS.Tools.RDS, AWS.Tools.EC2, AWS.Tools.SecurityToken, AWS.Tools.IdentityManagement, AWS.Tools.DocDB, AWS.Tools.Neptune -ErrorAction Stop

# ConvertTo-ShimSdk: CLI JSON value -> instance of $Type (recursive, by property name)
function global:ConvertTo-ShimSdk {
    param($Json, [type]$Type)
    if ($null -eq $Json) { return $null }
    $u = [Nullable]::GetUnderlyingType($Type); if ($u) { $Type = $u }
    if ($Type -eq [string]) { return [string]$Json }
    if ($Type -eq [bool]) { return [bool]$Json }
    if ($Type -eq [int]) { return [int]$Json }
    if ($Type -eq [long]) { return [long]$Json }
    if ($Type -eq [datetime]) {
        if ($Json -is [datetime]) { return $Json.ToUniversalTime() }
        return [DateTimeOffset]::Parse([string]$Json, [cultureinfo]::InvariantCulture).UtcDateTime
    }
    if ($Type.IsGenericType -and $Type.GetGenericTypeDefinition() -eq [System.Collections.Generic.List`1]) {
        $et = $Type.GetGenericArguments()[0]
        $list = [Activator]::CreateInstance($Type)
        foreach ($x in @($Json)) { $list.Add((ConvertTo-ShimSdk $x $et)) }
        return , $list
    }
    if ([Amazon.Runtime.ConstantClass].IsAssignableFrom($Type)) { return $Type::FindValue([string]$Json) }
    $o = [Activator]::CreateInstance($Type)
    foreach ($p in $Json.PSObject.Properties) {
        $prop = $Type.GetProperty($p.Name)
        if (-not $prop -or -not $prop.CanWrite) { continue }
        $prop.SetValue($o, (ConvertTo-ShimSdk $p.Value $prop.PropertyType))
    }
    return $o
}

# Invoke-ShimAws: run the mock CLI; throw like AWS.Tools on failure; return parsed JSON
function global:Invoke-ShimAws {
    param([string[]]$CliArgs, [hashtable]$Common, [type]$ExceptionType)
    $a = @('--output', 'json', '--no-cli-pager')
    if ($Common.ProfileName) { $a += @('--profile', $Common.ProfileName) }
    if ($Common.Region) { $a += @('--region', $Common.Region) }
    $ef = [System.IO.Path]::GetTempFileName()
    try { $out = (& aws @a @CliArgs 2>$ef) -join "`n"; $rc = $LASTEXITCODE; $err = [System.IO.File]::ReadAllText($ef) }
    finally { Remove-Item -LiteralPath $ef -Force -ErrorAction SilentlyContinue }
    if ($rc -ne 0) {
        $err = ($err -replace '\s+', ' ').Replace('aws: [ERROR]: ', '').Trim()
        if ($err -match '^An error occurred \(([^)]+)\) when calling the \S+ operation: (.*)$') {
            $ex = [Activator]::CreateInstance($ExceptionType, [object[]]@($Matches[2]))
            $ex.ErrorCode = $Matches[1]
            throw $ex
        }
        throw [System.InvalidOperationException]::new($err)
    }
    return ($out | ConvertFrom-Json -DateKind String)
}

function global:New-ShimCommon { param($B) $h = @{}; foreach ($k in 'Region', 'ProfileName') { if ($B.ContainsKey($k)) { $h[$k] = $B[$k] } }; $h }


function global:Get-STSCallerIdentity { [CmdletBinding()] param($Region, $ProfileName, $ClientConfig)
    $j = Invoke-ShimAws @('sts', 'get-caller-identity') (New-ShimCommon $PSBoundParameters) ([Amazon.SecurityToken.AmazonSecurityTokenServiceException])
    ConvertTo-ShimSdk $j ([Amazon.SecurityToken.Model.GetCallerIdentityResponse]) }
function global:Get-IAMAccountAlias { [CmdletBinding()] param($Region, $ProfileName, $ClientConfig)
    $j = Invoke-ShimAws @('iam', 'list-account-aliases') (New-ShimCommon $PSBoundParameters) ([Amazon.IdentityManagement.AmazonIdentityManagementServiceException])
    @($j.AccountAliases) }
function global:Get-EC2Region { [CmdletBinding()] param($Region, $ProfileName, $ClientConfig)
    $j = Invoke-ShimAws @('ec2', 'describe-regions') (New-ShimCommon $PSBoundParameters) ([Amazon.EC2.AmazonEC2Exception])
    foreach ($x in @($j.Regions)) { ConvertTo-ShimSdk $x ([Amazon.EC2.Model.Region]) } }
function global:Get-RDSDBCluster { [CmdletBinding()] param($Region, $ProfileName, $ClientConfig, $MaxRecord, [switch]$NoAutoIteration)
    if ($MaxRecord) {   # discovery probe: one page, count only
        $n = Invoke-ShimAws @('rds', 'describe-db-clusters', '--max-records', "$MaxRecord", '--query', 'length(DBClusters)', '--no-paginate') (New-ShimCommon $PSBoundParameters) ([Amazon.RDS.AmazonRDSException])
        for ($i = 0; $i -lt [int]$n; $i++) { [Amazon.RDS.Model.DBCluster]::new() }; return }
    $j = Invoke-ShimAws @('rds', 'describe-db-clusters') (New-ShimCommon $PSBoundParameters) ([Amazon.RDS.AmazonRDSException])
    foreach ($x in @($j.DBClusters)) { ConvertTo-ShimSdk $x ([Amazon.RDS.Model.DBCluster]) } }
function global:Get-RDSDBInstance { [CmdletBinding()] param($Region, $ProfileName, $ClientConfig, $MaxRecord, [switch]$NoAutoIteration)
    if ($MaxRecord) {
        $n = Invoke-ShimAws @('rds', 'describe-db-instances', '--max-records', "$MaxRecord", '--query', 'length(DBInstances)', '--no-paginate') (New-ShimCommon $PSBoundParameters) ([Amazon.RDS.AmazonRDSException])
        for ($i = 0; $i -lt [int]$n; $i++) { [Amazon.RDS.Model.DBInstance]::new() }; return }
    $j = Invoke-ShimAws @('rds', 'describe-db-instances') (New-ShimCommon $PSBoundParameters) ([Amazon.RDS.AmazonRDSException])
    foreach ($x in @($j.DBInstances)) { ConvertTo-ShimSdk $x ([Amazon.RDS.Model.DBInstance]) } }
function global:Get-RDSPendingMaintenanceAction { [CmdletBinding()] param($Region, $ProfileName, $ClientConfig)
    $j = Invoke-ShimAws @('rds', 'describe-pending-maintenance-actions') (New-ShimCommon $PSBoundParameters) ([Amazon.RDS.AmazonRDSException])
    foreach ($x in @($j.PendingMaintenanceActions)) { ConvertTo-ShimSdk $x ([Amazon.RDS.Model.ResourcePendingMaintenanceActions]) } }
function global:Get-RDSGlobalCluster { [CmdletBinding()] param($Region, $ProfileName, $ClientConfig)
    $j = Invoke-ShimAws @('rds', 'describe-global-clusters') (New-ShimCommon $PSBoundParameters) ([Amazon.RDS.AmazonRDSException])
    foreach ($x in @($j.GlobalClusters)) { ConvertTo-ShimSdk $x ([Amazon.RDS.Model.GlobalCluster]) } }
function global:Invoke-ShimEngineVersions { param([string]$Svc, [hashtable]$B, [type]$Model, [type]$Ex)
    $a = @($Svc, 'describe-db-engine-versions')
    if ($B.Engine) { $a += @('--engine', $B.Engine) }
    if ($B.EngineVersion) { $a += @('--engine-version', $B.EngineVersion) }
    $j = Invoke-ShimAws $a (New-ShimCommon $B) $Ex
    foreach ($x in @($j.DBEngineVersions)) { ConvertTo-ShimSdk $x $Model } }
function global:Get-RDSDBEngineVersion { [CmdletBinding()] param($Region, $ProfileName, $ClientConfig, $Engine, $EngineVersion)
    Invoke-ShimEngineVersions 'rds' $PSBoundParameters ([Amazon.RDS.Model.DBEngineVersion]) ([Amazon.RDS.AmazonRDSException]) }
function global:Get-DOCDBEngineVersion { [CmdletBinding()] param($Region, $ProfileName, $ClientConfig, $Engine, $EngineVersion)
    Invoke-ShimEngineVersions 'docdb' $PSBoundParameters ([Amazon.DocDB.Model.DBEngineVersion]) ([Amazon.DocDB.AmazonDocDBException]) }
function global:Get-NPTDBEngineVersion { [CmdletBinding()] param($Region, $ProfileName, $ClientConfig, $Engine, $EngineVersion)
    Invoke-ShimEngineVersions 'neptune' $PSBoundParameters ([Amazon.Neptune.Model.DBEngineVersion]) ([Amazon.Neptune.AmazonNeptuneException]) }
function global:Get-RDSDBMajorEngineVersion { [CmdletBinding()] param($Region, $ProfileName, $ClientConfig, $Engine)
    $a = @('rds', 'describe-db-major-engine-versions'); if ($Engine) { $a += @('--engine', $Engine) }
    $j = Invoke-ShimAws $a (New-ShimCommon $PSBoundParameters) ([Amazon.RDS.AmazonRDSException])
    foreach ($x in @($j.DBMajorEngineVersions)) { ConvertTo-ShimSdk $x ([Amazon.RDS.Model.DBMajorEngineVersion]) } }

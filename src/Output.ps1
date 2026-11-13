# src/Output.ps1 - writing files (Bash place / write_outputs), stdout, and the -DryRun plan (Bash dry_run_plan).

$script:Utf8 = [System.Text.UTF8Encoding]::new($false)   # no BOM, LF line ends: same bytes as the Bash tool

# Write-PcrStdout: raw UTF-8 to stdout (no PowerShell formatting, no console code page surprises on Windows)
function Write-PcrStdout {
    param([string]$Text)
    if ($script:CaptureStdout) { [void]$script:CaptureStdout.Append($Text); return }
    $b = $script:Utf8.GetBytes($Text)
    $s = [Console]::OpenStandardOutput(); $s.Write($b, 0, $b.Length); $s.Flush()
}

# Write-PcrFile (Bash place): atomic write (temp file + rename) into the output dir, mode 0640, logged
function Write-PcrFile {
    param([string]$Path, [string]$Text)
    $Path = Resolve-PcrPath $Path
    $tmp = "$Path.tmp.$PID"
    try {
        [System.IO.File]::WriteAllText($tmp, $Text, $script:Utf8)
        Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
    }
    catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; Stop-Pcr 4 "Cannot write $Path" }
    if (-not $IsWindows) {
        try { [System.IO.File]::SetUnixFileMode($Path, [System.IO.UnixFileMode]'UserRead, UserWrite, GroupRead') } catch { Write-Debug "chmod skipped: $_" }
    }
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    $script:Run.Written.Add($full)
    Write-PcrInfo "Wrote $full"
}

# Get-PcrRendered (Bash render): one format as text
function Get-PcrRendered {
    param($Report, [string]$Format)
    switch ($Format) {
        'json' { return (ConvertTo-PcrJson $Report) }
        'text' { return (ConvertTo-PcrText $Report) }
        'csv' { return (ConvertTo-PcrCsv $Report) }
        'html' { return (ConvertTo-PcrHtml $Report) }
    }
}

# Write-PcrOutputs (Bash write_outputs): every -Format to stdout or to PREFIX_[ACCOUNT_]STAMP.ext (+ _regions.csv)
function Write-PcrOutputs {
    param($Report)
    $O = $script:O
    $stamp = if ($script:Run.Stamp) { $script:Run.Stamp } else { [DateTimeOffset]::FromUnixTimeSeconds($script:Run.Now).ToLocalTime().ToString('yyyyMMdd_HHmmss', $script:Inv) }
    $acc = @($Report['meta']['accounts'])
    $acct = if ($acc.Count -eq 1) { [string]$acc[0]['account'] } else { '' }
    $base = "$($O.Prefix)_$(if ($acct) { "${acct}_" })$stamp"
    foreach ($fmt in $O.Formats) {
        try { $text = Get-PcrRendered $Report $fmt } catch { if ($_.Exception.Data['PcrExit']) { throw }; Write-PcrDebug $_.ScriptStackTrace; Stop-Pcr 4 "Rendering $fmt failed: $($_.Exception.Message)" }
        if (-not $O.OutputDir) { Write-PcrStdout $text; continue }
        $ext = if ($fmt -eq 'text') { 'txt' } else { $fmt }
        if ($O.OutFile) {
            $stem = [System.IO.Path]::GetFileNameWithoutExtension($O.OutFile)
            $name = if ($fmt -eq 'html') { $O.OutFile } else { "$stem.$ext" }
        }
        else { $stem = $base; $name = "$base.$ext" }
        Write-PcrFile (Join-Path $O.OutputDir $name) $text
        if ($fmt -eq 'csv') { Write-PcrFile (Join-Path $O.OutputDir "${stem}_regions.csv") (ConvertTo-PcrRegionCsv $Report) }
    }
}

# ---------------------------------------------------------------------------------------------- dry run
# Format-ShQuote: Bash printf %q for the plan lines (so -AwsBackend Cli prints the same text as Bash)
function Format-ShQuote {
    param([string]$S)
    if ($S -eq '') { return "''" }
    return [regex]::Replace($S, '[^A-Za-z0-9_./:=@%+,-]', { param($m) '\' + $m.Value })
}
# Get-PcrPlanLine: one planned call as an AWS CLI line (Cli) or an AWS.Tools cmdlet line (AwsTools)
function Get-PcrPlanLine {
    param([string]$ProfileName, [string]$Region, [string]$Call, [string[]]$Extra = @(), [hashtable]$Named = @{})
    if ($script:O.AwsBackend -eq 'Cli') {
        $a = @('aws') + (Get-PcrCliBase $ProfileName $Region) + $Call.Split(' ') + $Extra
        return (($a | ForEach-Object { (Format-ShQuote $_) + ' ' }) -join '')
    }
    $op = $script:AwsOps[$Call]
    $s = $op.Cmd
    if ($ProfileName) { $s += " -ProfileName $ProfileName" }
    if ($Region) { $s += " -Region $Region" }
    foreach ($k in $Named.Keys | Sort-Object) { $s += if ("$($Named[$k])" -eq '') { " -$k" } else { " -$k $($Named[$k])" } }
    return $s
}
# Show-PcrDryRun (Bash dry_run_plan): what would be called, no AWS call at all
function Show-PcrDryRun {
    $O = $script:O; $sb = [System.Text.StringBuilder]::new()
    $L = { param($t) [void]$sb.Append($t).Append("`n") }
    & $L "$script:ScriptName v$script:ScriptVersion dry run - no AWS calls are made"
    & $L "  profiles : $(($O.Profiles | ForEach-Object { "$(if ($_) { $_ } else { 'default' }) " }) -join '')"
    $rt = switch ($O.RegionMode) {
        'discover' { "all enabled per account; discovery probe ($($O.ProbeParallel) in parallel), full scan only where databases (or a probe error) are found" }
        'full' { 'all enabled per account; every region scanned in full (-NoDiscover)' }
        default { "$(if ($O.Regions.Count) { $O.Regions -join ' ' } else { 'profile default' }) (queried directly, no probe)" }
    }
    & $L "  regions  : $rt"
    & $L "  filters  : $(Get-PcrFiltersText)"
    & $L "  rule     : COMPLIANT <= $($O.MaxBehind) minor version(s) behind; support warning $($O.WarnDays)d"
    & $L "  formats  : $($O.Formats -join ' ') -> $(if ($O.OutputDir) { $O.OutputDir } else { 'stdout' })"
    if ($O.AwsBackend -ne 'Cli') { & $L "  back end : AWS.Tools cmdlets (-AwsBackend Cli prints the AWS CLI lines instead)" }
    $cli = $O.AwsBackend -eq 'Cli'
    $probeI = if ($cli) { @('--max-records', '20', '--query', 'length(DBInstances)', '--no-paginate') } else { @() }
    $probeC = if ($cli) { @('--max-records', '20', '--query', 'length(DBClusters)', '--no-paginate') } else { @() }
    foreach ($p in $O.Profiles) {
        $r = if ($O.Regions.Count) { $O.Regions[0] } else { '<region>' }
        & $L "Profile $(if ($p) { $p } else { 'default' }):"
        & $L "    $(Get-PcrPlanLine $p $r 'sts get-caller-identity')"
        & $L "    $(Get-PcrPlanLine $p $r 'iam list-account-aliases') (once per account, unless a name is set in the config; optional)"
        if ($O.AllRegions) { & $L "    $(Get-PcrPlanLine $p $r 'ec2 describe-regions')" }
        if ($O.RegionMode -eq 'discover') {
            & $L "  discovery probe, every enabled region, $($O.ProbeParallel) at a time (2 calls per region):"
            & $L "    $(Get-PcrPlanLine $p '<each-region>' 'rds describe-db-instances' $probeI @{ MaxRecord = 20; NoAutoIteration = '' })"
            & $L "    $(Get-PcrPlanLine $p '<each-region>' 'rds describe-db-clusters' $probeC @{ MaxRecord = 20; NoAutoIteration = '' })"
            & $L '  full scan, only regions where a probe found a DB instance / cluster or failed:'
        }
        $list = @(if ($O.Regions.Count) { $O.Regions } else { '<each-region>' })
        foreach ($r in $list) {
            & $L "    $(Get-PcrPlanLine $p $r 'rds describe-db-clusters')"
            & $L "    $(Get-PcrPlanLine $p $r 'rds describe-db-instances')"
            & $L "    $(Get-PcrPlanLine $p $r 'rds describe-pending-maintenance-actions')"
            & $L "    $(Get-PcrPlanLine $p $r 'rds describe-db-engine-versions' @('--engine', '<engine>', '--engine-version', '<current>') @{ Engine = '<engine>'; EngineVersion = '<current>' }) (once per engine+version+region; docdb / neptune CLI for those)"
            & $L "    $(Get-PcrPlanLine $p $r 'rds describe-db-major-engine-versions' @('--engine', '<engine>') @{ Engine = '<engine>' }) (once per RDS engine+region)"
        }
        & $L "    $(Get-PcrPlanLine $p $r 'rds describe-global-clusters') (once per account, only when Aurora clusters are found)"
    }
    Write-PcrStdout $sb.ToString()
}

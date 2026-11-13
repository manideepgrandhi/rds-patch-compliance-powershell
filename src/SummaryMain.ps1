# src/SummaryMain.ps1 - Invoke-RdsPatchComplianceSummary (port of rds_patch_compliance_summary.sh main).
# The scan / merge is done by Invoke-RdsPatchCompliance (in-process, -ReturnReport), so every number is the
# full report's number; this only renders the short summary (src/Summary.ps1) and optionally alerts.

# Get-PcsUsage: the -Help text of the summary script
function Get-PcsUsage {
    return @"
$script:SummaryName $script:SummaryVersion - RDS patch compliance SUMMARY (read-only)
Shows only the high-level picture and the NON-COMPLIANT servers. The rule (same as the full report):
NON-COMPLIANT when versions_behind > -MaxBehind (default 2, i.e. 3 or more valid minor versions behind).

Usage: ./Invoke-RdsPatchComplianceSummary.ps1 [options]
  -ProfileName P[,P]        AWS profile(s)
  -Region R[,R]             Region(s)
  -AllRegions               Every enabled region; a quick discovery probe per region skips empty regions
  -NoDiscover               With -AllRegions: scan every enabled region in full (no probe)
  -ProbeParallel N          With -AllRegions: regions probed at a time (1-32, default 8)
  -Engine GLOB / -Identifier GLOB   Filters
  -MaxBehind N              Allowed minor versions behind (default 2)
  -WarnDays N               "Support ending" window in days (default 180)
  -OracleAnyPatchLine       Oracle: count targets on other patch lines too
  -Format F[,F]             txt | html | csv  (default txt to the screen; csv = non-compliant + summary + accounts + regions CSV)
  -OutputDir DIR            Write files there (needed for html / csv / several formats)
  -Prefix NAME              File name prefix (default rds_patch_compliance_summary)
  -SaveData / -SaveDataFile FILE.json   Also save the raw data (same format as the Bash scripts)
  -Merge FILE|DIR ...       Offline: summarise -SaveData / --save-data files of any of the four scripts
  -FailOnNonCompliant       Exit 5 when any NON-COMPLIANT server is found
  -AlertEmail / -AlertSmtpServer / -AlertWebhook / -AlertWebhookFormat slack|json / -AlertOn noncompliant|always / -AlertFrom
  -AwsBackend AwsTools|Cli  How AWS is called (default AwsTools)
  -Verbose                  Debug log of the scan
  -Help / -Version
Exit codes: 0 ok, 1 usage, 2 pre-check / collection failed, 3 bad -Merge input, 4 output error, 5 non-compliant (-FailOnNonCompliant).
"@
}

<#
.SYNOPSIS
High-level RDS patch compliance summary + the NON-COMPLIANT servers only. Returns the exit code.
#>
function Invoke-RdsPatchComplianceSummary {
    [CmdletBinding(PositionalBinding = $false)]
    param(
        [Alias('Profile', 'P')][string[]]$ProfileName, [Alias('r')][string[]]$Region, [Alias('A')][switch]$AllRegions, [switch]$NoDiscover, [string]$ProbeParallel,
        [Alias('e')][string[]]$Engine, [Alias('i')][string[]]$Identifier, [string]$MaxBehind = '2', [string]$WarnDays = '180',
        [switch]$SaveData, [string]$SaveDataFile, [string[]]$Merge, [switch]$OracleAnyPatchLine,
        [Alias('F')][string[]]$Format, [Alias('o')][string]$OutputDir, [string]$Prefix = 'rds_patch_compliance_summary', [switch]$FailOnNonCompliant,
        [string[]]$AlertEmail, [string[]]$AlertWebhook, [string]$AlertWebhookFormat = 'slack', [string]$AlertOn = 'noncompliant', [string]$AlertFrom,
        [string]$AlertSmtpServer, [int]$AlertSmtpPort = 25, [ValidateSet('AwsTools', 'Cli')][string]$AwsBackend = 'AwsTools',
        [Alias('h')][switch]$Help, [Alias('V')][switch]$Version,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$MoreArgs
    )
    $script:CaptureStdout = $null
    $script:O = New-PcrOptions; $script:Run = New-PcrRun   # logging + alert helpers read these
    $verbose = [bool]($PSBoundParameters['Verbose'] -or $PSBoundParameters['Debug'])
    try {
        if ($Help) { Write-PcrStdout ((Get-PcsUsage) + "`n"); return 0 }
        if ($Version) { Write-PcrStdout "$script:SummaryName $script:SummaryVersion`n"; return 0 }
        # ------------------------------------------------------------------ validate (Bash validate)
        $formats = Split-PcrList $Format; if ($formats.Count -eq 0) { $formats = @('txt') }
        foreach ($f in $formats) { if ($f -notin 'txt', 'text', 'html', 'csv') { Stop-Pcr 1 "Unknown format '$f' (txt, html, csv)" } }
        if (-not $OutputDir -and ($formats.Count -gt 1 -or $formats[0] -notin 'txt', 'text')) { Stop-Pcr 1 'html / csv / several formats need -OutputDir DIR' }
        if ($MaxBehind -notmatch '^[0-9]+$') { Stop-Pcr 1 '-MaxBehind must be a whole number >= 0' }
        if ($WarnDays -notmatch '^[0-9]+$') { Stop-Pcr 1 '-WarnDays must be a whole number >= 0' }
        if ($Prefix -cnotmatch '^[A-Za-z0-9._-]+$' -or $Prefix.StartsWith('.')) { Stop-Pcr 1 '-Prefix may contain only letters, digits, . _ -' }
        $regions = Split-PcrList $Region
        if ($AllRegions -and $regions.Count) { Stop-Pcr 1 'Use either -Region or -AllRegions, not both' }
        if ($ProbeParallel -and ($ProbeParallel -notmatch '^[0-9]+$' -or [int]$ProbeParallel -lt 1 -or [int]$ProbeParallel -gt 32)) { Stop-Pcr 1 '-ProbeParallel must be a whole number from 1 to 32' }
        if ($AlertOn.ToLowerInvariant() -notin 'noncompliant', 'always') { Stop-Pcr 1 '-AlertOn must be noncompliant or always' }
        if ($AlertWebhookFormat.ToLowerInvariant() -notin 'slack', 'json') { Stop-Pcr 1 '-AlertWebhookFormat must be slack or json' }
        $emails = Split-PcrList $AlertEmail; $hooks = Split-PcrList $AlertWebhook
        foreach ($x in $emails) { if ($x -notmatch '^[^\s@;|&$`]+@[^\s@;|&$`]+$') { Stop-Pcr 1 "Invalid -AlertEmail address: $x" } }
        foreach ($x in $hooks) { if ($x -notmatch '^https?://') { Stop-Pcr 1 "-AlertWebhook must be an http(s) URL: $(Get-RedactedUrl $x)" } }
        $more = @($MoreArgs | Where-Object { $null -ne $_ -and $_ -ne '' })
        if ($more.Count) { if ($PSBoundParameters.ContainsKey('Merge')) { $Merge = @($Merge) + $more } else { Stop-Pcr 1 "Unknown option: $($more[0]) (see -Help)" } }
        $profiles = Split-PcrList $ProfileName; $engines = Split-PcrList $Engine; $ids = Split-PcrList $Identifier
        if ($PSBoundParameters.ContainsKey('Merge')) {
            if (@($Merge).Count -eq 0) { Stop-Pcr 1 '-Merge needs at least one -SaveData file or directory' }
            if ($profiles.Count -or $regions.Count -or $AllRegions -or $NoDiscover) { Stop-Pcr 1 '-Merge works offline on saved data: -ProfileName / -Region / -AllRegions / -NoDiscover do not apply' }
            if ($ProbeParallel) { Stop-Pcr 1 '-Merge: -ProbeParallel does not apply' }
            if ($engines.Count -or $ids.Count) { Stop-Pcr 1 '-Merge: -Engine / -Identifier do not apply' }
            if ($SaveData -or $SaveDataFile) { Stop-Pcr 1 '-Merge cannot be combined with -SaveData' }
        }
        if ($SaveDataFile) {
            if ($SaveDataFile -notmatch '\.json$') { Stop-Pcr 1 '-SaveDataFile must end in .json' }
            $SaveDataFile = [System.IO.Path]::GetFullPath($SaveDataFile, (Get-Location).ProviderPath)
        }
        # ------------------------------------------------------------------ collect (the full report does the work)
        $a = @{ ReturnReport = $true; WarnDays = $WarnDays; AwsBackend = $AwsBackend }
        if ($verbose) { $a.Verbose = $true }
        if ($OracleAnyPatchLine) { $a.OracleAnyPatchLine = $true }
        $dir = '.'
        if ($PSBoundParameters.ContainsKey('Merge')) {
            $a.Merge = $Merge; if ($PSBoundParameters.ContainsKey('MaxBehind')) { $a.MaxBehind = $MaxBehind }
            $what = 'Merge'
        }
        else {
            $a.MaxBehind = $MaxBehind
            if ($profiles.Count) { $a.ProfileName = $profiles }
            if ($regions.Count) { $a.Region = $regions }
            if ($engines.Count) { $a.Engine = $engines }
            if ($ids.Count) { $a.Identifier = $ids }
            if ($AllRegions) { $a.AllRegions = $true }
            if ($NoDiscover) { $a.NoDiscover = $true }
            if ($ProbeParallel) { $a.ProbeParallel = $ProbeParallel }
            if ($SaveDataFile) { $a.SaveDataFile = $SaveDataFile }
            elseif ($SaveData) {
                $a.SaveData = $true
                if ($OutputDir) { try { $null = New-Item -ItemType Directory -Force -Path $OutputDir -ErrorAction Stop } catch { Stop-Pcr 4 "Cannot create $OutputDir" }; $dir = $OutputDir }
            }
            $what = 'Scan'
        }
        Push-Location -LiteralPath $dir
        try { $null = Invoke-RdsPatchCompliance @a } finally { Pop-Location }
        $res = $script:LastResult
        # restore this script's settings (the inner call replaced $script:O)
        $script:O = New-PcrOptions; $script:O.VerboseLog = $verbose
        $script:O.AlertEmails = $emails; $script:O.AlertWebhooks = $hooks; $script:O.AlertOn = $AlertOn.ToLowerInvariant(); $script:O.AlertWebhookFormat = $AlertWebhookFormat.ToLowerInvariant()
        $script:O.AlertFrom = $AlertFrom; $script:O.AlertSmtpServer = $AlertSmtpServer; $script:O.AlertSmtpPort = $AlertSmtpPort
        $script:CaptureStdout = $null
        if ($res.ExitCode -ne 0) { Stop-Pcr $res.ExitCode "$what failed (Invoke-RdsPatchCompliance $(if ($what -eq 'Merge') { '-Merge ' })exit $($res.ExitCode))" }
        $rep = $res.Report
        if ($null -eq $rep -or $null -eq (Get-JqField $rep['summary'] 'total')) { Stop-Pcr 2 "$what returned no report" }
        # ------------------------------------------------------------------ write (Bash write_outputs)
        $written = [System.Collections.Generic.List[string]]::new()
        if (-not $OutputDir) { Write-PcrStdout (ConvertTo-SummaryText $rep) }
        else {
            try { $null = New-Item -ItemType Directory -Force -Path $OutputDir -ErrorAction Stop } catch { Stop-Pcr 4 "Cannot create $OutputDir" }
            $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd_HHmmss', $script:Inv)
            $acc = @($rep['meta']['accounts'])
            if ($acc.Count -eq 1 -and [string]$acc[0]['account'] -match '^[0-9]{12}$') { $stamp = "$($acc[0]['account'])_$stamp" }
            $full = (Resolve-Path -LiteralPath $OutputDir).ProviderPath
            $put = { param($name, $text) $p = Join-Path $full $name; try { [System.IO.File]::WriteAllText($p, $text, $script:Utf8) } catch { Stop-Pcr 4 "Writing $p failed" }; $written.Add($p) }
            foreach ($f in $formats) {
                switch ($f) {
                    { $_ -in 'txt', 'text' } { & $put "${Prefix}_$stamp.txt" (ConvertTo-SummaryText $rep) }
                    'html' { & $put "${Prefix}_$stamp.html" (ConvertTo-SummaryHtml $rep) }
                    'csv' {
                        & $put "${Prefix}_${stamp}_summary.csv" (ConvertTo-SummaryCsvSummary $rep)
                        & $put "${Prefix}_${stamp}_noncompliant.csv" (ConvertTo-SummaryCsvNc $rep)
                        & $put "${Prefix}_${stamp}_accounts.csv" (ConvertTo-SummaryCsvAccounts $rep)
                        & $put "${Prefix}_${stamp}_regions.csv" (ConvertTo-SummaryCsvRegions $rep)
                    }
                }
            }
            foreach ($w in $written) { Write-PcrInfo "Wrote $w" }
            if ($formats -contains 'txt' -or $formats -contains 'text') { Write-PcrStdout (ConvertTo-SummaryText $rep) }
        }
        $rc = 0
        $s = $rep['summary']
        if ($FailOnNonCompliant -and $s['non_compliant'] -ne 0) { $rc = 5 }
        $mm = Get-JqField $rep['meta'] 'merge'
        $pre = if (Test-JqTruthy $mm) { "Merged $(@($rep['meta']['accounts']).Count) account(s) from $($mm['files']) file(s), 0 AWS calls. " } else { '' }
        Write-PcrInfo "${pre}Summary: $($s['total']) server(s)/cluster(s): COMPLIANT $($s['compliant']), NON-COMPLIANT $($s['non_compliant']), UNKNOWN $($s['unknown']) ($(ConvertTo-JqText $s['pct_compliant'])% compliant); exit $rc"
        Send-PcsAlert $rep
        return $rc
    }
    catch {
        $code = $_.Exception.Data['PcrExit']
        if ($null -ne $code) { return [int]$code }
        Write-PcrError "Internal error: $($_.Exception.Message)"; Write-PcrDebug $_.ScriptStackTrace
        return 4
    }
}

# Send-PcsAlert (summary send_alerts): subject prefix [rds_patch_compliance_summary], body = the text summary
function Send-PcsAlert {
    param($Rep)
    $O = $script:O
    $m = Get-PcsAlertMessage $Rep
    if ($null -eq $m) { return }
    if ($O.AlertEmails.Count) {
        if (Send-PcrEmail $m.Subject $m.Body) { Write-PcrInfo "Alert: e-mail ($($m.Status)) sent to $($O.AlertEmails -join ' ')" }
        else { Write-PcrWarn "Alert: e-mail to $($O.AlertEmails -join ' ') failed" }
    }
    foreach ($u in $O.AlertWebhooks) { $null = Send-PcrWebhook $u $m.Payload }
}
# Get-PcsAlertMessage: subject / status / body / payload of the summary alert ($null = nothing to send)
function Get-PcsAlertMessage {
    param($Rep)
    $O = $script:O
    if (($O.AlertEmails.Count + $O.AlertWebhooks.Count) -eq 0) { return $null }
    $s = $Rep['summary']
    if ($O.AlertOn -eq 'noncompliant' -and ($s['non_compliant'] + $s['errors']) -eq 0) { return $null }
    $status = if ($s['non_compliant'] -gt 0) { 'NON-COMPLIANT' } elseif ($s['errors'] -gt 0) { 'ERRORS' } else { 'COMPLIANT' }
    $subject = "[rds_patch_compliance_summary] ${status}: $($s['non_compliant']) non-compliant of $($s['total']), $(ConvertTo-JqText $s['pct_compliant'])% compliant"
    $body = ConvertTo-SummaryText $Rep
    if ($O.AlertWebhookFormat -eq 'slack') {
        $b = if ($body.Length -gt $script:SlackMaxChars) { $body.Substring(0, $script:SlackMaxChars) + "`n... (truncated)" } else { $body }
        $payload = ConvertTo-JqJson (New-JqObject ([ordered]@{ text = "*$subject*`n``````$b``````" })) -Compact
    }
    else {
        $p = Get-SummaryAlertData $Rep; $p['status'] = $status; $p['text'] = "$subject`n`n$body"
        $payload = ConvertTo-JqJson $p -Compact
    }
    return @{ Status = $status; Subject = $subject; Body = $body; Payload = $payload + "`n" }   # jq -c ends with a newline
}

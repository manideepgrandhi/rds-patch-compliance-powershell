# src/Main.ps1 - Invoke-RdsPatchCompliance: the whole run (Bash main + parse_args), plus -Help text.
# Returns the exit code (0 ok, 1 usage, 2 pre-check, 3 bad -Merge file, 4 output, 5 -FailOnNonCompliant)
# instead of exiting, so it can be called from other scripts and from Pester; the .ps1 wrapper exits with it.

$script:ScriptName = 'Invoke-RdsPatchCompliance.ps1'
$script:ScriptVersion = '1.0.0'   # port of rds_patch_compliance_report.sh v1.5.1

# New-PcrRun: per-run state (counters, collected data); replaces the Bash WORK directory files
function New-PcrRun {
    return @{
        Now = [long]0; AwsCalls = 0; AwsFails = 0; Stamp = ''; ProfileIdx = 0; RawSeq = 0; WorkDir = ''
        Errors = [System.Collections.Generic.List[object]]::new(); Rows = [System.Collections.Generic.List[object]]::new()
        RowKeys = [System.Collections.Generic.List[string]]::new(); Accounts = [System.Collections.Generic.List[object]]::new()
        RegionStatus = [System.Collections.Generic.List[object]]::new(); Globals = [System.Collections.Generic.List[object]]::new()
        GlobalLookup = [System.Collections.Generic.List[object]]::new(); RegionsSeen = [System.Collections.Generic.List[string]]::new()
        Written = [System.Collections.Generic.List[string]]::new()
        EvCache = @{}; LcCache = @{}; LcUnsupported = $false
    }
}

# Get-PcrUsage (Bash usage): the -Help text
function Get-PcrUsage {
    return @"
$script:ScriptName v$script:ScriptVersion - minor-version patch compliance report for AWS databases (read-only)
PowerShell 7 port of rds_patch_compliance_report.sh v1.5.1 (same rules, same CSV / JSON / HTML, same data files).

Usage: ./Invoke-RdsPatchCompliance.ps1 [options]      (Get-Help ./Invoke-RdsPatchCompliance.ps1 -Full for details)

Scope:
  -ProfileName NAME[,NAME]  AWS profile(s) / accounts; comma list or array (default: default credential chain)
  -Region R[,R]             Region(s) (default: env / profile region)
  -AllRegions               Every enabled region; each is probed first (2 one-page calls, in parallel) and only
                            regions with a DB instance or cluster are scanned in full; a failed probe = error +
                            full scan, never skipped silently
  -NoDiscover               With -AllRegions: no probe, scan every enabled region in full   (-Discover = default)
  -ProbeParallel N          Regions probed at the same time (default 8, 1-32)
  -Engine GLOB[,GLOB]       aurora-postgresql, aurora-mysql, postgres, mysql, mariadb, 'sqlserver-*', 'oracle-*',
                            docdb, neptune (globs * ?, case-insensitive)
  -Identifier GLOB[,GLOB]   Cluster / instance identifier (a cluster also matches by member)

Compliance:
  -MaxBehind N              COMPLIANT when RDS lists at most N valid minor upgrade targets (default 2)
  -WarnDays N               Flag majors whose standard support ends within N days (default 180)
  -NonCompliantOnly         Show only NON-COMPLIANT rows (the summary still counts everything)
  -OracleAnyPatchLine       Oracle: also count targets on OTHER patch lines (default: same line only)
  -FailOnNonCompliant       Exit 5 when any NON-COMPLIANT server is found

Report:
  -Format LIST              text,csv,json,html (default text). Several formats need -OutputDir
  -OutputDir DIR            Write <prefix>[_<account>]_YYYYmmdd_HHMMSS.<ext> into DIR; DIR\FILE.html names the file
  -SaveData                 Also write the raw data for -Merge: rds_patch_<ACCOUNTID>_<YYYYMMDD>.json per account
  -SaveDataFile FILE.json   ... or all accounts in one file (implies -SaveData)
  -Prefix NAME              File name prefix (default rds_patch_compliance)
  -Top N                    Deprecated (accepted and ignored, like the Bash --top)
  -Tz ZONE                  Second time zone for the generated time (default Asia/Kolkata; Windows ids work too)
  -LogFile FILE             Append log lines to FILE

Alerts (optional):
  -AlertEmail ADDR[,ADDR]   E-mail the text report (mail/mailx/sendmail, or -AlertSmtpServer)
  -AlertSmtpServer HOST     SMTP relay for e-mail (Windows); -AlertSmtpPort N (default 25)
  -AlertWebhook URL[,URL]   POST to a webhook (Invoke-WebRequest); the URL is never logged in full
  -AlertWebhookFormat F     slack | json (default slack)
  -AlertOn WHEN             noncompliant (NON-COMPLIANT or AWS errors) | always (default noncompliant)
  -AlertFrom ADDR           From address for e-mail
  -AlertTest                Send a test alert and exit

Merge (offline):
  -Merge FILE|DIR|GLOB ...  Combine -SaveData files (from this script OR the Bash script) into one report.
                            Zero AWS calls. Same account twice: the newer collection wins. Default format html.

Behaviour:
  -ConfigFile FILE          key=value settings (same file format as the Bash tool; parameters override)
  -AwsBackend B             AwsTools (default, AWS.Tools modules) | Cli (the AWS CLI v2, like the Bash tool)
  -AwsTimeout SEC           AWS connect/read timeout (default 30)
  -MaxAttempts N            AWS retry attempts (default 5)
  -KeepWorkdir              Keep raw AWS responses (one JSON per call) for debugging
  -DryRun                   Print the AWS calls that would run; call nothing
  -Verbose                  Debug logging (-Debug works too)
  -Help / -Version

Exit codes: 0 report produced, 5 NON-COMPLIANT found (only with -FailOnNonCompliant), 1 usage,
            2 pre-check (modules / CLI missing, no profile has valid credentials), 3 bad -Merge input file,
            4 output error. Ctrl+C stops the run (PowerShell sets the exit code; see FEATURE-PARITY.md).
"@
}

# Set-PcrParams: bound parameters override the config file (a list given here REPLACES the config list,
# like the Bash reset_once); comma lists are split like the Bash add_list
function Set-PcrParams {
    param([hashtable]$B)
    $O = $script:O
    $lists = @{ ProfileName = 'Profiles'; Region = 'Regions'; Engine = 'Engines'; Identifier = 'Identifiers'; Format = 'Formats'; AlertEmail = 'AlertEmails'; AlertWebhook = 'AlertWebhooks' }
    foreach ($k in $lists.Keys) { if ($B.ContainsKey($k)) { $O[$lists[$k]] = Split-PcrList $B[$k] } }
    if ($B.ContainsKey('Format')) { $O.FormatsSet = $true }
    $plain = @{ ProbeParallel = 'ProbeParallel'; OutputDir = 'OutputDir'; Prefix = 'Prefix'; MaxBehind = 'MaxBehind'; WarnDays = 'WarnDays'; LogFile = 'LogFile'
        AwsTimeout = 'AwsTimeout'; MaxAttempts = 'MaxAttempts'; AlertWebhookFormat = 'AlertWebhookFormat'; AlertOn = 'AlertOn'; AlertFrom = 'AlertFrom'
        AlertSmtpServer = 'AlertSmtpServer'; AlertSmtpPort = 'AlertSmtpPort'; AwsBackend = 'AwsBackend'; Tz = 'Tz' }
    foreach ($k in $plain.Keys) { if ($B.ContainsKey($k)) { $O[$plain[$k]] = [string]$B[$k] } }
    if ($B.ContainsKey('Tz')) { $O.TzSet = $true }
    if ($B.ContainsKey('MaxBehind')) { $O.MaxBehindSet = $true }
    if ($B.ContainsKey('AlertSmtpPort')) { $O.AlertSmtpPort = [int]$B.AlertSmtpPort }
    $switches = @{ AllRegions = 'AllRegions'; NonCompliantOnly = 'NcOnly'; OracleAnyPatchLine = 'OracleAnyLine'; FailOnNonCompliant = 'FailOnNc'; KeepWorkdir = 'KeepWorkdir'; DryRun = 'DryRun'; AlertTest = 'AlertTest' }
    foreach ($k in $switches.Keys) { if ($B.ContainsKey($k) -and $B[$k]) { $O[$switches[$k]] = $true } }
    if ($B.ContainsKey('NoDiscover') -and $B.NoDiscover) { $O.Discover = $false }
    if ($B.ContainsKey('Discover') -and $B.Discover) { $O.Discover = $true }
    if ($B.ContainsKey('TagColumns')) { $O.TagIgnored = $true }
    if ($B.ContainsKey('Top')) { $O.TopSet = $true }
    if (($B.ContainsKey('Verbose') -and $B.Verbose) -or ($B.ContainsKey('Debug') -and $B.Debug)) { $O.VerboseLog = $true }
    if ($B.ContainsKey('SaveData') -and $B.SaveData) { $O.SaveData = $true }
    if ($B.ContainsKey('SaveDataFile')) { $O.SaveData = $true; $O.SaveDataFile = [string]$B.SaveDataFile }
    if ($B.ContainsKey('Merge')) { $O.Merge = $true; $O.MergeArgs = @($B.Merge | Where-Object { $_ }) }
    # Bash style "-Merge a.json b.json c.json": the extra words are more merge files; anything else is an error
    $more = @($B['MoreArgs'] | Where-Object { $null -ne $_ -and $_ -ne '' })
    if ($more.Count) {
        if ($O.Merge) { $O.MergeArgs = @($O.MergeArgs) + $more } else { Stop-Pcr 1 "Unknown option: $($more[0]) (see -Help)" }
    }
}

<#
.SYNOPSIS
Minor-version patch compliance report for Aurora / RDS / DocumentDB / Neptune (read-only). Returns the exit code.
.DESCRIPTION
Module entry point behind Invoke-RdsPatchCompliance.ps1. Same parameters; see that script's help or -Help.
-ReturnReport (used by the summary script) returns @{ ExitCode; Report } and prints nothing to stdout.
#>
function Invoke-RdsPatchCompliance {
    [CmdletBinding(PositionalBinding = $false)]
    param(
        [Alias('Profile', 'P')][string[]]$ProfileName, [Alias('r')][string[]]$Region, [Alias('A')][switch]$AllRegions, [switch]$NoDiscover, [switch]$Discover,
        [string]$ProbeParallel, [Alias('e')][string[]]$Engine, [Alias('i')][string[]]$Identifier, [Alias('T')][string]$TagColumns,
        [Alias('F')][string[]]$Format, [Alias('o')][string]$OutputDir, [string]$Prefix, [Alias('TimeZone')][string]$Tz,
        [switch]$SaveData, [string]$SaveDataFile, [string[]]$Merge,
        [string]$MaxBehind, [string]$WarnDays, [string]$Top, [switch]$NonCompliantOnly, [switch]$OracleAnyPatchLine, [switch]$FailOnNonCompliant,
        [Alias('l')][string]$LogFile, [Alias('Config')][string]$ConfigFile, [string]$AwsTimeout, [string]$MaxAttempts, [switch]$KeepWorkdir, [switch]$DryRun,
        [string[]]$AlertEmail, [string[]]$AlertWebhook, [string]$AlertWebhookFormat, [string]$AlertOn, [string]$AlertFrom, [switch]$AlertTest,
        [string]$AlertSmtpServer, [int]$AlertSmtpPort, [ValidateSet('AwsTools', 'Cli')][string]$AwsBackend,
        [Alias('h')][switch]$Help, [Alias('V')][switch]$Version,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$MoreArgs, [switch]$ReturnReport
    )
    $script:O = New-PcrOptions; $script:Run = New-PcrRun
    $script:CaptureStdout = if ($ReturnReport) { [System.Text.StringBuilder]::new() } else { $null }
    $rc = 0; $report = $null
    try {
        if ($Help) { Write-PcrStdout ((Get-PcrUsage) + "`n"); return 0 }
        if ($Version) { Write-PcrStdout "$script:ScriptName $script:ScriptVersion`n"; return 0 }
        if ($ConfigFile) { $script:O.ConfigFile = $ConfigFile; Import-PcrConfig $ConfigFile }
        Set-PcrParams $PSBoundParameters
        if ($ReturnReport) { $script:O.Formats = @('json'); $script:O.OutputDir = '' }
        Confirm-PcrOptions
        $O = $script:O
        $script:Run.Now = Get-PcrNow
        if ($O.Merge) {
            $m = Invoke-PcrMerge; $report = $m.Report
            Write-PcrOutputs $report
            $nc = $report['summary']['non_compliant']
            if ($O.FailOnNc -and $nc -gt 0) { $rc = 5 }
            $s = $report['summary']
            Write-PcrInfo "Merged $(@($report['meta']['accounts']).Count) account(s) from $($m.Files) file(s): $($s['total']) server(s)/cluster(s): COMPLIANT $($s['compliant']), NON-COMPLIANT $($s['non_compliant']), UNKNOWN $($s['unknown']) ($(ConvertTo-JqText $s['pct_compliant'])% compliant); $($s['errors']) error(s); 0 AWS calls; exit $rc"
            return $rc
        }
        if ($O.AlertTest) {
            if (($O.AlertEmails.Count + $O.AlertWebhooks.Count) -eq 0) { Stop-Pcr 1 '-AlertTest needs -AlertEmail or -AlertWebhook' }
            Send-PcrAlert $null 'test'; return 0
        }
        if ($O.DryRun) { Show-PcrDryRun; return 0 }
        Test-PcrPrereq
        if ($O.KeepWorkdir) { $script:Run.WorkDir = (New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ("rds_pcr." + [guid]::NewGuid().ToString('N').Substring(0, 6)))).FullName }
        $ok = 0
        for ($i = 0; $i -lt $O.Profiles.Count; $i++) {
            $script:Run.ProfileIdx = $i
            if (Invoke-PcrProfileScan $O.Profiles[$i]) { $ok++ }
        }
        if ($ok -eq 0) {
            foreach ($e in $script:Run.Errors) { Write-PcrError "$($e['profile']): $($e['message'])" }
            Stop-Pcr 2 'No profile could be used (credentials / region); nothing to report'
        }
        $raw = New-PcrRawReport
        $report = Complete-Report $raw $script:Run.Now $O.MaxBehind $O.WarnDays $O.NcOnly $O.AccountNames
        Write-PcrOutputs $report
        if ($O.SaveData) { Save-PcrData $raw }
        $s = $report['summary']
        if ($O.FailOnNc -and $s['non_compliant'] -gt 0) { $rc = 5 }
        Write-PcrInfo "Result: $($s['total']) server(s)/cluster(s): COMPLIANT $($s['compliant']), NON-COMPLIANT $($s['non_compliant']), UNKNOWN $($s['unknown']) ($(ConvertTo-JqText $s['pct_compliant'])% compliant); $($s['errors']) error(s); $($script:Run.AwsCalls) AWS call(s); exit $rc"
        Send-PcrAlert $report '' @($script:Run.Written)
        return $rc
    }
    catch {
        $code = $_.Exception.Data['PcrExit']
        if ($null -ne $code) { $rc = [int]$code; return $rc }
        Write-PcrError "Internal error: $($_.Exception.Message)"
        Write-PcrDebug $_.ScriptStackTrace
        $rc = 4; return $rc
    }
    finally {
        if ($script:Run.WorkDir) { Write-PcrInfo "Raw AWS responses kept in $($script:Run.WorkDir)" }
        if ($ReturnReport) { $script:LastResult = @{ ExitCode = $rc; Report = $report } }
    }
}

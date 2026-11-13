# src/Options.ps1 - run settings: defaults, logging, the key = value config file, validation, filter text.
# Port of the Bash globals + load_config / validate / filters_json / filters_text. One hashtable ($script:O)
# replaces ~40 Bash globals; counters (AWS calls / failures) live in $script:Run.

# ---------------------------------------------------------------------------------------------- defaults
# New-PcrOptions: every setting with the same default as the Bash script
function New-PcrOptions {
    return @{
        Profiles = @(); Regions = @(); AllRegions = $false; Discover = $true; ProbeParallel = '8'
        Engines = @(); Identifiers = @(); TagIgnored = $false
        Formats = @(); FormatsSet = $false; OutputDir = ''; OutFile = ''; Prefix = 'rds_patch_compliance'
        Tz = 'Asia/Kolkata'; TzSet = $false; MaxBehind = '2'; MaxBehindSet = $false; WarnDays = '180'; TopSet = $false
        NcOnly = $false; OracleAnyLine = $false; FailOnNc = $false
        LogFile = ''; ConfigFile = ''; AccountNames = (New-JqObject)
        AwsTimeout = '30'; MaxAttempts = '5'; KeepWorkdir = $false; DryRun = $false; VerboseLog = $false
        AlertEmails = @(); AlertWebhooks = @(); AlertOn = 'noncompliant'; AlertWebhookFormat = 'slack'; AlertFrom = ''; AlertTest = $false
        AlertSmtpServer = ''; AlertSmtpPort = 25
        SaveData = $false; SaveDataFile = ''; Merge = $false; MergeArgs = @()
        RegionMode = 'explicit'; AwsBackend = 'AwsTools'
    }
}

# ---------------------------------------------------------------------------------------------- logging
# Write-PcrLog: "YYYY-mm-dd HH:MM:SS [LEVEL] message" to stderr (stdout stays clean for the report) + -LogFile
function Write-PcrLog {
    param([string]$Level, [string]$Message)
    $line = "$([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss', $script:Inv)) [$Level] $Message"
    [Console]::Error.WriteLine($line)
    if ($script:O -and $script:O.LogFile -and -not $script:O.DryRun) {
        try { [System.IO.File]::AppendAllText($script:O.LogFile, $line + "`n") } catch { Write-Debug "log file write failed: $_" }
    }
}
function Write-PcrInfo { param([string]$Message) Write-PcrLog INFO $Message }
function Write-PcrWarn { param([string]$Message) Write-PcrLog WARN $Message }
function Write-PcrError { param([string]$Message) Write-PcrLog ERROR $Message }
function Write-PcrDebug { param([string]$Message) if ($script:O -and $script:O.VerboseLog) { Write-PcrLog DEBUG $Message } }

# Stop-Pcr: the Bash "die" - log an error and leave with an exit code. It throws (exception Data PcrExit = code)
# so that the entry script's finally block still cleans up; the entry script turns it into "exit <code>".
function Stop-Pcr {
    param([int]$Code, [string]$Message)
    if ($Message) { Write-PcrError $Message }
    $e = [System.Exception]::new("PcrExit ${Code}: $Message")
    $e.Data['PcrExit'] = $Code
    throw $e
}

# ---------------------------------------------------------------------------------------------- lists
# Add-PcrList (Bash add_list): split "a, b,c" on commas, trim, drop empties
function Split-PcrList {
    param([AllowNull()][object[]]$Value)
    $out = foreach ($v in @($Value)) { foreach ($p in ([string]$v).Split(',')) { $t = $p.Trim(); if ($t) { $t } } }
    return , @($out)
}
# Test-PcrTrue (Bash is_true): 1 / y / yes / true / on
function Test-PcrTrue { param([string]$Value) return @('1', 'y', 'yes', 'true', 'on') -contains $Value.ToLowerInvariant() }
# Get-RedactedUrl (Bash redact_url): keep scheme + host only, never print a webhook secret
function Get-RedactedUrl {
    param([string]$Url)
    $m = [regex]::Match($Url, '^([a-zA-Z]+://[^/]+)')
    if ($m.Success) { return $m.Groups[1].Value + '/...' }
    return '<webhook>'
}
# Expand-PcrHome: "~/x" -> "$HOME/x" (config values)
function Expand-PcrHome { param([string]$Path) if ($Path -match '^~') { return ($HOME + $Path.Substring(1)) } return $Path }

# ---------------------------------------------------------------------------------------------- config file
# Import-PcrConfig (Bash load_config): key = value lines, parsed, never executed; same keys as the Bash file,
# so ONE config file serves both tools. 12-digit keys are account names. Credentials are refused.
function Import-PcrConfig {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { Stop-Pcr 1 "Config file not readable: $File" }
    $O = $script:O; $lineno = 0
    foreach ($raw in [System.IO.File]::ReadAllLines($File)) {
        $lineno++; $line = $raw.TrimEnd("`r")
        if ($line -match '^\s*(#|$)') { continue }
        $m = [regex]::Match($line, '^\s*([0-9]{12})\s*=\s*(.*)$')
        if ($m.Success) {   # account name (plain text, display only)
            $key = $m.Groups[1].Value; $val = $m.Groups[2].Value
            $c = [regex]::Match($val, '^(.*[^\s])?\s+#.*$'); if ($c.Success) { $val = $c.Groups[1].Value }
            $val = ($val.TrimEnd() -replace '[\x01-\x1f]', '')
            $q = [regex]::Match($val, '^"(.*)"$'); if (-not $q.Success) { $q = [regex]::Match($val, "^'(.*)'$") }
            if ($q.Success) { $val = $q.Groups[1].Value }
            if ($val.Length -gt 64) { $val = $val.Substring(0, 64) }
            $O.AccountNames[$key] = $val; continue
        }
        $m = [regex]::Match($line, '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$')
        if (-not $m.Success) { Stop-Pcr 1 "Config ${File}:${lineno}: invalid line (expected key=value)" }
        $key = $m.Groups[1].Value.ToLowerInvariant(); $val = $m.Groups[2].Value
        $q = [regex]::Match($val, '^"([^"]*)"'); if (-not $q.Success) { $q = [regex]::Match($val, "^'([^']*)'") }
        if ($q.Success) { $val = $q.Groups[1].Value }
        else {
            $c = [regex]::Match($val, '^(.*[^\s])?\s+#.*$'); if ($c.Success) { $val = $c.Groups[1].Value }
            $val = $val.TrimEnd()
        }
        switch ($key) {
            { $_ -in 'profile', 'profiles' } { $O.Profiles = Split-PcrList $val; break }
            { $_ -in 'region', 'regions' } { $O.Regions = Split-PcrList $val; break }
            'all_regions' { $O.AllRegions = Test-PcrTrue $val; break }
            'discover' { $O.Discover = Test-PcrTrue $val; break }
            'probe_parallel' { $O.ProbeParallel = $val; break }
            { $_ -in 'engine', 'engines' } { $O.Engines = Split-PcrList $val; break }
            { $_ -in 'identifier', 'identifiers' } { $O.Identifiers = Split-PcrList $val; break }
            'tag_columns' { $O.TagIgnored = $true; break }
            { $_ -in 'format', 'formats' } { $O.Formats = Split-PcrList $val; break }
            'output_dir' { $O.OutputDir = Expand-PcrHome $val; break }
            'prefix' { $O.Prefix = $val; break }
            'tz' { $O.Tz = $val; break }
            'max_behind' { $O.MaxBehind = $val; break }
            'warn_days' { $O.WarnDays = $val; break }
            'top' { $O.TopSet = $true; break }
            'non_compliant_only' { $O.NcOnly = Test-PcrTrue $val; break }
            'oracle_any_patch_line' { $O.OracleAnyLine = Test-PcrTrue $val; break }
            'fail_on_noncompliant' { $O.FailOnNc = Test-PcrTrue $val; break }
            'log_file' { $O.LogFile = Expand-PcrHome $val; break }
            'aws_timeout' { $O.AwsTimeout = $val; break }
            'max_attempts' { $O.MaxAttempts = $val; break }
            'verbose' { $O.VerboseLog = Test-PcrTrue $val; break }
            { $_ -in 'alert_email', 'alert_emails' } { $O.AlertEmails = Split-PcrList $val; break }
            { $_ -in 'alert_webhook', 'alert_webhooks' } { $O.AlertWebhooks = Split-PcrList $val; break }
            'alert_webhook_format' { $O.AlertWebhookFormat = $val; break }
            'alert_on' { $O.AlertOn = $val; break }
            'alert_from' { $O.AlertFrom = $val; break }
            'alert_smtp_server' { $O.AlertSmtpServer = $val; break }   # PowerShell extra (Windows has no sendmail)
            'aws_backend' { $O.AwsBackend = $val; break }              # PowerShell extra: AwsTools | Cli
            { $_ -in 'aws_access_key_id', 'aws_secret_access_key', 'aws_session_token', 'secret', 'password' } {
                Stop-Pcr 1 "Config ${File}:${lineno}: credentials are not accepted here; use an AWS CLI profile / SSO / role"
            }
            default { Stop-Pcr 1 "Config ${File}:${lineno}: unknown key '$key'" }
        }
    }
}

# ---------------------------------------------------------------------------------------------- validation
# Test-PcrTimeZone: an IANA (or Windows) time zone id .NET knows, or UTC
function Test-PcrTimeZone {
    param([string]$Tz)
    if ($Tz -eq 'UTC') { return $true }
    try { [void][System.TimeZoneInfo]::FindSystemTimeZoneById($Tz); return $true } catch { return $false }
}
# Confirm-PcrOptions (Bash validate): same checks, same messages, same exit code 1
function Confirm-PcrOptions {
    $O = $script:O
    if ($O.TagIgnored) { Write-PcrWarn '-TagColumns / tag_columns is ignored since v1.4.0: tag columns are no longer shown (tags stay in -SaveData / JSON)' }
    if ($O.Formats.Count -eq 0) { $O.Formats = @(if ($O.Merge) { 'html' } else { 'text' }) }
    foreach ($x in $O.Formats) { if (@('text', 'txt', 'csv', 'json', 'html') -notcontains $x.ToLowerInvariant()) { Stop-Pcr 1 "Unknown format '$x' (text,csv,json,html)" } }
    $seen = @{}; $O.Formats = @(foreach ($x in $O.Formats) { $f = $x.ToLowerInvariant(); if ($f -eq 'txt') { $f = 'text' }; if (-not $seen[$f]) { $seen[$f] = 1; $f } })
    if ($O.OutputDir -match '\.html?$') {   # -OutputDir report.html: a file name
        $O.OutFile = Split-Path -Leaf $O.OutputDir; $O.OutputDir = Split-Path -Parent $O.OutputDir
        if (-not $O.OutputDir) { $O.OutputDir = '.' }
        if ($O.Merge -and -not $O.FormatsSet) { $O.Formats = @('html') }
        if ($O.Formats -notcontains 'html') { Stop-Pcr 1 "-OutputDir $($O.OutFile) names an HTML file; add html to -Format or give a directory" }
    }
    if ($O.Merge) {
        if ($O.MergeArgs.Count -eq 0) { Stop-Pcr 1 '-Merge needs at least one -SaveData file or directory' }
        if ($O.Profiles.Count -or $O.Regions.Count -or $O.AllRegions) { Stop-Pcr 1 '-Merge works offline on saved data: -ProfileName / -Region / -AllRegions do not apply' }
        if ($O.Engines.Count -or $O.Identifiers.Count) { Stop-Pcr 1 '-Merge: -Engine / -Identifier do not apply (filter in the HTML report instead)' }
        if ($O.DryRun -or $O.SaveData -or $O.AlertTest) { Stop-Pcr 1 '-Merge cannot be combined with -DryRun, -SaveData or -AlertTest' }
    }
    if ($O.SaveDataFile) {
        if ($O.SaveDataFile -notmatch '\.json$') { Stop-Pcr 1 '-SaveDataFile must end in .json' }
        $sd = Split-Path -Parent $O.SaveDataFile; if (-not $sd) { $sd = '.' }
        if (-not $O.DryRun) {
            try { [void](New-Item -ItemType Directory -Force -Path $sd -ErrorAction Stop) } catch { Stop-Pcr 1 "-SaveData directory not writable: $sd" }
            if (-not (Test-PcrWritable $sd)) { Stop-Pcr 1 "-SaveData directory not writable: $sd" }
        }
    }
    if ($O.Formats.Count -gt 1 -and -not $O.OutputDir) { Stop-Pcr 1 'Several formats need -OutputDir' }
    if ($O.OutputDir -and -not $O.DryRun) {
        try { [void](New-Item -ItemType Directory -Force -Path $O.OutputDir -ErrorAction Stop) } catch { Stop-Pcr 1 "Output directory not writable: $($O.OutputDir)" }
        if (-not (Test-PcrWritable $O.OutputDir)) { Stop-Pcr 1 "Output directory not writable: $($O.OutputDir)" }
    }
    if ($O.Prefix -cnotmatch '^[A-Za-z0-9._-]+$') { Stop-Pcr 1 '-Prefix may contain only letters, digits, . _ -' }
    if ($O.AllRegions -and $O.Regions.Count) { Stop-Pcr 1 'Use either -Region or -AllRegions, not both' }
    foreach ($x in $O.Regions) { if ($x -cnotmatch '^[a-z]{2}(-[a-z]+)+-[0-9]+$') { Stop-Pcr 1 "Invalid region: $x" } }
    foreach ($x in $O.Profiles) { if ($x -cnotmatch '^[A-Za-z0-9_.+@-]+$') { Stop-Pcr 1 "Invalid profile name: $x" } }
    if ([string]$O.MaxBehind -notmatch '^[0-9]+$') { Stop-Pcr 1 '-MaxBehind must be a whole number (0 or more)' }
    if ([string]$O.WarnDays -notmatch '^[0-9]+$') { Stop-Pcr 1 '-WarnDays must be a whole number' }
    if ($O.TopSet) { Write-PcrWarn "-Top / top = is deprecated and ignored (v1.3.1 removed the 'most behind' list)" }
    $O.MaxBehind = [long]$O.MaxBehind; $O.WarnDays = [long]$O.WarnDays
    if (-not $O.Merge -or $O.TzSet) { if (-not (Test-PcrTimeZone $O.Tz)) { Stop-Pcr 1 "Unknown time zone: $($O.Tz)" } }
    if ([string]$O.AwsTimeout -notmatch '^[0-9]+$' -or [long]$O.AwsTimeout -eq 0) { Stop-Pcr 1 '-AwsTimeout must be a positive integer' }
    if ([string]$O.MaxAttempts -notmatch '^[0-9]+$' -or [long]$O.MaxAttempts -eq 0) { Stop-Pcr 1 '-MaxAttempts must be a positive integer' }
    if ([string]$O.ProbeParallel -notmatch '^[0-9]+$' -or [long]$O.ProbeParallel -lt 1 -or [long]$O.ProbeParallel -gt 32) { Stop-Pcr 1 '-ProbeParallel must be 1-32' }
    $O.AwsTimeout = [int]$O.AwsTimeout; $O.MaxAttempts = [int]$O.MaxAttempts; $O.ProbeParallel = [int]$O.ProbeParallel
    if ($O.AllRegions) { $O.RegionMode = if ($O.Discover) { 'discover' } else { 'full' } }
    if (@('noncompliant', 'always') -notcontains $O.AlertOn.ToLowerInvariant()) { Stop-Pcr 1 '-AlertOn must be noncompliant or always' }
    $O.AlertOn = $O.AlertOn.ToLowerInvariant()
    if (@('slack', 'json') -notcontains $O.AlertWebhookFormat.ToLowerInvariant()) { Stop-Pcr 1 '-AlertWebhookFormat must be slack or json' }
    $O.AlertWebhookFormat = $O.AlertWebhookFormat.ToLowerInvariant()
    foreach ($x in $O.AlertEmails) { if ($x -notmatch '^[^\s@;|&$`]+@[^\s@;|&$`]+$') { Stop-Pcr 1 "Invalid -AlertEmail address: $x" } }
    foreach ($x in $O.AlertWebhooks) { if ($x -notmatch '^https?://') { Stop-Pcr 1 "-AlertWebhook must be an http(s) URL: $(Get-RedactedUrl $x)" } }
    if (@('AwsTools', 'Cli') -notcontains $O.AwsBackend) { Stop-Pcr 1 '-AwsBackend must be AwsTools or Cli' }
    if ($O.LogFile -and -not $O.DryRun) {
        try { [System.IO.File]::AppendAllText($O.LogFile, '') } catch { $lf = $O.LogFile; $O.LogFile = ''; Stop-Pcr 1 "Cannot write log file: $lf" }
    }
    if (-not $O.Merge -and $O.Profiles.Count -eq 0) { $O.Profiles = @('') }
}
# Test-PcrWritable: can we create a file in this directory?
function Test-PcrWritable {
    param([string]$Dir)
    $p = Join-Path $Dir (".pcr_w_" + [guid]::NewGuid().ToString('N'))
    try { [System.IO.File]::WriteAllText($p, ''); Remove-Item -LiteralPath $p -Force; return $true } catch { return $false }
}

# ---------------------------------------------------------------------------------------------- filters
# Get-PcrFilters (Bash filters_json): {engines: [...], identifiers: [...]}
function Get-PcrFilters { return (New-JqObject ([ordered]@{ engines = @($script:O.Engines); identifiers = @($script:O.Identifiers) })) }
# Get-PcrFiltersText (Bash filters_text): "engine=a,b; identifier=x; non-compliant only; oracle: any patch line"
function Get-PcrFiltersText {
    $O = $script:O
    $p = @()
    if ($O.Engines.Count) { $p += "engine=$($O.Engines -join ',')" }
    if ($O.Identifiers.Count) { $p += "identifier=$($O.Identifiers -join ',')" }
    if ($O.NcOnly) { $p += 'non-compliant only' }
    if ($O.OracleAnyLine) { $p += 'oracle: any patch line' }
    return ($p -join '; ')
}

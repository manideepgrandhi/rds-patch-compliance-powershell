# src/Time.ps1 - clock and time zone helpers (Bash: date -u -d @N / TZ=zone date / jq strftime).
# .NET has no time zone ABBREVIATIONS (IST, EST...), so %Z comes from `date` when it exists (Linux, macOS,
# CloudShell), else from a small table, else "+0530" style - the same fallback tzdata uses.

# Get-PcrNow: the run clock in epoch seconds; RDS_PCR_NOW freezes it (tests, same variable as the Bash tool)
function Get-PcrNow {
    if ($env:RDS_PCR_NOW) { return [long]$env:RDS_PCR_NOW }
    return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}
# Get-PcrZone: TimeZoneInfo for an id ("UTC" always works)
function Get-PcrZone {
    param([string]$Tz)
    if ($Tz -eq 'UTC') { return [System.TimeZoneInfo]::Utc }
    return [System.TimeZoneInfo]::FindSystemTimeZoneById($Tz)
}
# Get-PcrTzOffset: seconds east of UTC in zone $Tz at epoch $Epoch
function Get-PcrTzOffset {
    param([string]$Tz, [long]$Epoch)
    $z = Get-PcrZone $Tz
    return [long]$z.GetUtcOffset([DateTimeOffset]::FromUnixTimeSeconds($Epoch)).TotalSeconds
}
$script:TzAbbr = @{   # fallback when `date` is not available (Windows): zone -> (standard, daylight)
    'Asia/Kolkata' = @('IST', 'IST'); 'Asia/Calcutta' = @('IST', 'IST'); 'UTC' = @('UTC', 'UTC'); 'Etc/UTC' = @('UTC', 'UTC')
    'America/New_York' = @('EST', 'EDT'); 'America/Chicago' = @('CST', 'CDT'); 'America/Denver' = @('MST', 'MDT')
    'America/Los_Angeles' = @('PST', 'PDT'); 'Europe/London' = @('GMT', 'BST'); 'Europe/Dublin' = @('GMT', 'IST')
    'Europe/Berlin' = @('CET', 'CEST'); 'Europe/Paris' = @('CET', 'CEST'); 'Europe/Amsterdam' = @('CET', 'CEST')
    'Asia/Tokyo' = @('JST', 'JST'); 'Australia/Sydney' = @('AEST', 'AEDT'); 'Asia/Seoul' = @('KST', 'KST')
    'India Standard Time' = @('IST', 'IST')
}
# Get-PcrTzAbbr: "%Z" for zone $Tz at epoch $Epoch (IST, EDT, +04 ...)
function Get-PcrTzAbbr {
    param([string]$Tz, [long]$Epoch)
    if ($Tz -eq 'UTC') { return 'UTC' }
    if (-not $IsWindows -and (Get-Command date -CommandType Application -ErrorAction SilentlyContinue)) {
        $prev = $env:TZ
        try {
            $env:TZ = $Tz
            $a = & date -d "@$Epoch" '+%Z' 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $a) { $a = & date -r $Epoch '+%Z' 2>$null }   # BSD / macOS date
            if ($LASTEXITCODE -eq 0 -and $a) { return ([string]$a).Trim() }
        } catch { Write-Debug "date failed: $_" } finally { $env:TZ = $prev }
    }
    $z = Get-PcrZone $Tz
    $dto = [DateTimeOffset]::FromUnixTimeSeconds($Epoch)
    if ($script:TzAbbr.ContainsKey($Tz)) { return $script:TzAbbr[$Tz][[int]$z.IsDaylightSavingTime($dto)] }
    $off = [long]$z.GetUtcOffset($dto).TotalMinutes
    $sign = if ($off -lt 0) { '-' } else { '+' }; $off = [Math]::Abs($off)
    $h = '{0:00}' -f [Math]::Floor($off / 60); $m = $off % 60
    if ($m -eq 0) { return "$sign$h" } else { return "$sign$h$('{0:00}' -f $m)" }
}
# Format-PcrEpoch: strftime of an epoch shifted by $OffsetSeconds (jq: (. + $off) | strftime(fmt))
function Format-PcrEpoch {
    param([double]$Epoch, [string]$Format, [long]$OffsetSeconds = 0)
    $t = [DateTimeOffset]::FromUnixTimeSeconds([long][Math]::Floor($Epoch + $OffsetSeconds)).UtcDateTime
    return $t.ToString($Format, $script:Inv)
}
# Format-PcrUtc: "2026-11-03 10:50 UTC" (jq strftime("%Y-%m-%d %H:%M UTC"))
function Format-PcrUtc { param([double]$Epoch) return (Format-PcrEpoch $Epoch 'yyyy-MM-dd HH:mm') + ' UTC' }
# Format-PcrLocal: "2026-11-03 16:20 IST" in the display zone
function Format-PcrLocal {
    param([long]$Epoch, [string]$Tz)
    return (Format-PcrEpoch $Epoch 'yyyy-MM-dd HH:mm' (Get-PcrTzOffset $Tz $Epoch)) + ' ' + (Get-PcrTzAbbr $Tz $Epoch)
}
# ConvertFrom-PcrIsoUtc: jq fromdateiso8601 for "YYYY-MM-DDTHH:MM:SSZ" -> epoch seconds ($null if invalid)
function ConvertFrom-PcrIsoUtc {
    param([string]$Text)
    $d = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParseExact($Text, "yyyy-MM-dd'T'HH:mm:ss'Z'", $script:Inv, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) {
        return [double]$d.ToUnixTimeSeconds()
    }
    return $null
}

# src/Alerts.ps1 - e-mail and webhook alerts (Bash send_email_alert / send_webhook_alert / send_alerts).
# A failed alert is a WARNING and never changes the exit code. Webhook URLs are secrets: only scheme+host is logged.

$script:SlackMaxChars = 35000

# Send-PcrEmail: mail / mailx / sendmail like Bash (Linux, macOS, CloudShell); -AlertSmtpServer = .NET SMTP (Windows)
function Send-PcrEmail {
    param([string]$Subject, [string]$Body)
    $O = $script:O
    if ($O.AlertSmtpServer) {
        $from = if ($O.AlertFrom) { $O.AlertFrom } else { "rds-patch-compliance@$([System.Net.Dns]::GetHostName())" }
        $msg = [System.Net.Mail.MailMessage]::new()
        try {
            $msg.From = $from; foreach ($t in $O.AlertEmails) { $msg.To.Add($t) }
            $msg.Subject = $Subject; $msg.Body = $Body; $msg.BodyEncoding = [System.Text.Encoding]::UTF8
            $smtp = [System.Net.Mail.SmtpClient]::new($O.AlertSmtpServer, [int]$O.AlertSmtpPort)
            $smtp.Timeout = 60000; $smtp.Send($msg); $smtp.Dispose(); return $true
        }
        catch { Write-PcrWarn "Alert: SMTP $($O.AlertSmtpServer) failed: $($_.Exception.Message)"; return $false }
        finally { $msg.Dispose() }
    }
    $mailer = $null
    foreach ($c in 'mail', 'mailx', 'sendmail') { $g = Get-Command $c -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if ($g) { $mailer = $g; break } }
    if (-not $mailer -and (Test-Path -LiteralPath '/usr/sbin/sendmail')) { $mailer = Get-Item '/usr/sbin/sendmail' }
    if (-not $mailer) { Write-PcrWarn 'Alert: no mail/mailx/sendmail found (on Windows use -AlertSmtpServer)'; return $false }
    $name = [System.IO.Path]::GetFileName($mailer.Source ?? $mailer.FullName)
    $exe = $mailer.Source ?? $mailer.FullName
    $psi = [System.Diagnostics.ProcessStartInfo]::new($exe)
    if ($name -in 'mail', 'mailx') {
        if ($O.AlertFrom) { $psi.ArgumentList.Add('-r'); $psi.ArgumentList.Add($O.AlertFrom) }
        $psi.ArgumentList.Add('-s'); $psi.ArgumentList.Add($Subject); $psi.ArgumentList.Add('--')
        foreach ($t in $O.AlertEmails) { $psi.ArgumentList.Add($t) }
        $stdin = $Body
    }
    else {
        $psi.ArgumentList.Add('-t'); $psi.ArgumentList.Add('-oi')
        $hdr = if ($O.AlertFrom) { "From: $($O.AlertFrom)`n" } else { '' }
        $stdin = $hdr + "To: $($O.AlertEmails -join ',')`nSubject: $Subject`nContent-Type: text/plain; charset=UTF-8`n`n" + $Body
    }
    $psi.RedirectStandardInput = $true; $psi.UseShellExecute = $false
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.StandardInput.Write($stdin); $p.StandardInput.Close()
        if (-not $p.WaitForExit(60000)) { $p.Kill(); return $false }   # Bash: timeout 60
        return ($p.ExitCode -eq 0)
    }
    catch { return $false }
}

# Send-PcrWebhook: POST the JSON payload (20 s timeout, 2 retries, HTTP >= 400 = failure, like curl --fail)
function Send-PcrWebhook {
    param([string]$Url, [string]$Payload)
    $red = Get-RedactedUrl $Url
    try {
        $r = Invoke-WebRequest -Uri $Url -Method Post -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($Payload)) `
            -TimeoutSec 20 -MaximumRetryCount 2 -RetryIntervalSec 1 -UseBasicParsing -ErrorAction Stop
        Write-PcrInfo "Alert: webhook $red -> HTTP $([int]$r.StatusCode)"
        return $true
    }
    catch {
        $m = ($_.Exception.Message -split "`n")[0]
        if ($m.Contains($Url)) { $m = $m.Replace($Url, $red) }   # never print the secret part of the URL
        Write-PcrWarn "Alert: webhook $red failed: $m"
        return $false
    }
}

# Get-PcrAlertMessage: subject, status, body and webhook payload (no sending; tested directly)
function Get-PcrAlertMessage {
    param($Report, [string]$Mode, [string[]]$Written = @())
    $O = $script:O
    if ($Mode -eq 'test') {
        $status = 'TEST'; $subject = "[rds_patch_compliance] TEST alert from $([System.Net.Dns]::GetHostName())"
        $lz = [System.TimeZoneInfo]::Local; $nowL = [DateTimeOffset]::Now
        $body = "Test alert from $script:ScriptName v$script:ScriptVersion at $($nowL.ToString('yyyy-MM-dd HH:mm:ss', $script:Inv)) $(Get-PcrTzAbbr $lz.Id $nowL.ToUnixTimeSeconds()). No AWS calls were made.`n"
        $payload = ConvertTo-JqJson (New-JqObject ([ordered]@{ status = 'TEST'; text = "$subject`n`n$body" })) -Compact
    }
    else {
        $s = $Report['summary']
        if ($O.AlertOn -eq 'noncompliant' -and ($s['non_compliant'] + $s['errors']) -eq 0) { return $null }
        $status = if ($s['non_compliant'] -gt 0) { 'NON-COMPLIANT' } elseif ($s['errors'] -gt 0) { 'ERRORS' } else { 'COMPLIANT' }
        $subject = "[rds_patch_compliance] ${status}: $($s['non_compliant']) non-compliant of $($s['total']), $(ConvertTo-JqText $s['pct_compliant'])% compliant"
        $body = ConvertTo-PcrText $Report
        if ($Written.Count) { $body += "`n`nReport files:`n" + (($Written | ForEach-Object { "  $_`n" }) -join '') }
        $p = Get-PcrAlertData $Report
        $p['status'] = $status; $p['text'] = "$subject`n`n$body"
        $payload = ConvertTo-JqJson $p -Compact
    }
    if ($O.AlertWebhookFormat -eq 'slack') {
        $b = if ($body.Length -gt $script:SlackMaxChars) { $body.Substring(0, $script:SlackMaxChars) + "`n... (truncated - see the report files / e-mail)" } else { $body }
        $payload = ConvertTo-JqJson (New-JqObject ([ordered]@{ text = "*$subject*`n``````$b``````" })) -Compact
    }
    return @{ Status = $status; Subject = $subject; Body = $body; Payload = $payload + "`n" }   # jq -c ends with a newline
}

# Send-PcrAlert (Bash send_alerts): -AlertOn noncompliant (default: NON-COMPLIANT or errors) | always; 'test' mode
function Send-PcrAlert {
    param($Report, [string]$Mode = '', [string[]]$Written = @())
    $O = $script:O
    if (($O.AlertEmails.Count + $O.AlertWebhooks.Count) -eq 0) { return }
    $m = Get-PcrAlertMessage $Report $Mode $Written
    if ($null -eq $m) { return }
    if ($O.AlertEmails.Count) {
        if (Send-PcrEmail $m.Subject $m.Body) { Write-PcrInfo "Alert: e-mail ($($m.Status)) sent to $($O.AlertEmails -join ' ')" }
        else { Write-PcrWarn "Alert: e-mail to $($O.AlertEmails -join ' ') failed" }
    }
    foreach ($u in $O.AlertWebhooks) { $null = Send-PcrWebhook $u $m.Payload }
}

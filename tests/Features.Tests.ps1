# tests/Features.Tests.ps1 - feature tests that need only PowerShell + the mock CLI (python3).
# Where RDS_PCR_BASH_DIR is set, the alert payloads and the exit codes are also compared with Bash.

BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:NoMock = -not (Test-MockUsable)
    $script:Chrome = @('google-chrome', 'chromium', 'chromium-browser', 'chrome') | ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
    # Exit-code cases: PowerShell arguments, Bash arguments, expected exit code
    $script:ExitCases = @(
        @{ Name = 'unknown option'; P = @('-Bogus'); B = @('--bogus'); Rc = 1 }
        @{ Name = 'bad -MaxBehind'; P = @('-MaxBehind', 'x'); B = @('--max-behind', 'x'); Rc = 1 }
        @{ Name = 'bad -WarnDays'; P = @('-WarnDays', '-3'); B = @('--warn-days', '-3'); Rc = 1 }
        @{ Name = '-ProbeParallel 0'; P = @('-ProbeParallel', '0'); B = @('--probe-parallel', '0'); Rc = 1 }
        @{ Name = '-ProbeParallel 33'; P = @('-ProbeParallel', '33'); B = @('--probe-parallel', '33'); Rc = 1 }
        @{ Name = 'unknown format'; P = @('-Format', 'pdf'); B = @('-F', 'pdf'); Rc = 1 }
        @{ Name = 'several formats without -OutputDir'; P = @('-Format', 'csv,json'); B = @('-F', 'csv,json'); Rc = 1 }
        @{ Name = 'bad -AlertOn'; P = @('-AlertOn', 'sometimes'); B = @('--alert-on', 'sometimes'); Rc = 1 }
        @{ Name = 'bad -AlertWebhookFormat'; P = @('-AlertWebhookFormat', 'teams'); B = @('--alert-webhook-format', 'teams'); Rc = 1 }
        @{ Name = 'bad -AwsTimeout'; P = @('-AwsTimeout', '0'); B = @('--aws-timeout', '0'); Rc = 1 }
        @{ Name = 'bad -MaxAttempts'; P = @('-MaxAttempts', 'many'); B = @('--max-attempts', 'many'); Rc = 1 }
        @{ Name = 'bad time zone'; P = @('-Tz', 'Mars/Olympus'); B = @('--tz', 'Mars/Olympus'); Rc = 1 }
        @{ Name = 'missing config file'; P = @('-ConfigFile', '/nonexistent.conf'); B = @('--config', '/nonexistent.conf'); Rc = 1 }
        @{ Name = '-Merge with nothing'; P = @('-Merge'); B = @('--merge'); Rc = 1 }
        @{ Name = 'bad credentials'; P = @('-ProfileName', 'prod', '-Region', 'us-east-1'); B = @('-P', 'prod', '-r', 'us-east-1'); Rc = 2; Scen = 'badcreds' }
        @{ Name = 'non-compliant + -FailOnNonCompliant'; P = @('-ProfileName', 'prod', '-Region', 'us-east-1', '-FailOnNonCompliant'); B = @('-P', 'prod', '-r', 'us-east-1', '--fail-on-noncompliant'); Rc = 5 }
        @{ Name = 'output dir not writable'; P = @('-ProfileName', 'prod', '-Region', 'us-east-1', '-OutputDir', '/proc/nope'); B = @('-P', 'prod', '-r', 'us-east-1', '-o', '/proc/nope'); Rc = 1 }
        @{ Name = '-Help'; P = @('-Help'); B = @('--help'); Rc = 0 }
        @{ Name = '-Version'; P = @('-Version'); B = @('--version'); Rc = 0 }
    )
}

Describe 'Exit codes' -Skip:$script:NoMock {
    BeforeAll { Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force; Set-PcrTestEnv }
    It '<Name> -> exit <Rc> (same as Bash when available)' -TestCases $script:ExitCases {
        $s = if ($Scen) { $Scen } else { 'fleet' }
        $rp = Invoke-PcrTool ps-report $P -Scenario $s
        $rp.ExitCode | Should -Be $Rc
        if (Get-BashDir) { (Invoke-PcrTool bash-report $B -Scenario $s).ExitCode | Should -Be $Rc }
    }
    It 'summary: -FailOnNonCompliant -> exit 5 (same as Bash when available)' {
        (Invoke-PcrTool ps-summary @('-ProfileName', 'prod', '-Region', 'us-east-1', '-FailOnNonCompliant')).ExitCode | Should -Be 5
        if (Get-BashDir) { (Invoke-PcrTool bash-summary @('-P', 'prod', '-r', 'us-east-1', '--fail-on-noncompliant')).ExitCode | Should -Be 5 }
    }
    It 'summary: -SaveData writes the same data file as Bash' {
        $dp = New-PcrTestDir 'ssp'
        (Invoke-PcrTool ps-summary @('-ProfileName', 'prod', '-Region', 'us-east-1', '-SaveData', '-Format', 'html', '-OutputDir', $dp)).ExitCode | Should -Be 0
        $fp = @(Get-ChildItem $dp | Where-Object Name -Match '^rds_patch_[0-9]+_[0-9]+\.json$')
        $fp.Count | Should -Be 1
        if (Get-BashDir) {
            $db = New-PcrTestDir 'ssb'
            (Invoke-PcrTool bash-summary @('-P', 'prod', '-r', 'us-east-1', '--save-data', '-F', 'html', '-o', $db)).ExitCode | Should -Be 0
            $fb = @(Get-ChildItem $db | Where-Object Name -Match '^rds_patch_[0-9]+_[0-9]+\.json$')
            (Get-NormalizedJson $fp[0].FullName @('.script_version')) | Should -BeExactly (Get-NormalizedJson $fb[0].FullName @('.script_version'))
        }
    }
    It 'config file with a credentials key is refused (exit 1)' {
        $d = New-PcrTestDir 'cred'; Set-Content "$d/c.conf" @('profiles = prod', 'aws_secret_access_key = abc')
        $r = Invoke-PcrTool ps-report @('-ConfigFile', "$d/c.conf")
        $r.ExitCode | Should -Be 1
        $r.Stderr | Should -Match 'credentials are not accepted here'
    }
}

Describe 'AWS back ends: AWS.Tools (real SDK objects) == AWS CLI' -Skip:$script:NoMock {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force; Set-PcrTestEnv
        $script:HasAwsTools = [bool](Get-Module -ListAvailable AWS.Tools.RDS)
    }
    It '<Scen> <A>' -TestCases @(
        @{ Scen = 'fleet'; A = @('-ProfileName', 'prod', '-Region', 'us-east-1,us-west-2') }
        @{ Scen = 'global'; A = @('-ProfileName', 'prod', '-Region', 'us-east-1,us-west-2,eu-west-1') }
        @{ Scen = 'oracle'; A = @('-ProfileName', 'prod', '-Region', 'us-east-1') }
        @{ Scen = 'accessdenied'; A = @('-ProfileName', 'prod,nonprod', '-AllRegions', '-ProbeParallel', '1') }
        @{ Scen = 'lookupfail'; A = @('-ProfileName', 'prod', '-Region', 'us-east-1') }
        @{ Scen = 'lcfail'; A = @('-ProfileName', 'prod', '-Region', 'us-east-1') }
        @{ Scen = 'fleet'; A = @('-ProfileName', 'prod,broken', '-Region', 'us-east-1') }
    ) {
        if (-not $script:HasAwsTools) { Set-ItResult -Skipped -Because 'AWS.Tools.RDS is not installed'; return }
        $dc = New-PcrTestDir 'cli'; $dt = New-PcrTestDir 'tools'
        $common = $A + @('-Format', 'text,csv,json,html', '-Verbose')
        $rc = Invoke-PcrTool ps-report ($common + @('-OutputDir', $dc)) -Scenario $Scen
        $rt = Invoke-PcrTool ps-report-tools ($common + @('-OutputDir', $dt)) -Scenario $Scen
        $rt.ExitCode | Should -Be $rc.ExitCode
        Compare-PcrOutputDir $dc $dt -JsonDelete @() | Should -BeNullOrEmpty
        (Get-LogBody $rt.Stderr $dt) | Should -BeExactly (Get-LogBody $rc.Stderr $dc)
    }
}

Describe 'Parallel region discovery (ForEach-Object -Parallel)' -Skip:$script:NoMock {
    BeforeAll { Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force; Set-PcrTestEnv }
    It '-ProbeParallel 8 gives the same report as 1 and is faster' {
        $d1 = New-PcrTestDir 'p1'; $d8 = New-PcrTestDir 'p8'
        $e = @{ MOCK_PROBE_DELAY = '0.5' }   # every probe call takes 0.5 s
        $t1 = Measure-Command { $script:r1 = Invoke-PcrTool ps-report @('-ProfileName', 'prod', '-AllRegions', '-ProbeParallel', '1', '-Format', 'json', '-OutputDir', $d1) -Scenario discover -Env $e }
        $t8 = Measure-Command { $script:r8 = Invoke-PcrTool ps-report @('-ProfileName', 'prod', '-AllRegions', '-ProbeParallel', '8', '-Format', 'json', '-OutputDir', $d8) -Scenario discover -Env $e }
        $script:r1.ExitCode | Should -Be 0
        $script:r8.ExitCode | Should -Be 0
        # only the recorded -ProbeParallel value may differ
        $j1 = (Get-NormalizedJson (Get-ChildItem $d1 -Filter *.json)[0].FullName) -replace '"probe_parallel": \d+', 'PP'
        $j8 = (Get-NormalizedJson (Get-ChildItem $d8 -Filter *.json)[0].FullName) -replace '"probe_parallel": \d+', 'PP'
        $j8 | Should -BeExactly $j1
        $t8.TotalSeconds | Should -BeLessThan ($t1.TotalSeconds * 0.6)
    }
}

Describe 'Dry run, keep-workdir, -ReturnReport' -Skip:$script:NoMock {
    BeforeAll { Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force; Set-PcrTestEnv }
    It '-DryRun makes no AWS call and prints the plan (same as Bash apart from the name line)' {
        $bin = New-PcrTestDir 'trap'; $marker = Join-Path $bin 'CALLED'
        Set-Content (Join-Path $bin 'aws') "#!/bin/sh`ntouch '$marker'`nexit 1"; chmod +x (Join-Path $bin 'aws')
        $a = @('-ProfileName', 'prod,nonprod', '-AllRegions', '-Format', 'csv,html', '-OutputDir', '/tmp/x', '-DryRun')
        $r = Invoke-PcrTool ps-report $a -Env @{ PATH = $bin + ':' + $env:PATH }
        $r.ExitCode | Should -Be 0
        Test-Path $marker | Should -BeFalse
        $r.Stdout | Should -Match 'describe-db-clusters'
        if (Get-BashDir) {
            $rb = Invoke-PcrTool bash-report @('-P', 'prod,nonprod', '-A', '-F', 'csv,html', '-o', '/tmp/x', '--dry-run') -Env @{ PATH = $bin + ':' + $env:PATH }
            (($r.Stdout -split "`n") | Select-Object -Skip 1) -join "`n" | Should -BeExactly ((($rb.Stdout -split "`n") | Select-Object -Skip 1) -join "`n")
        }
    }
    It '-KeepWorkdir keeps one raw JSON per AWS call' {
        $r = Invoke-PcrTool ps-report @('-ProfileName', 'prod', '-Region', 'us-east-1', '-KeepWorkdir', '-Format', 'csv')
        $r.ExitCode | Should -Be 0
        $r.Stderr -match 'Raw AWS responses kept in (\S+)' | Should -BeTrue
        $kept = $Matches[1]
        @(Get-ChildItem $kept -Recurse -Filter *.json).Count | Should -BeGreaterThan 3
        Remove-Item -Recurse -Force $kept
    }
    It 'in-process call returns the exit code; -ReturnReport returns the report object' {
        Import-Module (Join-Path (Get-PcrTestRoot) 'src/RdsPatchCompliance.psm1') -Force
        $env:MOCK_SCENARIO = 'fleet'
        try {
            $null = Invoke-RdsPatchCompliance -AwsBackend Cli -ProfileName prod -Region us-east-1 -ReturnReport 2>$null
            $res = & (Get-Module RdsPatchCompliance) { $script:LastResult }
            $res.ExitCode | Should -Be 0
            @($res.Report['rows']).Count | Should -BeGreaterThan 0
        }
        finally { Remove-Item env:MOCK_SCENARIO }
    }
}

Describe 'Alerts' -Skip:$script:NoMock {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force; Set-PcrTestEnv
        $script:Kit = Join-Path $PSScriptRoot 'alerts'
        $script:Hook = New-PcrTestDir 'hook'
        $script:Port = Get-Random -Minimum 20000 -Maximum 40000
        $script:HookProc = Start-Process python3 -ArgumentList @((Join-Path $script:Kit 'hook.py'), $script:Port, (Join-Path $script:Hook 'h')) -PassThru
        Start-Sleep -Milliseconds 700
        $script:PathWithMail = $script:Kit + ':' + $env:PATH
        # Send-Both: run both tools with the same alert settings; return the captured mail + webhook bodies
        function Send-Both {
            param([string]$Tag, [string[]]$P, [string[]]$B, [string]$Tool = 'report')
            $out = @{}
            foreach ($t in @('p') + $(if (Get-BashDir) { @('b') } else { @() })) {
                $cap = Join-Path $script:Hook "mail_${Tag}_$t"
                $a = if ($t -eq 'p') { $P + @('-AlertWebhook', "http://127.0.0.1:$($script:Port)/${Tag}_$t") } else { $B + @('--alert-webhook', "http://127.0.0.1:$($script:Port)/${Tag}_$t") }
                $toolName = $(if ($t -eq 'p') { 'ps' } else { 'bash' }) + "-$Tool"
                $r = Invoke-PcrTool $toolName $a -Env @{ PATH = $script:PathWithMail; ALERT_CAPTURE = $cap }
                $out[$t] = @{ Rc = $r.ExitCode; Err = $r.Stderr
                    Mail = $(if (Test-Path $cap) { Get-Content -Raw $cap } else { $null })
                    Hook = $(if (Test-Path "$($script:Hook)/h.${Tag}_$t") { Get-Content -Raw "$($script:Hook)/h.${Tag}_$t" } else { $null }) }
            }
            return $out
        }
        $script:Norm = { param($t) if ($null -eq $t) { return $null }; $t -replace 'Invoke-RdsPatchCompliance(Summary)?\.ps1 v[0-9.]+', 'TOOL' -replace 'rds_patch_compliance_(report|summary)\.sh v?[0-9.]+', 'TOOL' -replace 'full per-server details: \S+', 'X' }
    }
    AfterAll { if ($script:HookProc) { Stop-Process -Id $script:HookProc.Id -ErrorAction SilentlyContinue } }

    It 'report: e-mail + <_> webhook payloads (same as Bash)' -TestCases @('slack', 'json') {
        $o = Send-Both "r$_" @('-ProfileName', 'prod', '-Region', 'us-east-1', '-AlertEmail', 'dba@example.com', '-AlertFrom', 'pcr@example.com', '-AlertWebhookFormat', $_) @('-P', 'prod', '-r', 'us-east-1', '--alert-email', 'dba@example.com', '--alert-from', 'pcr@example.com', '--alert-webhook-format', $_)
        $o.p.Rc | Should -Be 0
        $o.p.Mail | Should -Match '\[-s\]'
        $o.p.Hook | Should -Not -BeNullOrEmpty
        $o.p.Err | Should -Not -Match '127\.0\.0\.1:\d+/r'   # the webhook URL is never logged in full
        if ($o.b) {
            (& $script:Norm $o.p.Mail) | Should -BeExactly (& $script:Norm $o.b.Mail)
            (& $script:Norm $o.p.Hook) | Should -BeExactly (& $script:Norm $o.b.Hook)
        }
    }
    It 'summary: e-mail + <_> webhook payloads (same as Bash)' -TestCases @('slack', 'json') {
        $o = Send-Both "s$_" @('-ProfileName', 'prod', '-Region', 'us-east-1', '-AlertEmail', 'dba@example.com', '-AlertWebhookFormat', $_) @('-P', 'prod', '-r', 'us-east-1', '--alert-email', 'dba@example.com', '--alert-webhook-format', $_) -Tool summary
        $o.p.Rc | Should -Be 0
        $o.p.Mail | Should -Not -BeNullOrEmpty
        $o.p.Hook | Should -Not -BeNullOrEmpty
        if ($o.b) {
            (& $script:Norm $o.p.Mail) | Should -BeExactly (& $script:Norm $o.b.Mail)
            (& $script:Norm $o.p.Hook) | Should -BeExactly (& $script:Norm $o.b.Hook)
        }
    }
    It '-AlertTest sends a test message and makes no AWS call' {
        $o = Send-Both 'test' @('-AlertTest', '-AlertEmail', 'dba@example.com') @('--alert-test', '--alert-email', 'dba@example.com')
        $o.p.Rc | Should -Be 0
        $o.p.Mail | Should -Match 'Test alert from'
        $o.p.Hook | Should -Match 'Test alert from'
    }
    It '-AlertOn noncompliant: no alert when everything is compliant' {
        $o = Send-Both 'quiet' @('-ProfileName', 'prod', '-Region', 'us-east-1', '-MaxBehind', '99', '-AlertEmail', 'dba@example.com') @('-P', 'prod', '-r', 'us-east-1', '--max-behind', '99', '--alert-email', 'dba@example.com')
        $o.p.Rc | Should -Be 0
        $o.p.Mail | Should -BeNullOrEmpty
        $o.p.Hook | Should -BeNullOrEmpty
    }
}

Describe 'HTML page works offline' -Skip:$script:NoMock {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force; Set-PcrTestEnv
        $script:Out = New-PcrTestDir 'html'
        $null = Invoke-PcrTool ps-report @('-ProfileName', 'prod,nonprod', '-Region', 'us-east-1,us-west-2', '-Format', 'html', '-OutputDir', "$($script:Out)/r.html")
        $null = Invoke-PcrTool ps-summary @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Format', 'html', '-OutputDir', "$($script:Out)/s")
        $script:Pages = @("$($script:Out)/r.html") + @(Get-ChildItem "$($script:Out)/s" -Filter *.html | ForEach-Object FullName)
    }
    It 'pages have no external script / style / image / font references' {
        $script:Pages.Count | Should -Be 2
        foreach ($p in $script:Pages) {
            $h = Get-Content -Raw $p
            $h | Should -Not -Match '<(script|link|img|iframe)[^>]+(src|href)\s*=\s*"(https?:)?//'
            $h | Should -Not -Match '@import|url\(\s*["'']?https?:'
        }
    }
    It 'headless Chrome with networking disabled renders the table and the scripts run' -Skip:(-not $script:Chrome) {
        $chrome = @('google-chrome', 'chromium', 'chromium-browser', 'chrome') | ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
        $dom = & $chrome.Source --headless=new --no-sandbox --disable-gpu --proxy-server='http://127.0.0.1:9' --proxy-bypass-list='<-loopback>' --virtual-time-budget=3000 --dump-dom "file://$($script:Out)/r.html" 2>$null
        $dom = $dom -join "`n"
        $dom | Should -Match '<table'
        $dom | Should -Match 'NON-COMPLIANT'
        $dom | Should -Match 'Content-Security-Policy|<script'
    }
}

# tests/Parity.Tests.ps1 - the PowerShell port against the Bash original, same mock data, frozen clock.
# Needs RDS_PCR_BASH_DIR = a clone of manideepgrandhi/rds-patch-compliance (plus bash, jq, python3);
# skipped otherwise. Run:  $env:RDS_PCR_BASH_DIR='../rds-patch-compliance'; Invoke-Pester ./tests
# Every output file must match after normalisation (meta.script / version / host, the HTML footer and
# the tool-name line); the stderr log must match line for line except for the output directory.

BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:NoBash = -not (Get-BashDir)
    $F = 'text,csv,json,html'
    # Name, mock scenario, Bash arguments, PowerShell arguments, extra environment
    $script:ScanCases = @(
        @{ Name = 'fleet, 2 regions'; Scen = 'fleet'; B = @('-P', 'prod', '-r', 'us-east-1,us-west-2', '-F', $F, '-v'); P = @('-ProfileName', 'prod', '-Region', 'us-east-1,us-west-2', '-Format', $F, '-Verbose') }
        @{ Name = 'Aurora global databases'; Scen = 'global'; B = @('-P', 'prod', '-r', 'us-east-1,us-west-2,eu-west-1', '-F', $F, '-v'); P = @('-ProfileName', 'prod', '-Region', 'us-east-1,us-west-2,eu-west-1', '-Format', $F, '-Verbose') }
        @{ Name = 'Oracle patch lines'; Scen = 'oracle'; B = @('-P', 'prod', '-r', 'us-east-1', '-F', $F); P = @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Format', $F) }
        @{ Name = 'Oracle any patch line'; Scen = 'oracle'; B = @('-P', 'prod', '-r', 'us-east-1', '-F', $F, '--oracle-any-patch-line'); P = @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Format', $F, '-OracleAnyPatchLine') }
        @{ Name = 'discovery, 2 accounts'; Scen = 'fleet'; B = @('-P', 'prod,nonprod', '-A', '-F', $F, '-v'); P = @('-ProfileName', 'prod,nonprod', '-AllRegions', '-Format', $F, '-Verbose') }
        @{ Name = 'no discovery'; Scen = 'fleet'; B = @('-P', 'prod', '-A', '--no-discover', '-F', $F); P = @('-ProfileName', 'prod', '-AllRegions', '-NoDiscover', '-Format', $F) }
        @{ Name = 'access denied'; Scen = 'accessdenied'; B = @('-P', 'prod,nonprod', '-A', '-F', $F, '-v'); P = @('-ProfileName', 'prod,nonprod', '-AllRegions', '-Format', $F, '-Verbose') }
        @{ Name = 'no lifecycle API'; Scen = 'nolc'; B = @('-P', 'prod', '-r', 'us-east-1', '-F', $F, '-v'); P = @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Format', $F, '-Verbose') }
        @{ Name = 'lifecycle lookup fails'; Scen = 'lcfail'; B = @('-P', 'prod', '-r', 'us-east-1', '-F', $F, '-v'); P = @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Format', $F, '-Verbose') }
        @{ Name = 'version lookup fails'; Scen = 'lookupfail'; B = @('-P', 'prod', '-r', 'us-east-1', '-F', $F, '-v'); P = @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Format', $F, '-Verbose') }
        @{ Name = 'no databases'; Scen = 'empty'; B = @('-P', 'prod', '-A', '-F', $F); P = @('-ProfileName', 'prod', '-AllRegions', '-Format', $F) }
        @{ Name = 'one broken profile'; Scen = 'fleet'; B = @('-P', 'prod,broken', '-r', 'us-east-1', '-F', $F); P = @('-ProfileName', 'prod,broken', '-Region', 'us-east-1', '-Format', $F) }
        @{ Name = 'filters + non-compliant only'; Scen = 'fleet'; B = @('-P', 'prod', '-r', 'us-east-1,us-west-2', '-e', 'aurora-*', '-e', 'postgres', '-i', '*prod*', '--non-compliant-only', '-F', $F); P = @('-ProfileName', 'prod', '-Region', 'us-east-1,us-west-2', '-Engine', 'aurora-*,postgres', '-Identifier', '*prod*', '-NonCompliantOnly', '-Format', $F) }
        @{ Name = 'max-behind 0, warn-days 900, tz'; Scen = 'fleet'; B = @('-P', 'prod', '-r', 'us-east-1,us-west-2', '--max-behind', '0', '--warn-days', '900', '--tz', 'America/New_York', '-F', $F); P = @('-ProfileName', 'prod', '-Region', 'us-east-1,us-west-2', '-MaxBehind', '0', '-WarnDays', '900', '-Tz', 'America/New_York', '-Format', $F) }
        @{ Name = 'large (300 servers)'; Scen = 'large'; Env = @{ MOCK_LARGE_N = '300' }; B = @('-P', 'prod', '-r', 'us-east-1', '-F', $F); P = @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Format', $F) }
        @{ Name = '3 accounts with aliases'; Scen = 'fleet'; B = @('-P', 'prod,nonprod,dev', '-r', 'us-east-1,eu-west-1', '-F', $F); P = @('-ProfileName', 'prod,nonprod,dev', '-Region', 'us-east-1,eu-west-1', '-Format', $F) }
        @{ Name = 'prefix + single html file'; Scen = 'fleet'; B = @('-P', 'prod', '-r', 'us-east-1', '-F', 'html,csv', '--prefix', 'weekly'); P = @('-ProfileName', 'prod', '-Region', 'us-east-1', '-Format', 'html,csv', '-Prefix', 'weekly') }
    )
    $script:SummaryCases = @(
        @{ Name = 'fleet'; Scen = 'fleet'; B = @('-P', 'prod', '-r', 'us-east-1,us-west-2'); P = @('-ProfileName', 'prod', '-Region', 'us-east-1,us-west-2') }
        @{ Name = 'discovery'; Scen = 'fleet'; B = @('-P', 'prod,nonprod', '-A'); P = @('-ProfileName', 'prod,nonprod', '-AllRegions') }
        @{ Name = 'global'; Scen = 'global'; B = @('-P', 'prod', '-r', 'us-east-1,us-west-2,eu-west-1'); P = @('-ProfileName', 'prod', '-Region', 'us-east-1,us-west-2,eu-west-1') }
        @{ Name = 'oracle + broken, max-behind 1'; Scen = 'oracle'; B = @('-P', 'prod,broken', '-r', 'us-east-1', '--max-behind', '1'); P = @('-ProfileName', 'prod,broken', '-Region', 'us-east-1', '-MaxBehind', '1') }
        @{ Name = 'empty'; Scen = 'empty'; B = @('-P', 'prod', '-A'); P = @('-ProfileName', 'prod', '-AllRegions') }
    )
}

Describe 'Parity: scan report (Bash vs PowerShell)' -Skip:$script:NoBash {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
        Set-PcrTestEnv
    }
    It '<Name>: same files, same exit code, same log' -TestCases $script:ScanCases {
        $e = if ($Env) { $Env } else { @{} }
        $db = New-PcrTestDir 'b'; $dp = New-PcrTestDir 'p'
        $rb = Invoke-PcrTool bash-report ($B + @('-o', $db)) -Scenario $Scen -Env $e
        $rp = Invoke-PcrTool ps-report ($P + @('-OutputDir', $dp)) -Scenario $Scen -Env $e
        $rp.ExitCode | Should -Be $rb.ExitCode
        Compare-PcrOutputDir $db $dp | Should -BeNullOrEmpty
        (Get-LogBody $rp.Stderr $dp) | Should -BeExactly (Get-LogBody $rb.Stderr $db)
    }
    It 'stdout CSV (no -OutputDir) is byte-identical' {
        $rb = Invoke-PcrTool bash-report @('-P', 'prod', '-r', 'us-east-1,us-west-2', '-F', 'csv')
        $rp = Invoke-PcrTool ps-report @('-ProfileName', 'prod', '-Region', 'us-east-1,us-west-2', '-Format', 'csv')
        $rp.Stdout | Should -BeExactly $rb.Stdout
        $rp.Stdout | Should -Match 'COMPLIANT'
    }
    It 'stdout text report is identical (apart from the tool name)' {
        $rb = Invoke-PcrTool bash-report @('-P', 'prod', '-r', 'us-east-1')
        $rp = Invoke-PcrTool ps-report @('-ProfileName', 'prod', '-Region', 'us-east-1')
        ($rp.Stdout -replace 'Invoke-RdsPatchCompliance\.ps1 v[0-9.]+', 'TOOL') | Should -BeExactly ($rb.Stdout -replace 'rds_patch_compliance_report\.sh v[0-9.]+', 'TOOL')
    }
    It 'bad credentials: exit 2 with the same messages' {
        $rb = Invoke-PcrTool bash-report @('-P', 'prod', '-r', 'us-east-1') -Scenario badcreds
        $rp = Invoke-PcrTool ps-report @('-ProfileName', 'prod', '-Region', 'us-east-1') -Scenario badcreds
        $rb.ExitCode | Should -Be 2
        $rp.ExitCode | Should -Be 2
        (Get-LogBody $rp.Stderr 'x') | Should -BeExactly (Get-LogBody $rb.Stderr 'x')
    }
    It 'config file (account names, log_file, verbose): same outputs and same log file' {
        $d = New-PcrTestDir 'cfg'
        $conf = Join-Path $d 'pcr.conf'
        Set-Content -LiteralPath $conf -Value @(
            '# test config', 'profiles = prod,nonprod', 'regions = us-east-1', 'formats = csv,json', 'verbose = yes', "log_file = $d/LOG.log",
            '111111111111 = "Core Production"', '222222222222 = Non Prod  # comment')
        $db = New-PcrTestDir 'b'; $dp = New-PcrTestDir 'p'
        $rb = Invoke-PcrTool bash-report @('--config', $conf, '-o', $db)
        $lb = (Get-Content -Raw "$d/LOG.log"); Remove-Item "$d/LOG.log"
        $rp = Invoke-PcrTool ps-report @('-ConfigFile', $conf, '-OutputDir', $dp)
        $lp = (Get-Content -Raw "$d/LOG.log")
        $rp.ExitCode | Should -Be $rb.ExitCode
        Compare-PcrOutputDir $db $dp | Should -BeNullOrEmpty
        (Get-LogBody $lp $dp) | Should -BeExactly (Get-LogBody $lb $db)
    }
}

Describe 'Parity: summary script (Bash vs PowerShell)' -Skip:$script:NoBash {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
        Set-PcrTestEnv
    }
    It 'summary <Name>: txt / html / 4 CSVs and stdout match' -TestCases $script:SummaryCases {
        $db = New-PcrTestDir 'sb'; $dp = New-PcrTestDir 'sp'
        $rb = Invoke-PcrTool bash-summary ($B + @('-F', 'txt,html,csv', '-o', $db)) -Scenario $Scen
        $rp = Invoke-PcrTool ps-summary ($P + @('-Format', 'txt,html,csv', '-OutputDir', $dp)) -Scenario $Scen
        $rp.ExitCode | Should -Be $rb.ExitCode
        # summary files are stamped with the real UTC time, so match them by suffix
        Compare-PcrOutputDir $db $dp -BySuffix | Should -BeNullOrEmpty
        $norm = { param($t) [regex]::Replace($t, 'full per-server details: .*', 'X') }
        (& $norm $rp.Stdout) | Should -BeExactly (& $norm $rb.Stdout)
    }
}

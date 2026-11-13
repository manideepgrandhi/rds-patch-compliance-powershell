# tests/Merge.Tests.ps1 - -SaveData / -Merge, including cross-compatibility with the Bash tool:
#   PS save -> PS merge, Bash save -> PS merge, PS save -> Bash merge, Bash save -> Bash merge (reference),
#   a 3-account merge with an older + newer file of the same account, the v1.3.0 fixtures, the summary
#   script's -Merge, and every exit-3 bad-input message.
# The Bash parts need RDS_PCR_BASH_DIR (see Parity.Tests.ps1); the PowerShell-only parts always run.

BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:NoBash = -not (Get-BashDir)
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    Set-PcrTestEnv
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures/v130'
    $script:HasBash = [bool](Get-BashDir)
    $F = 'text,csv,json,html'

    # New-SaveSet: four collections (prod twice: old 1 region / newer 2 regions, nonprod global, dev oracle)
    function New-SaveSet {
        param([ValidateSet('bash', 'ps')][string]$Tool)
        $dir = New-PcrTestDir "save_$Tool"; New-Item -ItemType Directory "$dir/old" | Out-Null
        $runs = @(
            @{ Now = '1793000000'; Scen = 'fleet'; Profile = 'prod'; Region = 'us-east-1'; Old = $true }
            @{ Now = '1793600000'; Scen = 'fleet'; Profile = 'prod'; Region = 'us-east-1,ap-south-1' }
            @{ Now = '1793500000'; Scen = 'global'; Profile = 'nonprod'; Region = 'us-east-1' }
            @{ Now = '1793650000'; Scen = 'oracle'; Profile = 'dev'; Region = 'eu-west-1' }
        )
        foreach ($r in $runs) {
            $run = New-PcrTestDir 'run'
            $a = if ($Tool -eq 'bash') { @('-P', $r.Profile, '-r', $r.Region, '--save-data', '-o', $run, '-F', 'json') } else { @('-ProfileName', $r.Profile, '-Region', $r.Region, '-SaveData', '-OutputDir', $run, '-Format', 'json') }
            $res = Invoke-PcrTool "$Tool-report" $a -Scenario $r.Scen -Env @{ RDS_PCR_NOW = $r.Now }
            if ($res.ExitCode -ne 0) { throw "$Tool save failed: $($res.Stderr)" }
            $f = Get-ChildItem $run -File | Where-Object Name -Match '^rds_patch_[0-9]+_[0-9]+\.json$' | Select-Object -First 1
            $dest = if ($r.Old) { "$dir/old/prod_old.json" } else { Join-Path $dir $f.Name }
            Move-Item $f.FullName $dest
        }
        return $dir
    }
    # Invoke-Merge: merge <set>/old/prod_old.json + <set>/*.json with one tool into a new directory
    function Invoke-Merge {
        param([string]$Tool, [string]$Set, [string[]]$Extra = @())
        $out = New-PcrTestDir "m_$Tool"
        $files = @("$Set/old/prod_old.json") + @(Get-ChildItem $Set -Filter '*.json' | Sort-Object Name | ForEach-Object FullName)
        $a = if ($Tool -eq 'bash') { @('--merge') + $files + $Extra + @('-F', $F, '-o', $out) } else { @('-Merge') + $files + $Extra + @('-Format', $F, '-OutputDir', $out) }
        $res = Invoke-PcrTool "$Tool-report" $a
        return @{ Dir = $out; Res = $res }
    }
    $script:MergeJsonDelete = @('.meta.script', '.meta.version', '.meta.host', '.meta.merge.sources[].script_version')

    $script:PsSet = New-SaveSet ps
    if ($script:HasBash) { $script:BashSet = New-SaveSet bash }
}

Describe 'Merge: PowerShell only' {
    It 'PS save -> PS merge: exit 0, all accounts, newest prod collection wins' {
        $m = Invoke-Merge ps $script:PsSet
        $m.Res.ExitCode | Should -Be 0
        $json = Get-ChildItem $m.Dir -Filter '*.json' | Select-Object -First 1
        $j = Get-Content -Raw $json.FullName | ConvertFrom-Json -AsHashtable
        @($j.meta.accounts.account) | Sort-Object | Should -Be @('111111111111', '222222222222', '333333333333')
        # prod is in two files: the newer collection is used, the older one is listed as superseded
        $src = @($j.meta.merge.sources)
        ($src | Where-Object file -EQ 'prod_old.json').superseded | Should -Be @('111111111111')
        @(($src | Where-Object { $_.file -like 'rds_patch_111111111111_*' }).used) | Should -Be @('111111111111')
        (Get-ChildItem $m.Dir -Filter '*.html').Count | Should -Be 1
        $m.Res.Stderr | Should -Match 'Account 111111111111: using newer rds_patch_111111111111_'
    }
    It 'saved file has the Bash schema (schema, schema_version 1, accounts, rows, collected_epoch)' {
        $f = Get-ChildItem $script:PsSet -Filter '*.json' | Select-Object -First 1
        $j = Get-Content -Raw $f.FullName | ConvertFrom-Json -AsHashtable
        $j.schema_version | Should -Be 1
        $j.collected_epoch | Should -BeOfType [long]
        @($j.accounts).Count | Should -BeGreaterThan 0
        @($j.rows).Count | Should -BeGreaterThan 0
    }
    It 'merges the v1.3.0 fixtures (older Bash release) into one -OutputDir FILE.html' {
        $out = New-PcrTestDir 'fx'
        $res = Invoke-PcrTool ps-report @('-Merge', $script:Fixtures, '-OutputDir', "$out/all.html")
        $res.ExitCode | Should -Be 0
        Test-Path "$out/all.html" | Should -BeTrue
    }
    It 'merge makes zero AWS calls (works with no aws on PATH)' {
        # an `aws` that leaves a marker file if it is ever run
        $bin = New-PcrTestDir 'trap'; $marker = Join-Path $bin 'CALLED'
        Set-Content (Join-Path $bin 'aws') "#!/bin/sh`ntouch '$marker'`nexit 1"
        if (-not $IsWindows) { chmod +x (Join-Path $bin 'aws') }
        $res = Invoke-PcrTool ps-report @('-Merge', $script:Fixtures, '-Format', 'csv') -Env @{ PATH = $bin + [System.IO.Path]::PathSeparator + $env:PATH }
        $res.ExitCode | Should -Be 0
        Test-Path $marker | Should -BeFalse
        $res.Stdout | Should -Match '111111111111'
    }
}

Describe 'Merge: cross-compatible with the Bash tool' -Skip:$script:NoBash {
    It 'saved data files are identical (apart from script_version): <_>' -TestCases @('old/prod_old.json', 'rds_patch_111111111111_*.json', 'rds_patch_222222222222_*.json', 'rds_patch_333333333333_*.json') {
        $b = @(Get-ChildItem (Join-Path $script:BashSet $_))[0]; $p = @(Get-ChildItem (Join-Path $script:PsSet $_))[0]
        $b | Should -Not -BeNullOrEmpty
        $p | Should -Not -BeNullOrEmpty
        (Get-NormalizedJson $p.FullName @('.script_version')) | Should -BeExactly (Get-NormalizedJson $b.FullName @('.script_version'))
    }
    It 'Bash save -> PS merge == Bash save -> Bash merge' {
        $bb = Invoke-Merge bash $script:BashSet; $pb = Invoke-Merge ps $script:BashSet
        $pb.Res.ExitCode | Should -Be $bb.Res.ExitCode
        Compare-PcrOutputDir $bb.Dir $pb.Dir -JsonDelete $script:MergeJsonDelete | Should -BeNullOrEmpty
        (Get-LogBody $pb.Res.Stderr $pb.Dir) | Should -BeExactly (Get-LogBody $bb.Res.Stderr $bb.Dir)
    }
    It 'PS save -> Bash merge == Bash save -> Bash merge' {
        $bb = Invoke-Merge bash $script:BashSet; $bp = Invoke-Merge bash $script:PsSet
        $bp.Res.ExitCode | Should -Be 0
        Compare-PcrOutputDir $bb.Dir $bp.Dir -JsonDelete $script:MergeJsonDelete | Should -BeNullOrEmpty
    }
    It 'PS save -> PS merge == Bash save -> Bash merge' {
        $bb = Invoke-Merge bash $script:BashSet; $pp = Invoke-Merge ps $script:PsSet
        $pp.Res.ExitCode | Should -Be 0
        Compare-PcrOutputDir $bb.Dir $pp.Dir -JsonDelete $script:MergeJsonDelete | Should -BeNullOrEmpty
    }
    It 'multi-account merge with -MaxBehind 1 -OracleAnyPatchLine matches' {
        $bb = Invoke-Merge bash $script:BashSet @('--max-behind', '1', '--oracle-any-patch-line')
        $pb = Invoke-Merge ps $script:BashSet @('-MaxBehind', '1', '-OracleAnyPatchLine')
        Compare-PcrOutputDir $bb.Dir $pb.Dir -JsonDelete $script:MergeJsonDelete | Should -BeNullOrEmpty
    }
    It 'v1.3.0 fixtures + a new file into all.html: same page and same log' {
        $new = @(Get-ChildItem $script:BashSet -Filter 'rds_patch_333333333333_*.json')[0].FullName
        $ob = New-PcrTestDir 'fb'; $op = New-PcrTestDir 'fp'
        $rb = Invoke-PcrTool bash-report @('--merge', $script:Fixtures, $new, '-o', "$ob/all.html")
        $rp = Invoke-PcrTool ps-report @('-Merge', $script:Fixtures, $new, '-OutputDir', "$op/all.html")
        $rp.ExitCode | Should -Be $rb.ExitCode
        Compare-PcrOutputDir $ob $op | Should -BeNullOrEmpty
        (Get-LogBody $rp.Stderr $op) | Should -BeExactly (Get-LogBody $rb.Stderr $ob)
    }
    It 'summary script -Merge matches (txt, html, CSVs)' {
        $db = New-PcrTestDir 'sb'; $dp = New-PcrTestDir 'sp'
        $rb = Invoke-PcrTool bash-summary @('--merge', $script:BashSet, '-F', 'txt,html,csv', '-o', $db)
        $rp = Invoke-PcrTool ps-summary @('-Merge', $script:PsSet, '-Format', 'txt,html,csv', '-OutputDir', $dp)
        $rp.ExitCode | Should -Be $rb.ExitCode
        Compare-PcrOutputDir $db $dp -BySuffix | Should -BeNullOrEmpty
    }
}

Describe 'Merge: bad input files exit 3 with the Bash message' {
    BeforeAll {
        $script:Bad = New-PcrTestDir 'bad'
        Set-Content "$script:Bad/page.html" '<!DOCTYPE html><html><body>x</body></html>'
        Set-Content "$script:Bad/trunc.json" '{"schema": "rds-patch-compliance-data", "schema_ver'
        Set-Content "$script:Bad/report.json" '{"meta": {}, "summary": {}, "rows": []}'
        Set-Content "$script:Bad/array.json" '[1, 2]'
        Set-Content "$script:Bad/other.json" '{"hello": 1}'
        $src = Get-Content -Raw (@(Get-ChildItem $script:PsSet -Filter '*.json')[0].FullName) | ConvertFrom-Json -AsHashtable
        $schema = $src.schema
        $nv = $src.Clone(); $nv.Remove('schema_version'); $nv | ConvertTo-Json -Depth 30 | Set-Content "$script:Bad/noversion.json"
        $inc = $src.Clone(); $inc.accounts = @(); $inc | ConvertTo-Json -Depth 30 | Set-Content "$script:Bad/incomplete.json"
        $old = $src.Clone(); $old.schema_version = 0; $old | ConvertTo-Json -Depth 30 | Set-Content "$script:Bad/old.json"
        $newer = $src.Clone(); $newer.schema_version = 9; $newer | ConvertTo-Json -Depth 30 | Set-Content "$script:Bad/newer.json"
        New-Item -ItemType Directory "$script:Bad/emptydir" | Out-Null
        Set-Content "$script:Bad/emptydir/notes.json" '{"x": 1}'
        $script:Schema = $schema
        # PowerShell parameter names -> the Bash spelling, so the messages can be compared
        $script:ToBash = { param($t) $t.Replace('-SaveData', '--save-data').Replace('-Format json', '-F json').Replace('Invoke-RdsPatchCompliance.ps1', 'rds_patch_compliance_report.sh') -replace 're-run v[0-9.]+ ', 're-run vX ' }
    }
    It '<_> -> exit 3' -TestCases @('missing.json', 'page.html', 'trunc.json', 'report.json', 'array.json', 'other.json', 'noversion.json', 'incomplete.json', 'old.json', 'newer.json', 'emptydir', 'nomatch*.json') {
        $arg = Join-Path $script:Bad $_
        $rp = Invoke-PcrTool ps-report @('-Merge', $arg)
        $rp.ExitCode | Should -Be 3
        $rp.Stderr | Should -Match '\[ERROR\]'
        if ($script:HasBash) {
            $rb = Invoke-PcrTool bash-report @('--merge', $arg)
            $rb.ExitCode | Should -Be 3
            $eb = ($rb.Stderr -split "`n" | Where-Object { $_ -match '\[ERROR\]' }) -replace '^[0-9: -]+', '' -replace 're-run v[0-9.]+ ', 're-run vX '
            $ep = ($rp.Stderr -split "`n" | Where-Object { $_ -match '\[ERROR\]' }) -replace '^[0-9: -]+', ''
            (& $script:ToBash ($ep -join "`n")) | Should -BeExactly ($eb -join "`n")
        }
    }
}

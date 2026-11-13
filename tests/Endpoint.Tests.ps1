# tests/Endpoint.Tests.ps1 - the REAL AWS SDK (AWS.Tools) and, when available, the REAL AWS CLI v2 against a
# local fake of the RDS / STS / EC2 query API (XML over HTTP) that pages every list with Marker.
# The fake endpoint is the Bash repo's tests/fake_rds_endpoint.py (so RDS_PCR_BASH_DIR is needed); it gives:
#   us-east-1 = 30 Aurora PostgreSQL clusters + 200 PostgreSQL instances (pages of 20), us-west-2 = one
#   headless cluster, eu-west-1 = DescribeDBInstances AccessDenied (SCP), ap-south-1 / ca-central-1 = empty.
# The expectations are the ones the Bash repo's validate_cli.sh checks for the Bash tool + real CLI.
# RDS_PCR_REAL_AWS = path of a real `aws` v2 binary enables the three-way comparison (Bash+CLI, PS+CLI, PS+SDK).

BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:Skip = -not (Get-BashDir) -or -not (Get-Module -ListAvailable AWS.Tools.RDS) -or -not (Get-Command python3 -ErrorAction SilentlyContinue)
    $script:NoRealCli = -not ($env:RDS_PCR_REAL_AWS -and (Test-Path $env:RDS_PCR_REAL_AWS))
}

Describe 'Real AWS SDK against a paging fake endpoint' -Skip:$script:Skip {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
        $script:Root = Get-PcrTestRoot
        $script:Fake = Join-Path (Get-BashDir) 'tests/fake_rds_endpoint.py'
        # Start-Fake: start the endpoint with a fresh request log; returns @{ Proc; Port; Log }
        function Start-Fake {
            $d = New-PcrTestDir 'fake'
            $p = Start-Process python3 -ArgumentList @($script:Fake, "$d/port", "$d/req.jsonl") -PassThru
            for ($i = 0; $i -lt 50 -and -not ((Test-Path "$d/port") -and (Get-Content -Raw "$d/port")); $i++) { Start-Sleep -Milliseconds 100 }
            return @{ Proc = $p; Port = (Get-Content -Raw "$d/port").Trim(); Log = "$d/req.jsonl"; Dir = $d }
        }
        # Get-Requests: the endpoint's request log as objects
        function Get-Requests { param($F) @(Get-Content $F.Log | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) }
        # Invoke-Pcr: run the PS report in a child pwsh against the fake endpoint (AwsTools back end unless -Cli)
        function Invoke-Pcr {
            param($F, [string[]]$A, [string]$Backend = 'AwsTools', [string]$Path = $env:PATH)
            $env:AWS_ENDPOINT_URL = "http://127.0.0.1:$($F.Port)"
            $old = $env:PATH; $env:PATH = $Path
            try {
                $out = & pwsh -NoProfile -NonInteractive -File (Join-Path $script:Root 'Invoke-RdsPatchCompliance.ps1') -AwsBackend $Backend @A 2>"$($F.Dir)/err.txt"
                return @{ Rc = $LASTEXITCODE; Out = ($out -join "`n"); Err = (Get-Content -Raw "$($F.Dir)/err.txt") }
            }
            finally { $env:PATH = $old }
        }
        $env:AWS_ACCESS_KEY_ID = 'fake'; $env:AWS_SECRET_ACCESS_KEY = 'fake'
        Remove-Item env:AWS_SESSION_TOKEN, env:AWS_PROFILE, env:AWS_REGION, env:AWS_DEFAULT_REGION -ErrorAction SilentlyContinue
        $env:AWS_CONFIG_FILE = '/dev/null'; $env:AWS_SHARED_CREDENTIALS_FILE = '/dev/null'; $env:AWS_EC2_METADATA_DISABLED = 'true'
        $env:RDS_PCR_NOW = '1793700000'
    }
    AfterEach { if ($script:F) { Stop-Process -Id $script:F.Proc.Id -ErrorAction SilentlyContinue } }

    It 'follows every Marker page and reads all 230 servers' {
        $script:F = Start-Fake
        $r = Invoke-Pcr $script:F @('-Region', 'us-east-1', '-Format', 'json')
        $r.Rc | Should -Be 0
        $j = $r.Out | ConvertFrom-Json -AsHashtable
        $j.summary.total | Should -Be 230
        $j.summary.errors | Should -Be 0
        $j.summary.with_pending | Should -Be 50
        $pg = @($j.rows | Where-Object engine -EQ 'postgres')
        $pg.Count | Should -Be 200
        @($pg | Where-Object { $_.versions_behind -ne 5 -or $_.latest_minor_version -ne '16.11' -or $_.compliance_status -ne 'NON-COMPLIANT' }).Count | Should -Be 0
        $pg[0].default_auto_upgrade_target | Should -Be '16.11'
        @($pg | Where-Object { $_.tags.Environment -ne 'prod & test' }).Count | Should -Be 0
        $ap = @($j.rows | Where-Object engine -EQ 'aurora-postgresql')
        $ap.Count | Should -Be 30
        @($ap | Where-Object { $_.versions_behind -ne 1 -or $_.members -ne "$($_.identifier)-1 (writer)" -or $_.standard_support_end -ne '2029-02-28' }).Count | Should -Be 0
        # the same request counts as the Bash tool + real CLI (validate_cli.sh)
        $req = Get-Requests $script:F
        $count = { param($a) @($req | Where-Object action -EQ $a).Count }
        & $count 'DescribeDBInstances' | Should -Be 12
        & $count 'DescribeDBClusters' | Should -Be 2
        & $count 'DescribePendingMaintenanceActions' | Should -Be 3
        & $count 'DescribeDBEngineVersions' | Should -Be 2
        & $count 'DescribeDBMajorEngineVersions' | Should -Be 6
    }
    It '-AllRegions: one request per probe, AccessDenied region = error and still scanned, empty regions skipped' {
        $script:F = Start-Fake
        $env:AWS_REGION = 'us-east-1'
        try { $r = Invoke-Pcr $script:F @('-AllRegions', '-ProbeParallel', '3', '-Format', 'json') } finally { Remove-Item env:AWS_REGION }
        $r.Rc | Should -Be 0
        $j = $r.Out | ConvertFrom-Json -AsHashtable
        $o = $j.summary.region_overview
        @($o.checked, $o.with_databases, $o.empty, $o.error) | Should -Be @(5, 2, 2, 1)
        $by = @{}; foreach ($x in $j.summary.regions) { $by[$x.region] = "$($x.status)|$($x.probe_instances)|$($x.probe_clusters)|$($x.total)" }
        $by['us-east-1'] | Should -Be 'databases|20|20|230'
        $by['us-west-2'] | Should -Be 'databases|0|1|1'
        $by['eu-west-1'] | Should -Be 'error||0|0'
        $by['ap-south-1'] | Should -Be 'empty|0|0|0'
        $j.summary.total | Should -Be 231
        @($j.errors | Where-Object { $_.region -eq 'eu-west-1' -and $_.call -eq 'rds describe-db-instances (discovery probe)' -and $_.message -match 'AccessDenied' }).Count | Should -Be 1
        $req = Get-Requests $script:F
        $probes = @($req | Where-Object { $_.max_records -eq '20' })
        @($probes | Where-Object action -EQ 'DescribeDBInstances').Count | Should -Be 5
        @($probes | Where-Object { $null -ne $_.marker }).Count | Should -Be 0
        @($probes | ForEach-Object region | Sort-Object -Unique) | Should -Be @('ap-south-1', 'ca-central-1', 'eu-west-1', 'us-east-1', 'us-west-2')
        @($req | Where-Object { $null -eq $_.max_records -and $_.action -in 'DescribeDBInstances', 'DescribeDBClusters' } | ForEach-Object region | Sort-Object -Unique) | Should -Be @('eu-west-1', 'us-east-1', 'us-west-2')
    }
    It 'three-way: Bash + real CLI == PS + real CLI == PS + AWS.Tools (same report)' -Skip:$script:NoRealCli {
        $script:F = Start-Fake
        $wrap = New-PcrTestDir 'realbin'
        $real = $env:RDS_PCR_REAL_AWS
        Set-Content "$wrap/aws" @('#!/usr/bin/env bash', ('case " $* " in *" configure "*|*" --version "*) exec "' + $real + '" "$@" ;; esac'), ('exec "' + $real + '" "$@" --endpoint-url "http://127.0.0.1:' + $script:F.Port + '"'))
        chmod +x "$wrap/aws"
        $path = $wrap + [System.IO.Path]::PathSeparator + $env:PATH
        $env:AWS_REGION = 'us-east-1'; Remove-Item env:AWS_ENDPOINT_URL -ErrorAction SilentlyContinue
        try {
            $old = $env:PATH; $env:PATH = $path
            try { $b = & bash (Join-Path (Get-BashDir) 'rds_patch_compliance_report.sh') -A --probe-parallel 3 -F json 2>"$($script:F.Dir)/berr.txt"; $brc = $LASTEXITCODE } finally { $env:PATH = $old }
            if ($brc -ne 0) { Write-Host (Get-Content -Raw "$($script:F.Dir)/berr.txt") }
            $pc = Invoke-Pcr $script:F @('-AllRegions', '-ProbeParallel', '3', '-Format', 'json') -Backend Cli -Path $path
            $pt = Invoke-Pcr $script:F @('-AllRegions', '-ProbeParallel', '3', '-Format', 'json')
        }
        finally { Remove-Item env:AWS_REGION }
        $brc | Should -Be 0
        $pc.Rc | Should -Be 0
        $pt.Rc | Should -Be 0
        $norm = { param($t) $f = New-TemporaryFile; Set-Content $f $t; $n = Get-NormalizedJson $f.FullName @('.meta.script', '.meta.version', '.meta.host'); Remove-Item $f; $n }
        (& $norm $pc.Out) | Should -BeExactly (& $norm ($b -join "`n"))
        # the SDK back end: same rows and summary; the only allowed difference is the global-clusters error text
        # (the fake answers DescribeGlobalClusters with an empty HTTP 400: the CLI says "Unable to parse response ...",
        #  the SDK "An error occurred (400) ... Bad Request"; both are reported the same way)
        $strip = { param($t) $j = $t | ConvertFrom-Json -AsHashtable; $j.meta.Remove('script'); $j.meta.Remove('version'); $j.meta.Remove('host')
            ($j | ConvertTo-Json -Depth 50) -replace '"(Unable to parse response|An error occurred \(400\))[^"]*"', '"GLOBAL-LOOKUP-ERROR"' }
        (& $strip $pt.Out) | Should -BeExactly (& $strip $pc.Out)
    }
}

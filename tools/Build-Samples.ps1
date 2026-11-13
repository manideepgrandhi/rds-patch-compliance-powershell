#Requires -Version 7.2
<#
.SYNOPSIS
Regenerate samples/ from the test mock (no AWS account, no network, fake account numbers).

.DESCRIPTION
Runs both scripts through the shared mock AWS CLI (tests/mock/aws) with fake credentials and a frozen
clock (RDS_PCR_NOW = 2026-11-03 10:00 UTC), the same set-up the Pester tests use, and writes:
  samples/sample_report.*            full report, prod + nonprod, all regions (text, csv, regions csv, json, html)
  samples/sample_summary*            manager summary of the same scan (txt, html, csvs)
  samples/data/*.json                -SaveData files (prod saved by this port, nonprod saved by the Bash tool)
  samples/sample_merged.*            -Merge of the two data files (text, csv, regions csv, html)
  samples/sample_summary_merged.*    summary -Merge of the same files
Needs python3 and bash (for the mock). The Bash tool (for the nonprod data file) is taken from
-BashDir or $env:RDS_PCR_BASH_DIR; without it the nonprod file is saved by this port too.

.EXAMPLE
pwsh ./tools/Build-Samples.ps1 -BashDir ../rds-patch-compliance
#>
[CmdletBinding()]
param([string]$BashDir = $env:RDS_PCR_BASH_DIR)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'tests/TestHelpers.psm1') -Force
Set-PcrTestEnv
$env:RDS_PCR_BASH_DIR = $BashDir
$samples = Join-Path $root 'samples'
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('pcr-samples-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $work, (Join-Path $samples 'data') -Force | Out-Null
Get-ChildItem -LiteralPath $samples -File -Filter 'sample_*' | Where-Object Extension -NE '.png' | Remove-Item -Force
Get-ChildItem -LiteralPath (Join-Path $samples 'data') -File | Remove-Item -Force

# Run one tool and stop on an unexpected exit code
function Invoke-Step([string]$Tool, [string[]]$Arguments, [int[]]$Ok = @(0)) {
    $r = Invoke-PcrTool -Tool $Tool -Arguments $Arguments -WorkingDirectory $work
    if ($Ok -notcontains $r.ExitCode) { throw "$Tool $($Arguments -join ' ') -> exit $($r.ExitCode)`n$($r.Stderr)" }
    return $r
}
# Move the stamped files of one run to samples/<base><suffix>
function Move-Output([string]$Dir, [string]$Base) {
    foreach ($f in Get-ChildItem -LiteralPath $Dir -File) {
        $suffix = [regex]::Replace($f.Name, '^.*_[0-9]{8}_[0-9]{6}', '')
        Move-Item -LiteralPath $f.FullName -Destination (Join-Path $samples ($Base + $suffix)) -Force
    }
}

$d = Join-Path $work 'report'
$null = Invoke-Step ps-report @('-ProfileName', 'prod,nonprod', '-AllRegions', '-Format', 'text,csv,json,html', '-OutputDir', $d)
Move-Output $d 'sample_report'

$d = Join-Path $work 'summary'
$null = Invoke-Step ps-summary @('-ProfileName', 'prod,nonprod', '-AllRegions', '-Format', 'txt,html,csv', '-OutputDir', $d)
Move-Output $d 'sample_summary'

$data = Join-Path $work 'data'
$null = Invoke-Step ps-report @('-ProfileName', 'prod', '-AllRegions', '-Format', 'csv', '-OutputDir', $data, '-SaveData')
if (Get-BashDir) { $null = Invoke-Step bash-report @('-P', 'nonprod', '-A', '-F', 'csv', '-o', $data, '--save-data') }
else { $null = Invoke-Step ps-report @('-ProfileName', 'nonprod', '-AllRegions', '-Format', 'csv', '-OutputDir', $data, '-SaveData') }
Get-ChildItem -LiteralPath $data -File | Where-Object Name -Match '^rds_patch_[0-9]{12}_[0-9]{8}\.json$' | Move-Item -Destination (Join-Path $samples 'data') -Force

$d = Join-Path $work 'merged'
$null = Invoke-Step ps-report @('-Merge', (Join-Path $samples 'data'), '-Format', 'text,csv,html', '-OutputDir', $d)
Move-Output $d 'sample_merged'

$d = Join-Path $work 'summary-merged'
$null = Invoke-Step ps-summary @('-Merge', (Join-Path $samples 'data'), '-Format', 'txt,html,csv', '-OutputDir', $d)
Move-Output $d 'sample_summary_merged'

# the JSON names the machine that ran it; samples use a neutral host name
$json = Join-Path $samples 'sample_report.json'
$text = [System.IO.File]::ReadAllText($json)
[System.IO.File]::WriteAllText($json, [regex]::Replace($text, '"host": "[^"]*"', '"host": "jumpbox01"'))

Remove-Item -LiteralPath $work -Recurse -Force
Get-ChildItem -LiteralPath $samples -Recurse -File | Sort-Object FullName | ForEach-Object { $_.FullName.Substring($root.Length + 1) }

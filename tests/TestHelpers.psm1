# tests/TestHelpers.psm1 - shared plumbing for the Pester tests.
#   * every run goes through the shared mock AWS CLI (tests/mock/aws, Python 3) with fake credentials,
#     no network (AWS_ENDPOINT_URL points at a closed port) and a frozen clock (RDS_PCR_NOW)
#   * the Bash tool is only used when RDS_PCR_BASH_DIR points at a clone of rds-patch-compliance
#     (the parity / cross-merge tests are skipped otherwise)
#   * outputs are compared after removing what may legitimately differ (script name / version / host)

$script:Root = Split-Path -Parent $PSScriptRoot
$script:MockDir = Join-Path $PSScriptRoot 'mock'
$script:Now = 1793700000   # 2026-11-03 10:00 UTC

# Get-PcrTestRoot: the repo root
function Get-PcrTestRoot { return $script:Root }

# Get-BashDir: the Bash clone used for parity tests, or $null
function Get-BashDir {
    $d = $env:RDS_PCR_BASH_DIR
    if ($d -and (Test-Path -LiteralPath (Join-Path $d 'rds_patch_compliance_report.sh')) -and (Get-Command bash -ErrorAction SilentlyContinue) -and (Get-Command jq -ErrorAction SilentlyContinue)) { return $d }
    return $null
}

# Test-MockUsable: python3 + bash are needed to run the mock CLI
function Test-MockUsable { return [bool]((Get-Command python3 -ErrorAction SilentlyContinue) -and (Get-Command bash -ErrorAction SilentlyContinue)) }

# Set-PcrTestEnv: process environment for every child run (inherited by bash / pwsh children)
function Set-PcrTestEnv {
    $sep = [System.IO.Path]::PathSeparator
    if (-not ($env:PATH -split [regex]::Escape($sep) -contains $script:MockDir)) { $env:PATH = $script:MockDir + $sep + $env:PATH }
    foreach ($v in 'AWS_REGION', 'AWS_DEFAULT_REGION', 'AWS_PROFILE', 'MOCK_DEFAULT_REGION', 'MOCK_SCENARIO', 'MOCK_LARGE_N', 'MOCK_PROBE_DELAY') { Remove-Item "env:$v" -ErrorAction SilentlyContinue }
    $env:AWS_ACCESS_KEY_ID = 'fake'; $env:AWS_SECRET_ACCESS_KEY = 'fake'; $env:AWS_SESSION_TOKEN = 'fake'
    $env:AWS_CONFIG_FILE = '/dev/null'; $env:AWS_SHARED_CREDENTIALS_FILE = '/dev/null'
    $env:AWS_EC2_METADATA_DISABLED = 'true'; $env:AWS_ENDPOINT_URL = 'http://127.0.0.1:9'
    $env:RDS_PCR_NOW = [string]$script:Now
}

# ConvertTo-ShArg: one bash single-quoted word
function ConvertTo-ShArg { param([string]$S) return "'" + $S.Replace("'", "'\''") + "'" }

# Invoke-PcrTool: run one tool in a child process.
#   -Tool    bash-report | bash-summary | ps-report | ps-summary | ps-report-tools (AwsTools back end + SDK shim)
#   -Args    argument list (strings), -Scenario mock scenario, -Env extra environment
#   Returns @{ ExitCode; Stdout; Stderr }
function Invoke-PcrTool {
    param([Parameter(Mandatory)][string]$Tool, [string[]]$Arguments = @(), [string]$Scenario = 'fleet', [hashtable]$Env = @{}, [string]$WorkingDirectory = (Get-Location).Path)
    $pre = @("MOCK_SCENARIO=$(ConvertTo-ShArg $Scenario)") + @(foreach ($k in $Env.Keys) { "$k=$(ConvertTo-ShArg ([string]$Env[$k]))" })
    $argText = ($Arguments | ForEach-Object { ConvertTo-ShArg $_ }) -join ' '
    $bash = Get-BashDir
    $cmd = switch ($Tool) {
        'bash-report' { "$(ConvertTo-ShArg (Join-Path $bash 'rds_patch_compliance_report.sh')) $argText" }
        'bash-summary' { "$(ConvertTo-ShArg (Join-Path $bash 'rds_patch_compliance_summary.sh')) $argText" }
        'ps-report' { "pwsh -NoProfile -NonInteractive -File $(ConvertTo-ShArg (Join-Path $script:Root 'Invoke-RdsPatchCompliance.ps1')) -AwsBackend Cli $argText" }
        'ps-summary' { "pwsh -NoProfile -NonInteractive -File $(ConvertTo-ShArg (Join-Path $script:Root 'Invoke-RdsPatchComplianceSummary.ps1')) -AwsBackend Cli $argText" }
        'ps-report-tools' {
            $inner = ". $(ConvertTo-ShArg (Join-Path $script:MockDir 'AwsToolsShim.ps1')); & $(ConvertTo-ShArg (Join-Path $script:Root 'Invoke-RdsPatchCompliance.ps1')) -AwsBackend AwsTools $(($Arguments | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ' '); exit `$LASTEXITCODE"
            "pwsh -NoProfile -NonInteractive -Command $(ConvertTo-ShArg $inner)"
        }
        default { throw "unknown tool $Tool" }
    }
    $outF = [System.IO.Path]::GetTempFileName(); $errF = [System.IO.Path]::GetTempFileName()
    try {
        $full = "cd $(ConvertTo-ShArg $WorkingDirectory) && env $($pre -join ' ') $cmd >$(ConvertTo-ShArg $outF) 2>$(ConvertTo-ShArg $errF)"
        & bash -c $full
        $rc = $LASTEXITCODE
        return @{ ExitCode = $rc; Stdout = [System.IO.File]::ReadAllText($outF); Stderr = [System.IO.File]::ReadAllText($errF) }
    }
    finally { Remove-Item -LiteralPath $outF, $errF -Force -ErrorAction SilentlyContinue }
}

# Get-NormalizedJson: canonical JSON (keys sorted, via jq -S) with the given jq paths deleted
function Get-NormalizedJson {
    param([string]$Path, [string[]]$Delete = @('.meta.script', '.meta.version', '.meta.host'))
    $filter = if ($Delete.Count) { 'del(' + ($Delete -join ',') + ')' } else { '.' }
    $t = & jq -S $filter $Path 2>$null
    if ($LASTEXITCODE -ne 0) { return [System.IO.File]::ReadAllText($Path) }
    return ($t -join "`n")
}
# Get-NormalizedText: file text with the footer / version stamps that name the tool removed
function Get-NormalizedText {
    param([string]$Path)
    $t = [System.IO.File]::ReadAllText($Path)
    $t = [regex]::Replace($t, '<footer>[^<]*</footer>', '')
    $t = [regex]::Replace($t, 'full per-server details: .*', 'full per-server details: X')
    $t = [regex]::Replace($t, '<td>v[0-9.]+</td>', '<td>vX</td>')
    $t = [regex]::Replace($t, '>v[0-9.]+<', '>vX<')
    return $t
}
# Compare-PcrOutputDir: compare every file of directory A with the same-named (or same-suffix) file in B.
#   Returns a list of problems (empty = identical after normalisation)
function Compare-PcrOutputDir {
    param([string]$A, [string]$B, [string[]]$JsonDelete = @('.meta.script', '.meta.version', '.meta.host'), [switch]$BySuffix)
    $problems = [System.Collections.Generic.List[string]]::new()
    $fa = @(Get-ChildItem -LiteralPath $A -File | Sort-Object Name)
    $fb = @(Get-ChildItem -LiteralPath $B -File | Sort-Object Name)
    if ($fa.Count -eq 0) { $problems.Add("no files in $A") }
    foreach ($f in $fa) {
        $other = if ($BySuffix) {
            $suf = [regex]::Replace($f.Name, '^.*_[0-9]{8}_[0-9]{6}', '')
            $fb | Where-Object { $_.Name -match ('_[0-9]{8}_[0-9]{6}' + [regex]::Escape($suf) + '$') } | Select-Object -First 1
        }
        else { $fb | Where-Object Name -EQ $f.Name | Select-Object -First 1 }
        if (-not $other) { $problems.Add("missing in B: $($f.Name)"); continue }
        $same = if ($f.Extension -eq '.json') { (Get-NormalizedJson $f.FullName $JsonDelete) -ceq (Get-NormalizedJson $other.FullName $JsonDelete) }
        else { (Get-NormalizedText $f.FullName) -ceq (Get-NormalizedText $other.FullName) }
        if (-not $same) { $problems.Add("differs: $($f.Name)") }
    }
    if ($fb.Count -ne $fa.Count) { $problems.Add("file count A=$($fa.Count) B=$($fb.Count)") }
    return , $problems.ToArray()
}
# Get-LogBody: stderr log lines without the timestamp, with the run directory replaced
function Get-LogBody {
    param([string]$Text, [string]$Dir, [string]$Replace = 'OUT')
    $lines = foreach ($l in ($Text -split "`n")) { if ($l -ne '') { ([regex]::Replace($l, '^[0-9: -]+', '')).Replace($Dir, $Replace) } }
    return ($lines -join "`n")
}
# New-PcrTestDir: a fresh empty directory under the Pester TestDrive (or temp)
function New-PcrTestDir {
    param([string]$Name)
    $base = if (Test-Path 'TestDrive:\') { (Get-PSDrive TestDrive).Root } else { [System.IO.Path]::GetTempPath() }
    $d = Join-Path $base ($Name + '_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}

Export-ModuleMember -Function *

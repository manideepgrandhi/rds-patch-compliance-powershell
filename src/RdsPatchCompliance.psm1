# src/RdsPatchCompliance.psm1 - loads the parts of the port in dependency order and the HTML assets.
# Everything is module-private except the two entry functions; the .ps1 scripts in the repo root are thin wrappers.
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

foreach ($part in 'Json', 'Versions', 'Options', 'Time', 'Compliance', 'Aws', 'Collect', 'Render', 'Output', 'Data', 'Alerts', 'Summary', 'Main', 'SummaryMain') {
    . (Join-Path $PSScriptRoot "$part.ps1")
}

# HTML assets (same CSS / JS as the Bash report, so the page looks and behaves the same; all inline = works offline)
$script:AssetDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets'
$script:PagePath = Join-Path $script:AssetDir 'compliance_page.js'
$script:Assets = @{
    Css    = [System.IO.File]::ReadAllText((Join-Path $script:AssetDir 'report.css'))
    SortJs = [System.IO.File]::ReadAllText((Join-Path $script:AssetDir 'report_sort.js'))
    PageJs = [System.IO.File]::ReadAllText($script:PagePath)
}

Export-ModuleMember -Function Invoke-RdsPatchCompliance, Invoke-RdsPatchComplianceSummary

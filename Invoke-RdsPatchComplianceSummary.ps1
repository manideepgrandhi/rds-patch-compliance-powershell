#Requires -Version 7.2
<#
.SYNOPSIS
High-level RDS patch compliance summary and the NON-COMPLIANT servers only (read-only).

.DESCRIPTION
PowerShell 7 port of rds_patch_compliance_summary.sh v1.3.0. The scan / merge is done by Invoke-RdsPatchCompliance
(same module), so the numbers are identical to the full report. Formats: txt (screen), html, csv
(_summary.csv, _noncompliant.csv, _accounts.csv, _regions.csv). Run with -Help for the option list.

.EXAMPLE
./Invoke-RdsPatchComplianceSummary.ps1 -ProfileName prod -AllRegions

.EXAMPLE
./Invoke-RdsPatchComplianceSummary.ps1 -Merge ./data -Format txt,html,csv -OutputDir ./out
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Alias('Profile', 'P')][string[]]$ProfileName, [Alias('r')][string[]]$Region, [Alias('A')][switch]$AllRegions, [switch]$NoDiscover, [string]$ProbeParallel,
    [Alias('e')][string[]]$Engine, [Alias('i')][string[]]$Identifier, [string]$MaxBehind, [string]$WarnDays,
    [switch]$SaveData, [string]$SaveDataFile, [string[]]$Merge, [switch]$OracleAnyPatchLine,
    [Alias('F')][string[]]$Format, [Alias('o')][string]$OutputDir, [string]$Prefix, [switch]$FailOnNonCompliant,
    [string[]]$AlertEmail, [string[]]$AlertWebhook, [string]$AlertWebhookFormat, [string]$AlertOn, [string]$AlertFrom,
    [string]$AlertSmtpServer, [int]$AlertSmtpPort, [ValidateSet('AwsTools', 'Cli')][string]$AwsBackend,
    [Alias('h')][switch]$Help, [Alias('V')][switch]$Version,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$MoreArgs
)
# Thin wrapper: load the module next to this script and exit with the run's exit code
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src/RdsPatchCompliance.psm1') -Force -Verbose:$false
$result = Invoke-RdsPatchComplianceSummary @PSBoundParameters
exit ([int]@($result)[-1])

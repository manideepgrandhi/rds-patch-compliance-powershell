#Requires -Version 7.2
<#
.SYNOPSIS
Minor-version patch compliance report for Aurora / RDS / Multi-AZ DB cluster / DocumentDB / Neptune (read-only).

.DESCRIPTION
PowerShell 7 port of rds_patch_compliance_report.sh v1.5.1. Same rule, statuses, CSV columns, JSON, HTML page
and -SaveData file format (files merge in both directions with the Bash tool).
Rule: versions_behind = number of valid MINOR upgrade targets RDS returns for the current version
(ValidUpgradeTarget with IsMajorVersionUpgrade = false; Oracle: same patch line). COMPLIANT if <= -MaxBehind
(default 2), NON-COMPLIANT otherwise, UNKNOWN if the lookup failed or the version is deprecated.
Only describe / list / get calls are made. Run with -Help for the option list.

.EXAMPLE
./Invoke-RdsPatchCompliance.ps1 -ProfileName prod -Region us-east-1,ap-south-1 -Format text

.EXAMPLE
./Invoke-RdsPatchCompliance.ps1 -ProfileName prod,nonprod -AllRegions -Format csv,html -OutputDir ./out -SaveData

.EXAMPLE
./Invoke-RdsPatchCompliance.ps1 -Merge ./data/rds_patch_111111111111_20261103.json ./data/rds_patch_222222222222_20261103.json -OutputDir ./out/all.html

.NOTES
Exit codes: 0 ok, 1 usage, 2 pre-check, 3 bad -Merge input, 4 output error, 5 NON-COMPLIANT with -FailOnNonCompliant.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Alias('Profile', 'P')][string[]]$ProfileName, [Alias('r')][string[]]$Region, [Alias('A')][switch]$AllRegions, [switch]$NoDiscover, [switch]$Discover,
    [string]$ProbeParallel, [Alias('e')][string[]]$Engine, [Alias('i')][string[]]$Identifier, [Alias('T')][string]$TagColumns,
    [Alias('F')][string[]]$Format, [Alias('o')][string]$OutputDir, [string]$Prefix, [Alias('TimeZone')][string]$Tz,
    [switch]$SaveData, [string]$SaveDataFile, [string[]]$Merge,
    [string]$MaxBehind, [string]$WarnDays, [string]$Top, [switch]$NonCompliantOnly, [switch]$OracleAnyPatchLine, [switch]$FailOnNonCompliant,
    [Alias('l')][string]$LogFile, [Alias('Config')][string]$ConfigFile, [string]$AwsTimeout, [string]$MaxAttempts, [switch]$KeepWorkdir, [switch]$DryRun,
    [string[]]$AlertEmail, [string[]]$AlertWebhook, [string]$AlertWebhookFormat, [string]$AlertOn, [string]$AlertFrom, [switch]$AlertTest,
    [string]$AlertSmtpServer, [int]$AlertSmtpPort, [ValidateSet('AwsTools', 'Cli')][string]$AwsBackend,
    [Alias('h')][switch]$Help, [Alias('V')][switch]$Version,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$MoreArgs
)
# Thin wrapper: load the module next to this script and exit with the run's exit code
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src/RdsPatchCompliance.psm1') -Force -Verbose:$false
$result = Invoke-RdsPatchCompliance @PSBoundParameters
exit ([int]@($result)[-1])

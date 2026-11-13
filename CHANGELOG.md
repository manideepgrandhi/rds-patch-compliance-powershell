# Changelog

Plain-English features for each release of the PowerShell port. The format follows the Bash tool's
[CHANGELOG.md](https://github.com/manideepgrandhi/rds-patch-compliance/blob/main/CHANGELOG.md).

## 1.0.0

_Not released yet. This version is on the `feature/powershell-port` branch in draft PR #1, and no tag or
release has been made._

First version: a PowerShell 7 port of `rds_patch_compliance_report.sh` v1.5.1 and
`rds_patch_compliance_summary.sh` 1.3.0 (Bash repo `main` 5311723).

- `Invoke-RdsPatchCompliance.ps1` writes a read-only minor-version patch compliance report covering
  Aurora, RDS, Multi-AZ DB clusters, DocumentDB and Neptune, across accounts and regions
- Same rule as Bash: versions behind = valid minor upgrade targets from RDS (Oracle: same patch line;
  `-OracleAnyPatchLine` counts other patch lines too). COMPLIANT / NON-COMPLIANT / UNKNOWN, with
  `-MaxBehind` and `-WarnDays`
- Text, CSV (28 columns), regions CSV, JSON and an offline single-file HTML page. For the same data, the
  CSV, regions CSV and text are byte-for-byte the same as Bash. The HTML differs only in the footer
- Shows lifecycle and Extended Support dates, pending maintenance (with member actions), auto minor
  upgrade, deprecated versions, Aurora global databases, and account names (config file, then IAM alias)
- `-AllRegions` with a parallel discovery probe (`-ProbeParallel`, run with `ForEach-Object -Parallel`),
  `-NoDiscover`, and `-Engine` / `-Identifier` filters
- `-SaveData` / `-SaveDataFile` write the same data file as Bash. `-Merge` builds one report offline,
  and **files saved by either tool merge in either tool**
- `Invoke-RdsPatchComplianceSummary.ps1` gives a manager summary (txt, html and 4 CSVs) with the same
  numbers as the full report, including `-Merge`
- E-mail alerts through `mail`/`mailx`/`sendmail`, or an SMTP relay with `-AlertSmtpServer` for
  Windows. Slack and JSON webhooks, `-AlertOn`, `-AlertTest`
- `-ConfigFile` reads the same `key = value` file as Bash (one file for both tools). Credentials are
  refused
- `-FailOnNonCompliant` exits with code 5. `-LogFile`, `-DryRun`, `-KeepWorkdir`, `-Verbose`,
  `-AwsTimeout` and `-MaxAttempts` work as in Bash. Exit codes are the same: 0, 1, 2, 3, 4, 5
- Two AWS back ends: AWS.Tools modules (the default, all calls in one process) or the AWS CLI v2
  (`-AwsBackend Cli`). No jq, bash or curl needed, and it runs natively on Windows
- Can also be used as a module: `Import-Module ./src/RdsPatchCompliance.psm1`, then call
  `Invoke-RdsPatchCompliance`, which returns the exit code
- Pester 5 test suite (115 tests): side-by-side parity with the Bash tool, cross-merges in all four
  directions, the real AWS SDK and CLI against a paging fake endpoint, the HTML page offline in headless
  Chrome, and PSScriptAnalyzer. CI runs it on every push
- Not ported yet: exceptions (open draft PR in the Bash repo)

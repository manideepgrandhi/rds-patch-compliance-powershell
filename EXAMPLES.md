# Invoke-RdsPatchCompliance.ps1: examples

Every example is read-only and can be copied and pasted. Run them from the repo folder in `pwsh` 7.2 or
later. On Windows, use `.\` instead of `./`. The numbers follow the Bash tool's
[EXAMPLES.md](https://github.com/manideepgrandhi/rds-patch-compliance/blob/main/EXAMPLES.md), so you can
compare the two side by side.

**About the output shown here:**

- Paths in the output are shortened to the relative paths used in the commands. Webhook hosts are shown as
  the URL in the command; the real runs posted to a local test receiver.

- Every output block comes from a real run against the test mock (`tests/mock/aws`), with fake accounts
  (111111111111 prod, 222222222222 nonprod, 333333333333 dev) and the clock frozen at
  2026-11-03 10:00 UTC. Your numbers will differ.
- Log lines (`[INFO]`, `[WARN]`) go to stderr. Their timestamps are the real run time.
- `...` marks lines left out. In AWS CloudShell, add `-AwsBackend Cli` if AWS.Tools is not installed.

- [Report](#report)
- [Use the JSON / CSV from PowerShell](#use-the-json--csv-from-powershell)
- [Several accounts: save in each account, merge anywhere](#several-accounts-save-in-each-account-merge-anywhere)
- [Merge files saved by the Bash tool](#merge-files-saved-by-the-bash-tool)
- [Summary script](#summary-script)
- [Alerts](#alerts)
- [Config file](#config-file)
- [Scheduling](#scheduling) (Windows Task Scheduler, cron, CI)
- [Where to run it](#where-to-run-it) (jump box profiles, CloudShell)

## Report

```powershell
# 1. Quick look: default profile, default region, text on the screen
./Invoke-RdsPatchCompliance.ps1

# 2. Two accounts, two regions, every format into ./compliance
./Invoke-RdsPatchCompliance.ps1 -ProfileName prod,nonprod -Region us-east-1,ap-south-1 -Format csv,html,txt,json -OutputDir ./compliance
```

```
[INFO] Profile prod: account 111111111111 (arn:aws:iam::111111111111:user/dba)
[INFO] [prod/us-east-1] 11 cluster(s), 29 instance(s), 4 resource(s) with pending maintenance
[WARN] [prod/us-east-1] aurora-postgresql 11.9 is not returned by describe-db-engine-versions (deprecated / not offered here); its servers are UNKNOWN
[INFO] [prod/us-east-1] COMPLIANT=11 NON-COMPLIANT=7 UNKNOWN=1
...
[INFO] [nonprod/ap-south-1] COMPLIANT=2 NON-COMPLIANT=1
[INFO] Wrote ./compliance/rds_patch_compliance_20261103_153000.csv
[INFO] Wrote ./compliance/rds_patch_compliance_20261103_153000_regions.csv
[INFO] Wrote ./compliance/rds_patch_compliance_20261103_153000.html
[INFO] Wrote ./compliance/rds_patch_compliance_20261103_153000.txt
[INFO] Wrote ./compliance/rds_patch_compliance_20261103_153000.json
[INFO] Result: 22 server(s)/cluster(s): COMPLIANT 13, NON-COMPLIANT 8, UNKNOWN 1 (59.1% compliant); 0 error(s); 48 AWS call(s); exit 0
```

```powershell
# 3. Whole estate of one account, every enabled region, HTML only.
#    Regions are probed first; only regions with databases are scanned in full.
#    One account, so the file name carries the account number.
./Invoke-RdsPatchCompliance.ps1 -ProfileName prod -AllRegions -Format html -OutputDir ./compliance
```

```
[INFO] Profile prod: account 111111111111 (arn:aws:iam::111111111111:user/dba)
[INFO] [prod] discovery: probing 3 region(s), 8 at a time
...
[INFO] Wrote ./compliance/rds_patch_compliance_111111111111_20261103_153000.html
[INFO] Result: 19 server(s)/cluster(s): COMPLIANT 11, NON-COMPLIANT 7, UNKNOWN 1 (57.9% compliant); 0 error(s); 37 AWS call(s); exit 0
```

```powershell
# 3a. Probe 16 regions at a time (csv also writes *_regions.csv); or skip the probe and scan every region in full
./Invoke-RdsPatchCompliance.ps1 -ProfileName prod,nonprod -AllRegions -ProbeParallel 16 -Format html,csv -OutputDir ./compliance
./Invoke-RdsPatchCompliance.ps1 -ProfileName prod -AllRegions -NoDiscover

# 3b. Show the AWS calls without making them (-AwsBackend Cli prints them as AWS CLI lines)
./Invoke-RdsPatchCompliance.ps1 -ProfileName prod -AllRegions -DryRun -AwsBackend Cli
```

```
Invoke-RdsPatchCompliance.ps1 v1.0.0 dry run - no AWS calls are made
  profiles : prod
  regions  : all enabled per account; discovery probe (8 in parallel), full scan only where databases (or a probe error) are found
  rule     : COMPLIANT <= 2 minor version(s) behind; support warning 180d
  formats  : text -> stdout
Profile prod:
    aws ... --profile prod --region \<region\> sts get-caller-identity
    aws ... --profile prod --region \<region\> iam list-account-aliases  (once per account, unless a name is set in the config; optional)
    aws ... --profile prod --region \<region\> ec2 describe-regions
  discovery probe, every enabled region, 8 at a time (2 calls per region):
    aws ... --region \<each-region\> rds describe-db-instances --max-records 20 --query length\(DBInstances\) --no-paginate
    aws ... --region \<each-region\> rds describe-db-clusters --max-records 20 --query length\(DBClusters\) --no-paginate
  full scan, only regions where a probe found a DB instance / cluster or failed:
    aws ... --region \<each-region\> rds describe-db-clusters
    ...
```

```powershell
# 4. Only Aurora PostgreSQL clusters whose name contains "pg1", and only the ones that need patching
./Invoke-RdsPatchCompliance.ps1 -ProfileName prod -Region us-east-1 -Engine aurora-postgresql -Identifier '*pg1*' -NonCompliantOnly
```

```
RDS PATCH COMPLIANCE REPORT - 2026-11-03 10:00 UTC (2026-11-03 15:30 IST)
Accounts : 111111111111 prod-core (prod)   Regions: 1 given
Regions  : 1 checked, 1 with databases, 0 empty, 0 errors
Rule     : NON-COMPLIANT when more than 2 valid minor versions behind (same major)
Filters  : engine=aurora-postgresql; identifier=*pg1*; non-compliant only

SUMMARY
  Servers/clusters : 6   COMPLIANT 3   NON-COMPLIANT 2   UNKNOWN 1   -> 50% compliant
...
=== aurora-postgresql: 6 (compliant 3, non-compliant 2, unknown 1) ===
  STATUS        BEHIND  IDENTIFIER                      TYPE             CURRENT       LATEST MINOR  AUTO   PEND  ACCOUNT      REGION         FLAGS
  NON-COMPLIANT      6  legacy-aurora-pg12              aurora-cluster   12.15         12.22         true      0  111111111111 us-east-1      past standard support (Extended Support charges)
  NON-COMPLIANT      3  reports-aurora-pg14             aurora-cluster   14.12         14.17         false     0  111111111111 us-east-1      -
```

```powershell
# 5. SQL Server (all editions) and Oracle only. Quote globs so PowerShell does not expand them.
./Invoke-RdsPatchCompliance.ps1 -ProfileName prod -Region us-east-1 -Engine 'sqlserver-*','oracle-*'
```

```
Filters  : engine=sqlserver-*,oracle-*

SUMMARY
  Servers/clusters : 3   COMPLIANT 2   NON-COMPLIANT 1   UNKNOWN 0   -> 66.7% compliant
...
  oracle-ee             19             1      1      0     0  19.0.0.0.ru-2025-07.rur-2025-07.r1  unknown (AWS lists no lifecycle dates for oracle-ee 19)
  sqlserver-se          16.00          1      1      0     0  16.00.4185.3.v1                     unknown (AWS lists no lifecycle dates for sqlserver-se 16.00)
  sqlserver-se          15.00          1      0      1     0  15.00.4430.1.v1                     unknown (AWS lists no lifecycle dates for sqlserver-se 15.00)
```

```powershell
# 6. Stricter policy: at most 1 behind, warn a year before the end of standard support
./Invoke-RdsPatchCompliance.ps1 -ProfileName prod -Region us-east-1 -MaxBehind 1 -WarnDays 365
```

```
Rule     : NON-COMPLIANT when more than 1 valid minor versions behind (same major)

SUMMARY
  Servers/clusters : 19   COMPLIANT 5   NON-COMPLIANT 13   UNKNOWN 1   -> 26.3% compliant
  Support          : 2 past standard support (Extended Support charges), 2 ending within 365 days
```

```powershell
# 7. Gate in a pipeline or scheduler: exit 5 when anything is NON-COMPLIANT
./Invoke-RdsPatchCompliance.ps1 -ProfileName prod -AllRegions -FailOnNonCompliant -Format csv -OutputDir ./ci
"rc=$LASTEXITCODE"
```

```
[INFO] Wrote ./ci/rds_patch_compliance_111111111111_20261103_153000.csv
[INFO] Wrote ./ci/rds_patch_compliance_111111111111_20261103_153000_regions.csv
[INFO] Result: 19 server(s)/cluster(s): COMPLIANT 11, NON-COMPLIANT 7, UNKNOWN 1 (57.9% compliant); 0 error(s); 37 AWS call(s); exit 5
rc=5
```

```powershell
# 8. Oracle: also count targets on other patch lines (the default counts the same line only)
./Invoke-RdsPatchCompliance.ps1 -ProfileName prod -Region us-east-1 -Engine 'oracle-*' -OracleAnyPatchLine

# 9. Log to a file as well (appends); debug detail with -Verbose
./Invoke-RdsPatchCompliance.ps1 -ProfileName prod -AllRegions -Format html -OutputDir ./compliance -LogFile ./compliance/run.log -Verbose

# 10. Second time zone in the header and a custom file prefix (IANA ids everywhere; on Windows, Windows ids work too)
./Invoke-RdsPatchCompliance.ps1 -ProfileName prod -Tz 'America/New_York' -Prefix weekly_patch -Format html -OutputDir ./compliance
.\Invoke-RdsPatchCompliance.ps1 -ProfileName prod -Tz 'India Standard Time' -Format html -OutputDir C:\reports   # Windows
```

## Use the JSON / CSV from PowerShell

The tool writes the report text straight to stdout. To get objects in your own session, read the file it
wrote, or pipe the output of a child `pwsh` process.

```powershell
# 11. Write JSON + CSV, then load the JSON
./Invoke-RdsPatchCompliance.ps1 -ProfileName prod -Region us-east-1 -Format json,csv -OutputDir ./j
$r = Get-Content (Get-ChildItem ./j/*.json | Select-Object -Last 1) -Raw | ConvertFrom-Json

# 12. NON-COMPLIANT servers, most behind first
$r.rows | Where-Object compliance_status -eq 'NON-COMPLIANT' | Sort-Object versions_behind -Descending |
    Format-Table identifier, engine, current_version, latest_minor_version, versions_behind
```

```
identifier          engine            current_version         latest_minor_version    versions_behind
----------          ------            ---------------         --------------------    ---------------
legacy-aurora-pg12  aurora-postgresql 12.15                   12.22                                 6
inv-mysql           mysql             8.0.36                  8.0.43                                6
shop-aurora-mysql   aurora-mysql      8.0.mysql_aurora.3.05.2 8.0.mysql_aurora.3.10.0               5
reports-aurora-pg14 aurora-postgresql 14.12                   14.17                                 3
analytics-pg        postgres          13.18                   13.22                                 3
ledger-maz          postgres          16.6                    16.10                                 3
hr-sql              sqlserver-se      15.00.4410.1.v1         15.00.4430.1.v1                       3
```

```powershell
# 13. Pending maintenance per server, readable
$r.rows | Where-Object pending_actions_count -gt 0 | ForEach-Object { '{0}: {1}' -f $_.identifier, $_.pending_actions }
```

```
orders-aurora-pg15: system-update on cluster (auto-apply 2026-11-30, forced 2026-12-30) - Upgrade to Aurora PostgreSQL 15.8.1 patch; os-upgrade on member orders-pg15-2 (opt-in: next-maintenance) - New Operating System update is available
catalog-docdb: system-update on member catalog-docdb-2 (auto-apply 2026-12-13, forced 2027-01-12) - Upgrades to the DocumentDB engine
inv-mysql: db-upgrade (auto-apply 2026-11-23) - Automatic minor version upgrade to 8.0.40; os-upgrade (no date, optional) - New Operating System update is available; it includes sec...
```

```powershell
# 14. Servers whose auto minor upgrade would move them, and to what
$r.rows | Where-Object default_auto_upgrade_target | ForEach-Object {
    '{0} {1} -> {2} (auto minor upgrade: {3})' -f $_.identifier, $_.current_version, $_.default_auto_upgrade_target, $_.auto_minor_upgrade }
```

```
shop-aurora-mysql 8.0.mysql_aurora.3.05.2 -> 8.0.mysql_aurora.3.08.2 (auto minor upgrade: mixed)
reports-aurora-pg14 14.12 -> 14.15 (auto minor upgrade: false)
orders-aurora-pg15 15.8 -> 15.12 (auto minor upgrade: true)
inv-mysql 8.0.36 -> 8.0.40 (auto minor upgrade: false)
...
```

```powershell
# 15. Region-wise compliance
$r.summary.regions | Where-Object total -gt 0 | Format-Table account_id, region, total, compliant, non_compliant, unknown, pct_compliant

# 16. Count by status from the CSV
Import-Csv (Get-ChildItem ./j/*.csv -Exclude *_regions.csv | Select-Object -Last 1) | Group-Object compliance_status -NoElement
```

```
Name          Count
----          -----
COMPLIANT        11
NON-COMPLIANT     7
UNKNOWN           1
```

```powershell
# 17. No file: pipe a child pwsh (stdout carries only the report; the log goes to stderr)
pwsh -NoProfile -File ./Invoke-RdsPatchCompliance.ps1 -ProfileName prod -Region us-east-1 -Format csv 2>$null | ConvertFrom-Csv | Measure-Object
#   Count : 19

# 18. Check one server's valid minor targets yourself (the source the report uses)
(Get-RDSDBEngineVersion -Engine aurora-postgresql -EngineVersion 15.8 -Region us-east-1).ValidUpgradeTarget |
    Where-Object { -not $_.IsMajorVersionUpgrade } | Select-Object EngineVersion, AutoUpgrade
```

## Several accounts: save in each account, merge anywhere

```powershell
# 19. In each account (CloudShell or the jump box): report + raw data file
./Invoke-RdsPatchCompliance.ps1 -ProfileName prod -AllRegions -Format html -OutputDir ./data -SaveData
./Invoke-RdsPatchCompliance.ps1 -ProfileName nonprod -AllRegions -Format html -OutputDir ./data -SaveData
```

```
[INFO] Wrote ./data/rds_patch_compliance_111111111111_20261103_153000.html
[INFO] Wrote ./data/rds_patch_111111111111_20261103.json
[INFO] Result: 19 server(s)/cluster(s): COMPLIANT 11, NON-COMPLIANT 7, UNKNOWN 1 (57.9% compliant); 0 error(s); 37 AWS call(s); exit 0
...
[INFO] Wrote ./data/rds_patch_222222222222_20261103.json
```

```powershell
# 20. Merge a folder into one named HTML file (0 AWS calls, no AWS module needed)
./Invoke-RdsPatchCompliance.ps1 -Merge ./data -OutputDir ./combined/all-accounts.html
```

```
[INFO] Input 1: ./data/rds_patch_111111111111_20261103.json (collected 2026-11-03T10:00:00Z, account(s) 111111111111 (prod))
[INFO] Input 2: ./data/rds_patch_222222222222_20261103.json (collected 2026-11-03T10:00:00Z, account(s) 222222222222 (nonprod))
[INFO] Wrote ./combined/all-accounts.html
[INFO] Merged 2 account(s) from 2 file(s): 22 server(s)/cluster(s): COMPLIANT 13, NON-COMPLIANT 8, UNKNOWN 1 (59.1% compliant); 0 error(s); 0 AWS calls; exit 0
```

```powershell
# 21. Merge named files (separate them with spaces) into text + CSV
./Invoke-RdsPatchCompliance.ps1 -Merge ./data/rds_patch_111111111111_20261103.json ./data/rds_patch_222222222222_20261103.json -Format text,csv -OutputDir ./combined

# 22. Windows: a folder with spaces in Downloads
.\Invoke-RdsPatchCompliance.ps1 -Merge 'C:\Users\me\Downloads\patch data' -OutputDir C:\reports\all-accounts.html

# 23. Re-judge saved data with a stricter rule; fail the job if anything is NON-COMPLIANT
./Invoke-RdsPatchCompliance.ps1 -Merge ./data -MaxBehind 1 -FailOnNonCompliant -Format text
```

The repo has two ready-made data files in [samples/data/](samples/data/), so you can try `-Merge` without
AWS:

```powershell
./Invoke-RdsPatchCompliance.ps1 -Merge ./samples/data -Format text
```

The output is the same as [samples/sample_merged.txt](samples/sample_merged.txt):

```
RDS PATCH COMPLIANCE REPORT - 2026-11-03 10:00 UTC (2026-11-03 15:30 IST)
Accounts : 111111111111 prod-core (prod), 222222222222 (nonprod)   Merged: 2 file(s)
Regions  : 6 checked, 2 with databases, 4 empty, 0 errors
Rule     : NON-COMPLIANT when more than 2 valid minor versions behind (same major)

SUMMARY
  Servers/clusters : 22   COMPLIANT 13   NON-COMPLIANT 8   UNKNOWN 1   -> 59.1% compliant
  Support          : 2 past standard support (Extended Support charges), 2 ending within 180 days
  Pending maint.   : on 3 server(s): os-upgrade 2, system-update 2, db-upgrade 1 (5 action(s))
```

The header uses the run time, so it changes when you run it yourself.

## Merge files saved by the Bash tool

Data files from the two tools have the same name and schema, so you can mix them freely. For example, one
account may run the Bash tool in CloudShell while another runs this tool on a Windows server.

```bash
# 24. Account 333333333333 saved with the Bash tool
./rds_patch_compliance_report.sh -P dev -r eu-west-1 -F csv -o ./bashdata --save-data
#   [INFO] Wrote ./bashdata/rds_patch_333333333333_20261103.json
```

```powershell
# 25. PowerShell merges the PowerShell-saved files and the Bash-saved file together
./Invoke-RdsPatchCompliance.ps1 -Merge ./data ./bashdata -Format text -MaxBehind 1
```

```
[INFO] Input 1: ./data/rds_patch_111111111111_20261103.json (collected 2026-11-03T10:00:00Z, account(s) 111111111111 (prod))
[INFO] Input 2: ./data/rds_patch_222222222222_20261103.json (collected 2026-11-03T10:00:00Z, account(s) 222222222222 (nonprod))
[INFO] Input 3: ./bashdata/rds_patch_333333333333_20261103.json (collected 2026-11-03T10:00:00Z, account(s) 333333333333 (dev))
RDS PATCH COMPLIANCE REPORT - 2026-11-03 10:00 UTC (2026-11-03 15:30 IST)
Accounts : 111111111111 prod-core (prod), 222222222222 (nonprod), 333333333333 (dev)   Merged: 3 file(s)
...
PER ACCOUNT
  ACCOUNT       PROFILE         COLLECTED              REG TOTAL  COMPL  NON-C  UNKN  %COMPL  PEND  NAME
  111111111111  prod            2026-11-03 10:00 UTC     1    19      5     13     1   26.3%     3  prod-core
  222222222222  nonprod         2026-11-03 10:00 UTC     1     3      0      3     0      0%     0  -
  333333333333  dev             2026-11-03 10:00 UTC     1     2      0      2     0      0%     0  -
```

```bash
# 26. The other direction: the Bash tool merges files saved by PowerShell
./rds_patch_compliance_report.sh --merge ./data -F csv -o ./bashmerged
#   [INFO] Merged 2 account(s) from 2 file(s): 22 server(s)/cluster(s): COMPLIANT 13, NON-COMPLIANT 8, UNKNOWN 1 (59.1% compliant); 0 error(s); 0 AWS calls; exit 0
```

The CSV from example 26 is byte-for-byte the same as the CSV that PowerShell produces from the same
files. See [docs/TEST-RESULTS.md](docs/TEST-RESULTS.md).

## Summary script

`Invoke-RdsPatchComplianceSummary.ps1` shows the high-level picture plus the NON-COMPLIANT servers. The
counting is the same as in the full report.

```powershell
# 27. Summary on the screen
./Invoke-RdsPatchComplianceSummary.ps1 -ProfileName prod,nonprod -AllRegions
```

```
RDS PATCH COMPLIANCE - SUMMARY
Run      : 2026-11-03 10:00 UTC / 2026-11-03 15:30 IST
Scanned  : accounts 111111111111 (prod), 222222222222 (nonprod); all enabled regions
Rule     : NON-COMPLIANT when the current version is more than 2 valid minor versions behind the latest (3 or more); counted from RDS ValidUpgradeTarget (same major; Oracle: same patch line)

Regions  : 6 checked, 2 with databases, 4 empty, 0 errors (discovery probe)

OVERALL  : 22 servers/clusters | COMPLIANT 13 | NON-COMPLIANT 8 | UNKNOWN 1 | 59.1% compliant
...
!!! NON-COMPLIANT SERVERS (8) - most behind first
!! 222222222222  ap-south-1  aurora-postgresql  dev-aurora-pg15      15.4 -> 15.13                                            7  ok
!! 111111111111  us-east-1   mysql              inv-mysql            8.0.36 -> 8.0.43                                         6  standard support ends in 179 days
!! 111111111111  us-east-1   aurora-postgresql  legacy-aurora-pg12   12.15 -> 12.22                                           6  past standard support (Extended Support charges)
...
```

```powershell
# 28. txt + one-page HTML + 4 CSVs into a folder (the summary stamps file names in UTC, as Bash does)
./Invoke-RdsPatchComplianceSummary.ps1 -ProfileName prod -AllRegions -Format txt,html,csv -OutputDir ./summary
```

```
[INFO] Wrote ./summary/rds_patch_compliance_summary_111111111111_20261113_040653.txt
[INFO] Wrote ./summary/rds_patch_compliance_summary_111111111111_20261113_040653.html
[INFO] Wrote ./summary/rds_patch_compliance_summary_111111111111_20261113_040653_summary.csv
[INFO] Wrote ./summary/rds_patch_compliance_summary_111111111111_20261113_040653_noncompliant.csv
[INFO] Wrote ./summary/rds_patch_compliance_summary_111111111111_20261113_040653_accounts.csv
[INFO] Wrote ./summary/rds_patch_compliance_summary_111111111111_20261113_040653_regions.csv
```

```powershell
# 29. Only Oracle, stricter rule (NON-COMPLIANT when 2 or more behind)
./Invoke-RdsPatchComplianceSummary.ps1 -ProfileName prod -Region us-east-1 -Engine 'oracle-*' -MaxBehind 1
```

```
!!! NON-COMPLIANT SERVERS (1) - most behind first
!! 111111111111  us-east-1  oracle-ee  fin-ora  19.0.0.0.ru-2025-01.rur-2025-01.r1 -> 19.0.0.0.ru-2025-07.rur-2025-07.r1       2  unknown (AWS lists no lifecycle dates for oracle-ee 19)
```

```powershell
# 30. Summary from saved data files (any of the four scripts), offline
./Invoke-RdsPatchComplianceSummary.ps1 -Merge ./data -Format txt,html,csv -OutputDir ./combined-summary

# 31. Weekly gate from merged data: exit 5 if anything is NON-COMPLIANT
./Invoke-RdsPatchComplianceSummary.ps1 -Merge ./data -MaxBehind 1 -FailOnNonCompliant ; "rc=$LASTEXITCODE"
```

```
OVERALL  : 22 servers/clusters | COMPLIANT 5 | NON-COMPLIANT 16 | UNKNOWN 1 | 22.7% compliant
...
rc=5
```

## Alerts

```powershell
# 32. E-mail (Linux / CloudShell: mail, mailx or sendmail) + Slack webhook, only when something is NON-COMPLIANT
./Invoke-RdsPatchCompliance.ps1 -ProfileName prod -Region us-east-1 -Format html -OutputDir ./alerts `
    -AlertEmail dba-team@example.com -AlertWebhook https://hooks.slack.com/services/XXX/YYY/ZZZ
```

```
[INFO] Result: 19 server(s)/cluster(s): COMPLIANT 11, NON-COMPLIANT 7, UNKNOWN 1 (57.9% compliant); 0 error(s); 30 AWS call(s); exit 0
[INFO] Alert: e-mail (NON-COMPLIANT) sent to dba-team@example.com
[INFO] Alert: webhook https://hooks.slack.com/... -> HTTP 200
```

The mail subject is `[rds_patch_compliance] NON-COMPLIANT: 7 non-compliant of 19, 57.9% compliant`.
The body is the text report. The Slack payload is `{"text":"*[rds_patch_compliance] NON-COMPLIANT: ...*\n```RDS PATCH COMPLIANCE REPORT ..."}`.

```powershell
# 33. Windows: e-mail through an SMTP relay (no mail command on Windows; the relay must accept unauthenticated mail)
.\Invoke-RdsPatchCompliance.ps1 -ProfileName prod -AllRegions -Format html -OutputDir C:\reports `
    -AlertEmail dba-team@example.com -AlertFrom rds-compliance@example.com -AlertSmtpServer smtp.example.com -AlertSmtpPort 25
```

```
[INFO] Alert: e-mail (NON-COMPLIANT) sent to dba-team@example.com
```

```powershell
# 34. Send after every run, even when everything is compliant; JSON payload for Teams / your own endpoint
./Invoke-RdsPatchCompliance.ps1 -ProfileName prod -AllRegions -AlertOn always -AlertWebhook https://example.com/hook -AlertWebhookFormat json

# 35. Test the wiring only (no AWS calls)
./Invoke-RdsPatchCompliance.ps1 -AlertTest -AlertWebhook https://example.com/hook -AlertWebhookFormat json
```

```
[INFO] Alert: webhook https://example.com/... -> HTTP 200
```

The JSON test payload is
`{"status":"TEST","text":"[rds_patch_compliance] TEST alert from <host>\n\nTest alert from Invoke-RdsPatchCompliance.ps1 v1.0.0 at ... IST. No AWS calls were made.\n"}`.

## Config file

```powershell
# 36. Settings from the sample file, one override on the command line (the command line wins)
./Invoke-RdsPatchCompliance.ps1 -ConfigFile ./rds_patch_compliance_report.conf.example -MaxBehind 3 -DryRun
```

```
Invoke-RdsPatchCompliance.ps1 v1.0.0 dry run - no AWS calls are made
  profiles : prod nonprod
  regions  : us-east-1 ap-south-1 (queried directly, no probe)
  filters  :
  rule     : COMPLIANT <= 3 minor version(s) behind; support warning 180d
  formats  : csv html text -> /home/me/compliance-reports
  back end : AWS.Tools cmdlets (-AwsBackend Cli prints the AWS CLI lines instead)
```

```powershell
# 37. Account names: set them in the config (otherwise the IAM account alias is used, otherwise the number)
Set-Content ./my.conf "111111111111 = prod-payments`n222222222222 = nonprod-shared"
./Invoke-RdsPatchCompliance.ps1 -ConfigFile ./my.conf -ProfileName prod,nonprod -Format json -OutputDir ./j
(Get-Content (Get-ChildItem ./j/*.json | Select-Object -Last 1) -Raw | ConvertFrom-Json).meta.accounts
```

```
account      profile name
-------      ------- ----
111111111111 prod    prod-payments
222222222222 nonprod nonprod-shared
```

## Scheduling

### Windows Task Scheduler

```powershell
# 38. Every Monday 09:30 (local time): HTML + CSV into C:\reports, e-mail when something is NON-COMPLIANT.
#     Put the settings in C:\tools\weekly.conf (see the sample config). Run once in an elevated pwsh.
$ps   = (Get-Command pwsh).Source
$tool = 'C:\tools\rds-patch-compliance-powershell\Invoke-RdsPatchCompliance.ps1'
$taskArgs = "-NoProfile -NonInteractive -File `"$tool`" -ConfigFile C:\tools\weekly.conf -LogFile C:\reports\run.log"
$action  = New-ScheduledTaskAction -Execute $ps -Argument $taskArgs -WorkingDirectory 'C:\tools\rds-patch-compliance-powershell'
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At 9:30am
Register-ScheduledTask -TaskName 'RDS patch compliance' -Action $action -Trigger $trigger `
    -User "$env:USERDOMAIN\svc-dba" -Password (Read-Host 'svc-dba password') -RunLevel Limited

# run it now, then look at the result (0 = report produced)
Start-ScheduledTask -TaskName 'RDS patch compliance'
Get-ScheduledTaskInfo -TaskName 'RDS patch compliance' | Select-Object LastRunTime, LastTaskResult
```

The account that runs the task needs an AWS profile in its own `%USERPROFILE%\.aws\config`, or an
instance role on an EC2 Windows server. The task is not tested in CI, which runs on Linux.

### cron on a Linux jump box

```bash
# 39. Every Monday 09:30 IST (server clock in Asia/Kolkata): all accounts, HTML + CSV, e-mail the team
30 9 * * 1  cd ~/rds-patch-compliance-powershell && pwsh -NoProfile -File ./Invoke-RdsPatchCompliance.ps1 -ProfileName prod,nonprod,dev -AllRegions -Format html,csv -OutputDir ~/compliance -AlertEmail dba-team@example.com -LogFile ~/compliance/run.log
```

### CI (GitHub Actions / Azure DevOps / Jenkins)

```powershell
# 40. Fail the job when anything is NON-COMPLIANT; keep the CSV as a build artifact
./Invoke-RdsPatchCompliance.ps1 -ProfileName prod -AllRegions -FailOnNonCompliant -Format csv,html -OutputDir ./out
exit $LASTEXITCODE      # 0 = all compliant, 5 = NON-COMPLIANT found, 1-4 = the run itself failed
```

## Where to run it

### Jump box with one role profile per account

```ini
# ~/.aws/config on the jump box (EC2 instance role assumes the read-only role in each account)
[profile prod]
role_arn          = arn:aws:iam::111111111111:role/dbops_compliance_role
credential_source = Ec2InstanceMetadata
region            = us-east-1

[profile nonprod]
role_arn          = arn:aws:iam::222222222222:role/dbops_compliance_role
credential_source = Ec2InstanceMetadata
region            = ap-south-1
```

```powershell
# 41. All accounts in one run; a profile whose role cannot be assumed is reported and the rest still run
./Invoke-RdsPatchCompliance.ps1 -ProfileName prod,nonprod -AllRegions -Format html,csv -OutputDir ~/compliance
```

With an unusable profile in the list (the mock's `broken` profile), the run carries on:

```
[ERROR] [broken/us-east-1] 'aws sts get-caller-identity' failed (rc=254): An error occurred (InvalidClientTokenId) when calling the GetCallerIdentity operation: The security token included in the request is invalid.
[INFO] Result: 19 server(s)/cluster(s): COMPLIANT 11, NON-COMPLIANT 7, UNKNOWN 1 (57.9% compliant); 1 error(s); 31 AWS call(s); exit 0
```

### AWS CloudShell

```bash
# 42. One-time setup, then a full scan of the signed-in account with the data file for a later merge
git clone https://github.com/manideepgrandhi/rds-patch-compliance-powershell.git ~/rds-patch-compliance-powershell
cd ~/rds-patch-compliance-powershell && git pull --ff-only
pwsh ./Invoke-RdsPatchCompliance.ps1 -AllRegions -Format html -OutputDir ~/compliance -SaveData
#   download ~/compliance/rds_patch_<ACCOUNTID>_<YYYYMMDD>.json (Actions > Download file) and merge it later
```

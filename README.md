# rds-patch-compliance-powershell

A PowerShell 7 port of [`rds_patch_compliance_report.sh`](https://github.com/manideepgrandhi/rds-patch-compliance) v1.5.1. It reports
minor-version patch compliance for Aurora, RDS (PostgreSQL, MySQL, MariaDB, SQL Server, Oracle),
DocumentDB and Neptune across accounts and regions. It is **read-only**: it only makes describe, list
and get calls.

The rules, the CSV, JSON, text and HTML outputs, and the `-SaveData` data files are the same as the
Bash tool's. Data files from either tool can be merged by either tool. Tests check this: see
[FEATURE-PARITY.md](FEATURE-PARITY.md). For how the two implementations differ, see
[COMPARISON.md](COMPARISON.md).

```
Invoke-RdsPatchCompliance.ps1          full per-server report  (= rds_patch_compliance_report.sh)
Invoke-RdsPatchComplianceSummary.ps1   manager summary         (= rds_patch_compliance_summary.sh)
src/                                   the module (RdsPatchCompliance.psm1 + one file per area)
assets/                                CSS / JS embedded in the HTML page (same as the Bash tool)
tests/                                 Pester 5 tests, the shared mock AWS CLI, an AWS.Tools test double
```

## Requirements

- **PowerShell 7.2+** (`pwsh`) on Windows, Linux or macOS. Windows PowerShell 5.1 is not supported.
- **One of these AWS back ends:**
  - `-AwsBackend AwsTools` (the default): the AWS.Tools modules `AWS.Tools.Common`, `.SecurityToken`, `.EC2`, `.RDS`, and optionally `.IdentityManagement` (account aliases), `.DocDB` and `.Neptune`.
  - `-AwsBackend Cli`: the AWS CLI v2. It runs the same commands as the Bash tool.
- No jq is needed. `-Merge` makes no AWS calls and needs no AWS module.

```powershell
Install-Module AWS.Tools.Installer -Scope CurrentUser
Install-AWSToolsModule AWS.Tools.Common, AWS.Tools.SecurityToken, AWS.Tools.EC2, AWS.Tools.RDS, AWS.Tools.IdentityManagement, AWS.Tools.DocDB, AWS.Tools.Neptune -Scope CurrentUser
```

The IAM permissions are the same as the Bash tool's read-only policy: `rds:Describe*` for clusters,
instances, pending maintenance, engine versions, major engine versions and global clusters, plus
`ec2:DescribeRegions` and, optionally, `iam:ListAccountAliases`. The AWS managed `ReadOnlyAccess`
policy covers all of them.

## Get it

### AWS CloudShell

CloudShell has `pwsh` and the AWS CLI already.

```bash
git clone https://github.com/manideepgrandhi/rds-patch-compliance-powershell.git
cd rds-patch-compliance-powershell
pwsh ./Invoke-RdsPatchCompliance.ps1 -AwsBackend Cli -AllRegions -Format text,html -OutputDir ~/compliance
```

You can also install AWS.Tools there once (`pwsh`, then the `Install-AWSToolsModule` line above) and
leave out `-AwsBackend Cli`.

### Windows (PowerShell 7)

```powershell
git clone https://github.com/manideepgrandhi/rds-patch-compliance-powershell.git
cd rds-patch-compliance-powershell
Unblock-File -Path .\*.ps1, .\src\*   # files downloaded as a ZIP are marked as "from the internet"
.\Invoke-RdsPatchCompliance.ps1 -ProfileName prod -Region us-east-1 -Format html -OutputDir C:\reports
```

For e-mail alerts on Windows, which has no `mail` command, add `-AlertSmtpServer smtp.example.com`
(and `-AlertSmtpPort`).

### As a module

```powershell
Import-Module ./src/RdsPatchCompliance.psm1
$rc = Invoke-RdsPatchCompliance -ProfileName prod -Region us-east-1 -Format csv -OutputDir ./out
# returns the exit code (0, 1, 2, 3, 4, 5) instead of exiting the session
```

To make the module available from anywhere, copy the repo folder to a folder on `$env:PSModulePath`
(keep `src/` and `assets/` together).

## Examples

The account numbers below are fake: 111111111111 = prod, 222222222222 = nonprod, 333333333333 = dev.

```powershell
# one account, two regions, text on screen
./Invoke-RdsPatchCompliance.ps1 -ProfileName prod -Region us-east-1,ap-south-1

# every enabled region (a quick probe finds the regions that have databases), all formats into a folder
./Invoke-RdsPatchCompliance.ps1 -ProfileName prod -AllRegions -Format text,csv,json,html -OutputDir ./reports
#   -> reports/rds_patch_compliance_111111111111_20261103_153000.{txt,csv,json,html} and _regions.csv

# only Aurora PostgreSQL clusters whose name contains "pay", only the non-compliant ones
./Invoke-RdsPatchCompliance.ps1 -ProfileName prod -Region us-east-1 -Engine 'aurora-postgresql' -Identifier '*pay*' -NonCompliantOnly

# stricter rule: at most 1 minor version behind; fail the CI job when anything is non-compliant
./Invoke-RdsPatchCompliance.ps1 -ProfileName prod -AllRegions -MaxBehind 1 -FailOnNonCompliant ; $LASTEXITCODE   # 5 = non-compliant found

# manager summary (txt on screen; html + 4 CSVs into a folder)
./Invoke-RdsPatchComplianceSummary.ps1 -ProfileName prod,nonprod -AllRegions -Format txt,html,csv -OutputDir ./summary

# what would run, without calling AWS
./Invoke-RdsPatchCompliance.ps1 -ProfileName prod,nonprod -AllRegions -DryRun

# settings from a file (same format as the Bash tool's .conf; parameters override it)
./Invoke-RdsPatchCompliance.ps1 -ConfigFile ./weekly.conf
```

### Jump box: several accounts through role profiles

On a jump box (or a CI runner) that has one set of credentials and assumes a read-only role in each
account, define one profile per account in `~/.aws/config`:

```ini
[profile prod]
role_arn       = arn:aws:iam::111111111111:role/RdsPatchComplianceReadOnly
source_profile = jumpbox
region         = us-east-1

[profile nonprod]
role_arn       = arn:aws:iam::222222222222:role/RdsPatchComplianceReadOnly
source_profile = jumpbox
region         = us-east-1

[profile dev]
role_arn       = arn:aws:iam::333333333333:role/RdsPatchComplianceReadOnly
credential_source = Ec2InstanceMetadata
region         = eu-west-1
```

Then scan them all in one run. A profile that fails (expired role, no trust) is reported and the
others still run.

```powershell
./Invoke-RdsPatchCompliance.ps1 -ProfileName prod,nonprod,dev -AllRegions -Format html,csv -OutputDir ./reports
```

AWS.Tools reads the same `~/.aws/config` and `~/.aws/credentials` files as the CLI, including `role_arn`,
`source_profile`, `credential_source` and SSO profiles. Account names come from `-ConfigFile` lines
such as `111111111111 = prod-payments`, otherwise from the IAM account alias, otherwise the number.

### Collect in each account, merge anywhere

```powershell
# in each account (CloudShell): also save the raw data
./Invoke-RdsPatchCompliance.ps1 -AwsBackend Cli -AllRegions -Format html -OutputDir ~/compliance -SaveData
#   -> ~/compliance/rds_patch_111111111111_20261103.json   (download this file)

# on a laptop: merge the files into one report (no AWS calls, no AWS modules, no jq)
./Invoke-RdsPatchCompliance.ps1 -Merge 'C:\Users\me\Downloads\patch data' -OutputDir C:\reports\all-accounts.html
./Invoke-RdsPatchComplianceSummary.ps1 -Merge ./data/*.json -Format txt,html,csv -OutputDir ./summary
```

`-Merge` takes files, folders and wildcards. It also reads files saved by the **Bash** tool, in any
version from v1.3.0 on, and the Bash tool's `--merge` reads files saved by this port. If the same account
appears in two files, the newer collection wins.

## Parameters

Run `./Invoke-RdsPatchCompliance.ps1 -Help` (or `Get-Help ./Invoke-RdsPatchCompliance.ps1 -Full`).
[FEATURE-PARITY.md](FEATURE-PARITY.md) maps every Bash option to its parameter.

Exit codes:
- 0: report produced
- 1: usage error
- 2: pre-check failed (no AWS back end, no profile has valid credentials)
- 3: bad `-Merge` input
- 4: output error
- 5: NON-COMPLIANT found (only with `-FailOnNonCompliant`)

## Tests

The tests use no AWS account. A mock `aws` (Python 3, shared with the Bash repo) serves a realistic
fleet, with fake credentials and a closed endpoint. The AWS.Tools back end is tested through a double
that returns **real AWS SDK model objects** built from the same mock data.

```powershell
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser
Invoke-Pester ./tests                                   # PowerShell-only tests
$env:RDS_PCR_BASH_DIR = '../rds-patch-compliance'       # a clone of the Bash repo (needs bash + jq)
Invoke-Pester ./tests -Output Detailed                  # + Bash parity and cross-merge tests
```

| File | What it checks |
|---|---|
| `tests/Parity.Tests.ps1` | 17 scan scenarios and 5 summary scenarios: Bash and PS on the same mock data with a frozen clock. Every output file and the log must match. |
| `tests/Merge.Tests.ps1` | PS→PS, Bash→PS, PS→Bash and Bash→Bash merges give the same results; the v1.3.0 fixtures; 12 bad-input exit-3 messages |
| `tests/Features.Tests.ps1` | 19 exit-code cases, AWS.Tools == CLI back end, parallel probe, dry-run, keep-workdir, alerts (fake `mail` and a local webhook), HTML offline in headless Chrome |
| `tests/Unit.Tests.ps1` | jq-compatible number, string, CSV and HTML printing and ordering; version rules |
| `tests/Lint.Tests.ps1` | PSScriptAnalyzer (settings in `PSScriptAnalyzerSettings.psd1`), case-colliding variable names, a comment above every function |

# Windows EC2 jump box setup: multi-account collection, merge, e-mail and schedule

This guide sets up a Windows EC2 jump box to run `Invoke-RdsPatchCompliance.ps1` on a schedule. One job collects
data from every account, merges it into one report and e-mails it. All account numbers below are fake examples;
replace them with yours.

## How it works

1. The jump box's **EC2 instance role** gives the box credentials. No access keys are stored.
2. Each other account has a read-only role, `RdsComplianceReadOnly`, that the jump box role is allowed to assume.
3. `~\.aws\config` has one profile per account.
4. A wrapper script collects with `-SaveData`, merges with `-Merge` (0 AWS calls) and mails the HTML report.
5. Task Scheduler runs the wrapper every week.

## 1. Find your AWS config

These commands only read; nothing changes.

```powershell
# env vars that override the default location
"AWS_CONFIG_FILE=$env:AWS_CONFIG_FILE"
"AWS_SHARED_CREDENTIALS_FILE=$env:AWS_SHARED_CREDENTIALS_FILE"

# default folder: C:\Users\<you>\.aws
Get-ChildItem "$env:USERPROFILE\.aws" -Force

# where each setting comes from, and all profiles
aws configure list
aws configure list-profiles
```

- If neither env var is set, the files are `C:\Users\<you>\.aws\config` and `C:\Users\<you>\.aws\credentials`.
- In `aws configure list`, the **Location** column shows the file for each value. `iam-role` means the EC2 instance
  role supplies the credentials, and no keys file is needed.
- A scheduled task must run as the **same Windows user** that owns this `.aws` folder.

If the folder is missing, check that the instance role works:

```powershell
aws --version
aws sts get-caller-identity
```

The ARN it prints, such as `arn:aws:sts::999999999999:assumed-role/<JumpBoxRoleName>/i-...`, shows the jump box
account number and role name. You need both in the steps below.

## 2. IAM permissions

### 2a. Read-only policy for the report

Attach this as an inline policy named `RdsPatchComplianceReadOnly`. Attach it to the jump box role to report on the
jump box's own account, and to each account's `RdsComplianceReadOnly` role. Go to IAM, then **Roles**, then the
role. Choose **Add permissions**, then **Create inline policy**, then the **JSON** tab.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "RdsPatchComplianceReadOnly",
    "Effect": "Allow",
    "Action": [
      "rds:DescribeDBClusters",
      "rds:DescribeDBInstances",
      "rds:DescribePendingMaintenanceActions",
      "rds:DescribeDBEngineVersions",
      "rds:DescribeDBMajorEngineVersions",
      "rds:DescribeGlobalClusters",
      "ec2:DescribeRegions",
      "iam:ListAccountAliases"
    ],
    "Resource": "*"
  }]
}
```

- Everything in this policy is read-only. `sts:GetCallerIdentity` needs no permission.
- The jump box usually can't edit its own role, so someone with IAM admin rights makes these changes.

### 2b. A role in each other account

In each other account, create a role named `RdsComplianceReadOnly`. Attach the policy from 2a and give it this
trust policy, which names the jump box role:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::999999999999:role/<JumpBoxRoleName>" },
    "Action": "sts:AssumeRole"
  }]
}
```

### 2c. Let the jump box role assume those roles

Add this inline policy to the jump box role:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "sts:AssumeRole",
    "Resource": [
      "arn:aws:iam::111111111111:role/RdsComplianceReadOnly",
      "arn:aws:iam::222222222222:role/RdsComplianceReadOnly"
    ]
  }]
}
```

## 3. Create the AWS config

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.aws" | Out-Null
@"
[profile base]
credential_source = Ec2InstanceMetadata
region = us-east-1

[profile prod]
role_arn = arn:aws:iam::111111111111:role/RdsComplianceReadOnly
credential_source = Ec2InstanceMetadata
region = us-east-1

[profile nonprod]
role_arn = arn:aws:iam::222222222222:role/RdsComplianceReadOnly
credential_source = Ec2InstanceMetadata
region = ap-south-1
"@ | Set-Content -Encoding ascii "$env:USERPROFILE\.aws\config"

aws configure list-profiles
aws sts get-caller-identity --profile prod
aws rds describe-db-instances --profile prod --region us-east-1 --query 'DBInstances[].DBInstanceIdentifier'
```

`credential_source = Ec2InstanceMetadata` tells the CLI to assume each account's role with the instance role's
credentials. There are no keys to store or rotate. The `base` profile reports on the jump box's own account.

## 4. Get the tool

```powershell
$ProgressPreference = 'SilentlyContinue'
Set-Location $env:USERPROFILE
$base = 'https://github.com/manideepgrandhi/rds-patch-compliance-powershell/releases/latest/download'
Invoke-WebRequest "$base/rds-patch-compliance-powershell.zip" -OutFile rds-patch-compliance-powershell.zip
Invoke-WebRequest "$base/rds-patch-compliance-powershell.zip.sha256" -OutFile rds-patch-compliance-powershell.zip.sha256
$expected = ((Get-Content .\rds-patch-compliance-powershell.zip.sha256 -Raw) -split '\s+')[0]
if ((Get-FileHash .\rds-patch-compliance-powershell.zip -Algorithm SHA256).Hash -ne $expected) { throw 'Checksum mismatch' }
Expand-Archive .\rds-patch-compliance-powershell.zip -DestinationPath . -Force
pwsh .\rds-patch-compliance-powershell\Invoke-RdsPatchCompliance.ps1 -Version
```

You need PowerShell 7.2 or later (`pwsh`), plus either the AWS CLI v2 (`-AwsBackend Cli`) or the AWS.Tools modules.

## 5. Collect, merge and e-mail by hand

```powershell
$tool = "$env:USERPROFILE\rds-patch-compliance-powershell"

# collect: one rds_patch_<ACCOUNTID>_<YYYYMMDD>.json per account
& "$tool\Invoke-RdsPatchCompliance.ps1" -ProfileName base,prod,nonprod -AllRegions -SaveData -OutputDir C:\compliance\data

# merge (0 AWS calls) and e-mail the text report in the body
& "$tool\Invoke-RdsPatchCompliance.ps1" -Merge C:\compliance\data -Format html,csv -OutputDir C:\compliance\combined `
    -AlertEmail dba-team@example.com -AlertFrom rds-compliance@example.com `
    -AlertSmtpServer smtp.example.com -AlertSmtpPort 25 -AlertOn always
```

- `-AlertOn always` mails on every run. The default mails only when something is NON-COMPLIANT or an AWS call failed.
- Data files saved by the Bash tool, for example in CloudShell, can go in the same folder and merge in too.
- The built-in e-mail puts the **text** report in the body and doesn't attach the HTML report. To send the HTML as an
  attachment, use the wrapper in step 6.
- The built-in e-mail and `Send-MailMessage` both work only through an SMTP relay that needs no login or TLS.

## 6. Wrapper script

Save this as `C:\compliance\Run-PatchCompliance.ps1`:

```powershell
$ErrorActionPreference = 'Stop'
$tool  = "$env:USERPROFILE\rds-patch-compliance-powershell"
$stamp = Get-Date -Format 'yyyyMMdd_HHmm'
$data  = "C:\compliance\data\$stamp"
$html  = "C:\compliance\reports\all-accounts_$stamp.html"
New-Item -ItemType Directory -Force $data, (Split-Path $html) | Out-Null

# 1. collect: one data file per account
& "$tool\Invoke-RdsPatchCompliance.ps1" -ProfileName base,prod,nonprod -AllRegions `
    -SaveData -OutputDir $data -LogFile C:\compliance\run.log

# 2. merge into one HTML report (0 AWS calls)
& "$tool\Invoke-RdsPatchCompliance.ps1" -Merge $data -OutputDir $html

# 3. mail it as an attachment
Send-MailMessage -From rds-compliance@example.com -To dba-team@example.com `
    -Subject "RDS patch compliance - all accounts - $(Get-Date -Format 'dd MMM yyyy')" `
    -Body 'Combined patch compliance report attached.' -Attachments $html `
    -SmtpServer smtp.example.com -Port 25

# 4. keep 30 days of data and reports
Get-ChildItem C:\compliance\data, C:\compliance\reports |
    Where-Object LastWriteTime -lt (Get-Date).AddDays(-30) | Remove-Item -Recurse -Force
```

- `Send-MailMessage` shows an "obsolete" warning in PowerShell 7, but it still works.
- If one account fails, the merge still runs and mails what was collected. Check `C:\compliance\run.log`.

## 7. Schedule it

Every Monday at 9:30 AM, in the box's time zone. Run this once in an admin PowerShell:

```powershell
$a = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument '-NoProfile -File C:\compliance\Run-PatchCompliance.ps1'
$t = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At 9:30am
Register-ScheduledTask -TaskName 'RDS Patch Compliance' -Action $a -Trigger $t -User $env:USERNAME -RunLevel Limited

# test it now
Start-ScheduledTask 'RDS Patch Compliance'
Get-ScheduledTaskInfo 'RDS Patch Compliance'   # LastTaskResult 0 = success
```

- The task asks for the password so it can run while you're signed out.
- It must run as the user that owns `C:\Users\<you>\.aws\config`. Otherwise, set `AWS_CONFIG_FILE` in the wrapper.

### Linux jump box

On a Linux jump box, use the same wrapper with Linux paths. Run `crontab -e` and add this line:

```
30 9 * * 1  pwsh -NoProfile -File $HOME/compliance/Run-PatchCompliance.ps1 >> $HOME/compliance/cron.log 2>&1
```

On Linux, the config lives at `~/.aws/config` for the user that owns the crontab.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `Unable to locate credentials` | The instance role isn't attached, or the task runs as another user |
| `AccessDenied ... sts:AssumeRole` | The policy from 2c is missing, or the trust policy in 2b names the wrong role |
| `AccessDenied ... rds:Describe*` | The policy from 2a isn't on that account's role |
| Support dates show `unknown` | `rds:DescribeDBMajorEngineVersions` is missing |
| No e-mail | The SMTP relay needs a login or TLS, or port 25 is blocked from EC2 |
| `exit 3` on merge | A file in the data folder isn't a valid `-SaveData` file |

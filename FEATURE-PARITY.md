# Feature parity: Bash v1.5.1 → PowerShell port

Reference: `manideepgrandhi/rds-patch-compliance` at `main` 5311723
(`rds_patch_compliance_report.sh` v1.5.1, `rds_patch_compliance_summary.sh` 1.3.0).

**Status key**
- **Same**: the same output bytes as Bash on the shared mock data (after the normalisation listed under each test).
- **Same (worded for PS)**: the behaviour is the same, but a message names the PowerShell parameter (`-SaveData`) where Bash names `--save-data`.
- **Accepted, ignored**: Bash accepts and ignores this too.

**Tests**
- `P` = `tests/Parity.Tests.ps1`: the Bash tool and the PowerShell tool run side by side and their outputs are compared.
- `M` = `tests/Merge.Tests.ps1`
- `F` = `tests/Features.Tests.ps1`
- `U` = `tests/Unit.Tests.ps1`

## Report script: `rds_patch_compliance_report.sh` → `Invoke-RdsPatchCompliance.ps1`

| Bash option | PowerShell parameter | Status | Tested |
|---|---|---|---|
| `-P, --profile` (repeatable, comma list) | `-ProfileName` (alias `-Profile`, `-P`; comma list or array) | Same | P: 1, 2 and 3 accounts, broken profile |
| `-r, --region` | `-Region` (`-r`) | Same | P |
| `-A, --all-regions` | `-AllRegions` (`-A`) | Same | P: discovery, access denied, empty |
| `--no-discover` / `--discover` | `-NoDiscover` / `-Discover` | Same | P: no discovery |
| `--probe-parallel N` (background jobs + `wait -n`) | `-ProbeParallel N` (`ForEach-Object -Parallel -ThrottleLimit N`) | Same output, real parallelism | F: 8 vs 1 gives the same report and is faster |
| `-e, --engine GLOB` | `-Engine` (`-e`) | Same | P: filters |
| `-i, --identifier GLOB` | `-Identifier` (`-i`) | Same | P: filters |
| `-T, --tag-columns` (ignored) | `-TagColumns` (`-T`) | Accepted, ignored | – |
| `--max-behind N` | `-MaxBehind` | Same | P, M |
| `--warn-days N` | `-WarnDays` | Same | P |
| `--non-compliant-only` | `-NonCompliantOnly` | Same | P: filters |
| `--oracle-any-patch-line` | `-OracleAnyPatchLine` | Same | P: oracle, M |
| `--fail-on-noncompliant` (exit 5) | `-FailOnNonCompliant` | Same | F: exit codes |
| `-F, --format text,csv,json,html` | `-Format` (`-F`) | Same: text, CSV, `_regions.csv`, JSON, HTML | P: every scenario, all four formats |
| `-o, --output-dir DIR` / `DIR/FILE.html` | `-OutputDir` (`-o`) | Same file names | P: prefix + single html file, M |
| `--save-data [FILE.json]` | `-SaveData` / `-SaveDataFile FILE.json` | Same file: schema 1, same keys and order; only `script_version` differs | M: four saved files compared |
| `--merge FILE\|DIR\|GLOB...` | `-Merge` (files, folders, globs; extra arguments after `-Merge` are taken as more files) | Same | M: all four directions plus the fixtures |
| `--prefix NAME` | `-Prefix` | Same | P |
| `--top N` (deprecated) | `-Top` | Accepted, ignored | – |
| `--tz ZONE` | `-Tz` (IANA zone ids; Windows ids work too) | Same | P: America/New_York |
| `-l, --log-file FILE` | `-LogFile` (`-l`) | Same lines | P: config file (the log file is compared) |
| `--alert-email ADDR` (mail/mailx/sendmail) | `-AlertEmail` (mail/mailx/sendmail, or `-AlertSmtpServer`/`-AlertSmtpPort` on Windows) | Same arguments and body | F: alerts |
| `--alert-webhook URL` (curl) | `-AlertWebhook` (Invoke-WebRequest) | Same payload bytes; URL never logged in full | F: alerts |
| `--alert-webhook-format slack\|json` | `-AlertWebhookFormat` | Same | F |
| `--alert-on noncompliant\|always` | `-AlertOn` | Same | F: quiet run |
| `--alert-from ADDR` | `-AlertFrom` | Same | F |
| `--alert-test` | `-AlertTest` | Same apart from the tool name | F |
| `--config FILE` (`key = value`, account-name lines, credentials refused) | `-ConfigFile` (`-Config`) | Same parser and the same keys | P: config file, F: credentials refused |
| `--aws-timeout SEC` | `-AwsTimeout` | Same (CLI flags, or the SDK ClientConfig.Timeout) | F: validation |
| `--max-attempts N` | `-MaxAttempts` | Same (AWS_MAX_ATTEMPTS, or the SDK MaxErrorRetry) | F: validation |
| `--keep-workdir` | `-KeepWorkdir` | One JSON file per AWS call (Bash keeps its whole work folder) | F |
| `--dry-run` | `-DryRun` | Same plan text; the first line has the script name | F: compared with Bash |
| `-v, --verbose` | `-Verbose` (`-Debug` works too) | Same debug lines | P: logs compared line by line |
| `-h, --help` / `-V, --version` | `-Help` / `-Version` (plus `Get-Help`) | Text is worded for PS | F |
| (n/a) | `-AwsBackend AwsTools\|Cli` | New: AWS.Tools modules (the default) or the AWS CLI | F: both back ends give the same output |
| exit codes 0/1/2/3/4/5 | same | Same | F: 19 cases, M: 12 bad merge inputs |
| exit 130 on Ctrl+C | not guaranteed | See "Not matched" | – |

### Report behaviour

| Feature | Status | Tested |
|---|---|---|
| Version rule (valid minor targets, deprecated version → UNKNOWN) | Same | P, U |
| Oracle patch lines (mrp/rur/plain RU, `--oracle-any-patch-line`) | Same | P, M |
| Lifecycle (standard and extended support end dates, `--warn-days` flag) | Same | P |
| No lifecycle API (old CLI or old AWS.Tools) | Same; the warning names AWS.Tools in AwsTools mode | P |
| Lookup failures, access denied, broken profile (reported, never hidden) | Same | P, F |
| Pending maintenance (cluster plus member actions, IST and UTC dates) | Same | P |
| Aurora global databases (one call per account, worst member, mismatch) | Same | P |
| Account names (config, then IAM alias, then the number) | Same | P |
| Region overview and per-region CSV | Same | P |
| HTML page (inline CSS and JS, sortable, works offline) | Same bytes apart from the footer | P, F: headless Chrome with no network |
| Atomic file writes, file mode 0640 | Same | – |
| Merge: newest collection wins, the same time goes to the later file, days counted from merge time | Same | M |
| Merge: older v1.3.0 data files | Same | M: fixtures |
| Merge: re-applies `-MaxBehind`, Oracle recount | Same | M |
| Merge: error messages (12 bad-input cases) | Same (worded for PS) | M |

## Summary script: `rds_patch_compliance_summary.sh` → `Invoke-RdsPatchComplianceSummary.ps1`

| Bash option | PowerShell parameter | Status | Tested |
|---|---|---|---|
| `-P / -r / -A / --no-discover / --probe-parallel / -e / -i` | `-ProfileName / -Region / -AllRegions / -NoDiscover / -ProbeParallel / -Engine / -Identifier` | Same | P: summary scenarios |
| `--max-behind / --warn-days / --oracle-any-patch-line` | `-MaxBehind / -WarnDays / -OracleAnyPatchLine` | Same | P |
| `-F txt\|html\|csv` (csv = 4 files) | `-Format` | Same txt, html, nc/summary/regions/accounts CSV | P |
| `-o / --prefix` | `-OutputDir / -Prefix` | Same names (stamped with the current UTC time, as in Bash) | P |
| `--save-data [FILE]` | `-SaveData / -SaveDataFile` | Same file | M |
| `--merge` | `-Merge` | Same | M: summary merge |
| `--fail-on-noncompliant` | `-FailOnNonCompliant` | Same | – |
| `--alert-*` | `-Alert*` | Same mail and payloads | F: summary alerts |
| `-v` | `-Verbose` | Same | – |
| (runs the report script, then summary.jq) | calls `Invoke-RdsPatchCompliance -ReturnReport` in the same process | Same output; one process instead of two | P, F |

## Not matched, and why

1. **Messages and help name PowerShell parameters.** Where Bash prints `--save-data`, the port prints `-SaveData`. The tests map the names back before they compare.
2. **Tool name and version.** `meta.script`, `meta.version`, `script_version` in saved files, the HTML footer, and the first dry-run line all name `Invoke-RdsPatchCompliance.ps1 1.0.0`. In a merged HTML report, the "Sources" table shows the version of each tool that saved a file. The data and the decisions are the same.
3. **Exit code 130 on Ctrl+C is not guaranteed.** PowerShell stops the pipeline with its own exit code. Partial files are not left behind, because writes are atomic.
4. **Time-zone abbreviation on Windows.** On Linux and macOS the port asks `date +%Z`, as Bash does, so the output is the same. Windows has no such source, so the port uses a small table (IST, EDT, CET, ...) and otherwise prints `+05`/`+0530` style, which is what `%Z` prints for zones with no abbreviation.
5. **`@html` and the apostrophe.** jq 1.7 prints `&apos;` and jq 1.6 prints `&#39;`. The port follows jq 1.7 (the box and CloudShell), so it matches Bash runs that use jq 1.7.
6. **Git Bash path handling** (`win_path`) is not needed. PowerShell takes Windows paths as they are.
7. **`-KeepWorkdir` content.** The port keeps one raw JSON file per AWS call. Bash keeps its whole work folder, which also holds intermediate jq files.
8. **Pester mocks do not reach `ForEach-Object -Parallel` runspaces.** The AWS.Tools back-end tests use `-ProbeParallel 1`. The parallel path is tested with the CLI back end.

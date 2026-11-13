# Test results

Latest full run: **2026-11-13, about 09:46 IST**, on `feature/powershell-port`. The Bash reference was
`manideepgrandhi/rds-patch-compliance` `main` 5311723 (report v1.5.1, summary 1.3.0). No AWS account was
used. All data comes from the shared mock (`tests/mock/aws`) and a local fake RDS endpoint, with fake
accounts 111111111111, 222222222222 and 333333333333.

| | |
|---|---|
| Result | **115 passed, 0 failed, 0 skipped** (331 s) |
| Full log | [pester-output.txt](pester-output.txt) |
| Environment | Linux, PowerShell 7.5.4, Pester 5.7.1, PSScriptAnalyzer 1.25.0, AWS.Tools.RDS 5.0.335, AWS CLI 2.40.2, jq 1.7, google-chrome (headless) |
| How it was run | `RDS_PCR_BASH_DIR` = a clone of the Bash repo; `RDS_PCR_REAL_AWS` = a real AWS CLI v2 binary (enables the three-way check); `Invoke-Pester ./tests -Output Detailed` |
| CI | `.github/workflows/tests.yml` runs the same suite on `ubuntu-latest` for every push and pull request |

## By test file

| File | Passed | What it covers |
|---|---:|---|
| `tests/Parity.Tests.ps1` | 26 | 17 scan scenarios + 4 stdout/credential/config checks + 5 summary scenarios. Bash and PowerShell run on the same mock with a frozen clock, and every output file, the exit code and the log must match. |
| `tests/Merge.Tests.ps1` | 26 | PowerShell-only merges, cross-merges with Bash in all four directions, the v1.3.0 fixtures, and 12 bad-input cases (exit 3 with the Bash message). |
| `tests/Features.Tests.ps1` | 41 | Exit codes, AWS.Tools giving the same report as the AWS CLI (real SDK objects), parallel probe, dry run, keep-workdir, in-process call, alerts, and the HTML page offline in headless Chrome. |
| `tests/Unit.Tests.ps1` | 15 | jq-compatible JSON, CSV and HTML printing, sorting, and the version rules. |
| `tests/Endpoint.Tests.ps1` | 3 | The real AWS SDK against a paging fake endpoint (230 servers), the discovery probe, and the three-way check: Bash + real CLI == PS + real CLI == PS + AWS.Tools. |
| `tests/Lint.Tests.ps1` | 4 | PSScriptAnalyzer: no errors or warnings in `src/` and the scripts, and no errors anywhere. Also checks for case-colliding variable names and a comment above every function. |

## Parity with the Bash tool (from the run above)

```
Describing Parity: scan report (Bash vs PowerShell)
  [+] fleet, 2 regions: same files, same exit code, same log
  [+] Aurora global databases: same files, same exit code, same log
  [+] Oracle patch lines: same files, same exit code, same log
  [+] Oracle any patch line: same files, same exit code, same log
  [+] discovery, 2 accounts: same files, same exit code, same log
  [+] no discovery: same files, same exit code, same log
  [+] access denied: same files, same exit code, same log
  [+] no lifecycle API: same files, same exit code, same log
  [+] lifecycle lookup fails: same files, same exit code, same log
  [+] version lookup fails: same files, same exit code, same log
  [+] no databases: same files, same exit code, same log
  [+] one broken profile: same files, same exit code, same log
  [+] filters + non-compliant only: same files, same exit code, same log
  [+] max-behind 0, warn-days 900, tz: same files, same exit code, same log
  [+] large (300 servers): same files, same exit code, same log
  [+] 3 accounts with aliases: same files, same exit code, same log
  [+] prefix + single html file: same files, same exit code, same log
  [+] stdout CSV (no -OutputDir) is byte-identical
  [+] stdout text report is identical (apart from the tool name)
  [+] bad credentials: exit 2 with the same messages
  [+] config file (account names, log_file, verbose): same outputs and same log file
Describing Parity: summary script (Bash vs PowerShell)
  [+] summary fleet: txt / html / 4 CSVs and stdout match
  [+] summary discovery: txt / html / 4 CSVs and stdout match
  [+] summary global: txt / html / 4 CSVs and stdout match
  [+] summary oracle + broken, max-behind 1: txt / html / 4 CSVs and stdout match
  [+] summary empty: txt / html / 4 CSVs and stdout match
```

## Merge cross-tests (from the run above)

```
Describing Merge: cross-compatible with the Bash tool
  [+] saved data files are identical (apart from script_version): old/prod_old.json
  [+] saved data files are identical (apart from script_version): rds_patch_111111111111_*.json
  [+] saved data files are identical (apart from script_version): rds_patch_222222222222_*.json
  [+] saved data files are identical (apart from script_version): rds_patch_333333333333_*.json
  [+] Bash save -> PS merge == Bash save -> Bash merge
  [+] PS save -> Bash merge == Bash save -> Bash merge
  [+] PS save -> PS merge == Bash save -> Bash merge
  [+] multi-account merge with -MaxBehind 1 -OracleAnyPatchLine matches
  [+] v1.3.0 fixtures + a new file into all.html: same page and same log
  [+] summary script -Merge matches (txt, html, CSVs)
Describing Merge: bad input files exit 3 with the Bash message
  [+] missing.json, page.html, trunc.json, report.json, array.json, other.json, noversion.json,
      incomplete.json, old.json, newer.json, emptydir, nomatch*.json -> exit 3   (12 tests)
```

## Sample outputs: PowerShell vs Bash

The files in [samples/](../samples/) were made by `tools/Build-Samples.ps1`. The same commands were then
run with the Bash tool on the same mock data, with the clock frozen at 2026-11-03 10:00 UTC, and the
results were compared with `cmp`:

| Output | Command | PS vs Bash |
|---|---|---|
| [sample_report.csv](../samples/sample_report.csv) | 2 accounts, `-AllRegions` | **byte-identical** |
| [sample_report_regions.csv](../samples/sample_report_regions.csv) | same | **byte-identical** |
| [sample_report.txt](../samples/sample_report.txt) | same | **byte-identical** |
| [sample_report.json](../samples/sample_report.json) | same | identical apart from `meta.script`, `meta.version` and `meta.host` |
| [sample_report.html](../samples/sample_report.html) | same | identical apart from the footer (`Invoke-RdsPatchCompliance.ps1 v1.0.0` vs `rds_patch_compliance_report.sh v1.5.1`) |
| [sample_merged.csv](../samples/sample_merged.csv) | `-Merge samples/data` (one PS-saved and one Bash-saved file) | **byte-identical** |
| [sample_merged_regions.csv](../samples/sample_merged_regions.csv) | same | **byte-identical** |
| [sample_merged.txt](../samples/sample_merged.txt) | same | **byte-identical** |
| [sample_merged.html](../samples/sample_merged.html) | same | identical apart from the footer |
| summary `_summary` / `_noncompliant` / `_accounts` / `_regions` CSV | summary `-Merge samples/data` | **byte-identical** |
| [sample_summary_merged.txt](../samples/sample_summary_merged.txt) | same | identical apart from the last line (`full per-server details: <tool name>`) |
| [sample_summary_merged.html](../samples/sample_summary_merged.html) | same | identical apart from the tool name and version |

All of these show 22 servers: COMPLIANT 13, NON-COMPLIANT 8 and UNKNOWN 1, which is 59.1% compliant.

To repeat the comparison:

```bash
pwsh ./tools/Build-Samples.ps1 -BashDir ../rds-patch-compliance        # regenerate samples/
# with the mock on PATH and RDS_PCR_NOW=1793700000 (see tests/TestHelpers.psm1, Set-PcrTestEnv):
../rds-patch-compliance/rds_patch_compliance_report.sh --merge samples/data -F text,csv,html -o /tmp/bash-merged
cmp samples/sample_merged.txt /tmp/bash-merged/*.txt && cmp samples/sample_merged.csv /tmp/bash-merged/*[0-9].csv
```

## Static analysis

`Invoke-ScriptAnalyzer` with `PSScriptAnalyzerSettings.psd1` finds nothing in `src/`, the two scripts or
`tools/Build-Samples.ps1`. Tests are checked at Error severity. This is part of `tests/Lint.Tests.ps1`
above.

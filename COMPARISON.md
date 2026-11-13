# Bash vs PowerShell: how the two implementations differ

This file compares `manideepgrandhi/rds-patch-compliance` (Bash + jq, `main` 5311723, report v1.5.1) with
this port (PowerShell 7). Both tools produce **the same output**: the tests run them side by side on the
same mock data with a frozen clock and require the same files byte for byte (see
[FEATURE-PARITY.md](FEATURE-PARITY.md)). The difference is in how they get there.

## Summary

- **The logic is the same; the hard part was the gaps between jq and PowerShell.** About half of the work went into making PowerShell sort, compare, print numbers, and treat empty arrays the way jq does. jq gives the Bash tool all of that for free.
- **The PS code is longer.** 3,022 code lines against 1,972; 255 KB against 183 KB. jq's pipelines are much denser than PowerShell loops.
- **Fewer dependencies, and Windows works without Git Bash.** The port needs only `pwsh` plus AWS.Tools *or* the AWS CLI. No jq, no coreutils, and curl is not needed.
- **On mock data the port is slower** (about 2× on small runs, about 4.6× at 3,000 servers), mostly because of PowerShell start-up and interpreted loops.
- **Against a real (local, paging) AWS endpoint, the AWS.Tools back end is 2.3× faster than Bash.** Bash starts one `aws` process per call (about 0.4 s each here); the SDK makes all calls inside one process.
- **The PS code is easier to call from other code:** `Invoke-RdsPatchCompliance` returns an exit code and `-ReturnReport` returns the report object. The summary script uses that in-process; the Bash summary script runs the report script and parses its JSON.

## At a glance

| | Bash tool | PowerShell port |
|---|---|---|
| Files (code) | `rds_patch_compliance_report.sh`, `rds_patch_compliance_summary.sh`, `lib/{compliance,versions,merge,summary}.jq` (6) | 2 wrapper scripts + `src/` module of 15 files (17) |
| Lines (all / code, no comments or blank lines) | 2,182 / 1,972 | 3,428 / 3,022 |
| Size | 183 KB | 255 KB |
| Biggest files | `report.sh` 1,037 lines, `compliance.jq` 540 | `Compliance.ps1` 462, `Render.ps1` 411 |
| Shared assets | `lib/compliance_page.js` (+ CSS inline in jq) | `assets/` (the same CSS and JS, byte for byte) |
| Runtime | Bash 4.4+, jq 1.6+, AWS CLI v2, coreutils (`date -d`, `tr`, `sed`, `timeout`, `mktemp` ...); curl and mail for alerts | PowerShell 7.2+, then AWS.Tools modules **or** the AWS CLI v2; mail/sendmail or an SMTP server for e-mail alerts |
| Windows | Git Bash (path conversion built in, `win_path`) | Native |
| Where the data lives during a run | Files in a work folder (`$WORK/p1/us-east-1/rows.json` ...), combined by `find \| sort` + `jq -s` | Ordered dictionaries in memory, returned from functions |
| Parallel probes | `probe_region ... &` + `wait -n`, results through files | `ForEach-Object -Parallel -ThrottleLimit N`, results returned as objects |
| Errors | `die <code> msg` → `exit` | `Stop-Pcr <code> msg` throws; one `catch` in the entry function turns it into the exit code |
| Tests | `run_tests.sh` (500+ checks), `validate_cli.sh`, browser checks (node + puppeteer) | Pester 5: 115 tests; 73 of them run the Bash tool too and compare the results |

## Section by section

### 1. Options and configuration

The Bash tool hand-parses its arguments in a `case` loop. Every option needs code for the value check,
the list split, and the "given once" reset:

```bash
# rds_patch_compliance_report.sh
case "$opt" in
    -P|--profile)       need_arg "$opt" $#; reset_once PROFILES; add_list PROFILES "$2"; shift 2 ;;
    -r|--region)        need_arg "$opt" $#; reset_once REGIONS; add_list REGIONS "$2"; shift 2 ;;
    -A|--all-regions)   ALL_REGIONS=1; shift ;;
    --no-discover)      DISCOVER=0; shift ;;
```

PowerShell declares parameters, so the binding, the aliases, `-Help` and tab completion come with the
language:

```powershell
# src/Main.ps1
[CmdletBinding(PositionalBinding = $false)]
param(
    [Alias('Profile', 'P')][string[]]$ProfileName, [Alias('r')][string[]]$Region, [Alias('A')][switch]$AllRegions, [switch]$NoDiscover, ...
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$MoreArgs, [switch]$ReturnReport
)
```

There are two catches. First, a script run with `pwsh -File` cannot take an array as separate words,
so `-Engine aurora-*,postgres` is the form that works everywhere. Second, without
`PositionalBinding = $false`, `-Merge a.json b.json c.json` sent `b.json` to some other parameter; the
port collects extra words in `MoreArgs` and treats them as more merge files, as Bash does. The config
file (`key = value`) has the same parser rules in both tools (never executed, credentials refused,
account-name lines), so the same `.conf` file works for both.

### 2. Calling AWS

Bash runs the CLI and keeps its JSON in a file:

```bash
aws_call() {   # aws_call <outfile> <profile> <region> <service> <operation> [args...]
    ...
    "${AWS_CMD[@]}" "$@" >"$out" 2>"$out.err" || rc=$?
    if (( rc == 0 )) && jq -e . "$out" >/dev/null 2>&1; then return 0; fi
    LAST_ERR="$(tr -s '\n' ' ' <"$out.err" | sed -E 's/aws: \[ERROR\]: //g; s/^ +//; s/ +$//')"
```

The port has **two back ends behind one function**, and both return the CLI's JSON shape:

```powershell
function Invoke-PcrAws {
    param([string]$ProfileName, [string]$Region, [string]$Call, [hashtable]$Params = @{}, [switch]$Soft)
    ...
    $res = if ($script:O.AwsBackend -eq 'Cli') { Invoke-PcrAwsCli $ProfileName $Region $Call $Params } else { Invoke-PcrAwsTools $ProfileName $Region $Call $Params }
```

With AWS.Tools, `Get-RDSDBCluster` returns .NET SDK objects, not JSON. `ConvertFrom-PcrSdkObject`
flattens them to the CLI's field names. It writes dates as `2026-11-03T10:00:00+00:00`, leaves out
unset fields (it asks the SDK's internal `IsSetX()`), and turns enum classes into strings. After that,
nothing else in the port knows which back end ran. Error text is rebuilt in the CLI's words
(`An error occurred (AccessDenied) when calling the DescribeDBInstances operation: ...`), so logs and
reports read the same. One extra detail: for RDS and EC2 the port sets the SDK's signing region
explicitly. With an endpoint override (a VPC endpoint, `AWS_ENDPOINT_URL`) the SDK would otherwise
guess the region from the URL. The fake-endpoint test found this.

### 3. Region discovery in parallel

```bash
for region in "$@"; do
    probe_region "$profile" "$region" "$dir/probe/$region.json" &
    running=$(( running + 1 ))
    if (( running >= PROBE_PARALLEL )); then wait -n || true; running=$(( running - 1 )); fi
done
wait || true
# the probes ran in subshells: count their calls / failures here
```

```powershell
$probeText = $script:ProbeBlock.ToString()
$results = $Regions | ForEach-Object -ThrottleLimit $n -Parallel {
    $sb = [scriptblock]::Create($using:probeText)
    & $sb $using:backend $using:ProfileName $_ $using:to $using:ma
}
```

Both tools have the same problem: the probe runs somewhere else (a subshell, or a runspace) that cannot
update the main counters, so both count the calls afterwards. In Bash the results come back through
files. In PowerShell they come back as objects, but each runspace starts empty: no module functions and
no variables except `$using:`. So the probe is one self-contained script block, passed as text.
Measured with a 0.5 s delay per probe: 8 in parallel vs 1 gives the same report in less than 60 % of
the time (a test checks this).

### 4. The compliance rules

The rules are a line-by-line port of `lib/compliance.jq` and `lib/versions.jq`. The jq version is
shorter. Here is the version sort key:

```jq
def vkey: [scan("[0-9]+|[A-Za-z]+") | (tonumber? // ascii_downcase)];
```

```powershell
function Get-VersionKey {
    param([AllowNull()]$Version)
    $s = ConvertTo-JqText $Version
    $out = foreach ($m in [regex]::Matches($s, '[0-9]+|[A-Za-z]+')) {
        if ($m.Value -match '^[0-9]+$') { [double]$m.Value } else { $m.Value.ToLowerInvariant() }
    }
    return , @($out)
}
```

The one-line jq `select | map | group_by` chains become `foreach` loops with explicit lists. They read
more easily for someone who does not know jq, but they take 2 to 4 times as many lines.

### 5. Making PowerShell behave like jq (the hidden cost)

The outputs must match byte for byte, so the port had to copy jq's behaviour where PowerShell differs:

| jq behaviour | PowerShell default | What the port does |
|---|---|---|
| `sort_by` total order: null < false < true < numbers < strings < arrays < objects; stable | `Sort-Object` is culture-aware, not stable, and cannot compare mixed types | `PcrJqOrder`: a small C# comparer compiled once with `Add-Type` |
| Numbers print as `57.89473684210527`, `1E+20`, `100` | `57.8947368421053`, `1E+20`, `100` | `PcrJqJson.Number` (shortest round-trip) |
| `@csv`, `@html` (`&apos;` in jq 1.7) | `ConvertTo-Csv` quotes differently and has no `@html` | `ConvertTo-JqCsvLine`, `ConvertTo-JqHtml` |
| JSON keys keep their order, 2-space indent | `ConvertTo-Json` uses 4 spaces, escapes `<>'&`, and has a depth limit | Own writer (`PcrJqJson.Write`), ordered dictionaries everywhere |
| `[]` stays an array, `{}` is truthy | A function returning `@()` or a 1-item array gets *unrolled* (to `$null` or a scalar) | `return , $x`, `@(if ...)`, `List[object]`, and tests for each case |
| Variable names are case-sensitive (`$L` ≠ `$l`) | Case-**in**sensitive | Renames, plus a lint test that fails on any function using two spellings |

During the port, five bugs came from array unrolling and five from case-insensitive names. One
example: `$G`/`$g` in the merge were the same variable, so merges silently used the wrong data. The
first version wrote JSON and compared values in PowerShell; that took about 25 ms per server.
Moving those two hot spots to about 140 lines of compiled C# cut a 3,000-server run from 79 s to 17 s.

### 6. Outputs (text, CSV, JSON, HTML)

These are the same in both tools; the CSS and JS are copied as is. Bash builds the HTML inside jq
(`compliance.jq`), and the port builds it with a `List[string]` and `-join`. Both write atomically: a
temp file, then a rename, with mode 0640. The HTML has no external references, and a test opens it in
headless Chrome with networking disabled.

### 7. Save-data and merge

Both tools use the same file format (`schema_version` 1, the same keys in the same order). The merge
rules are the same ("newest collection per account wins; a tie goes to the later file"):

```jq
| ($ALL | group_by(.account) | map(sort_by(.collected_epoch, .i))) as $G
| ([ $G[] | last | {key: "\(.account)|\(.i)", value: true} ] | from_entries) as $USE
```

```powershell
$groups = @(foreach ($g in (Group-JqBy $all { param($x) , @($x.account) })) { , (Get-JqSortedBy $g { param($x) , @($x.collected_epoch, $x.i) }) })
$use = @{}; foreach ($g in $groups) { $use["$($g[-1].account)|$($g[-1].i)"] = $true }
```

Cross-tests (all pass, see `tests/Merge.Tests.ps1`):
- Bash save → PS merge, PS save → Bash merge, and PS save → PS merge all equal Bash save → Bash merge.
- So do a 3-account merge with an old and a new file for the same account, the same merge with `-MaxBehind 1 -OracleAnyPatchLine`, and the v1.3.0 fixtures.
- The only differences are the tool name and version cells.

### 8. Alerts

| | Bash | PowerShell |
|---|---|---|
| Webhook | `curl -sS --fail --max-time 20 --retry 2 -K -` (URL passed on stdin so it is not in `ps`) | `Invoke-WebRequest -TimeoutSec 20 -MaximumRetryCount 2` (in-process, so not in `ps` either) |
| E-mail | `mail` / `mailx` / `sendmail` | The same programs, or `-AlertSmtpServer` (.NET SMTP) on Windows |
| Payload | jq builds Slack or JSON | The same bytes (tested against a local webhook receiver) |

### 9. Summary script

The Bash summary script runs `rds_patch_compliance_report.sh -F json`, then renders with `summary.jq`.
The PS summary calls `Invoke-RdsPatchCompliance -ReturnReport` in the same process and renders the
object. That saves one PowerShell start-up (about 0.8 s) and a JSON round trip. The summary
outputs (txt, html, 4 CSVs) are the same.

### 10. Errors and exit codes

`die 3 "..."` exits on the spot, from anywhere, even inside a subshell where it only ends the subshell.
That is why the Bash tool checks probe files for "produced no result". The port's `Stop-Pcr 3 "..."`
throws an exception that carries the code, and the entry function turns it into the return value. This
makes the module safe to call from another script: it never closes the caller's session. One thing
cannot be matched: exit code 130 on Ctrl+C.

## Performance

Each number is the median of 3 wall-clock runs on the same Linux box, in ms. The PS runs use
`-AwsBackend Cli` with the same mock `aws` (a Python script, about 22 ms per call) as Bash.

| Scenario | Bash | PowerShell | PS / Bash |
|---|---:|---:|---:|
| Start-up only (`--version` / `-Version`) | 8 | 836 | – |
| fleet: 1 account, 2 regions, 4 formats | 1,817 | 3,320 | 1.8× |
| discovery `-A`, 2 accounts, 4 formats | 2,354 | 3,664 | 1.6× |
| discovery `-A`, every probe 0.5 s, 8 in parallel | 4,015 | 5,012 | 1.2× |
| 300 servers, 4 formats | 1,392 | 5,508 | 4.0× |
| 1,000 servers, 4 formats | 1,885 | 8,362 | 4.4× |
| 3,000 servers, 4 formats | 3,764 | 17,269 | 4.6× |
| merge 4 saved files, 4 formats (no AWS) | 597 | 3,362 | 5.6× |
| summary, 1 account, 2 regions, txt+html+csv | 1,726 | 3,576 | 2.1× |

The same scan, now with the **real** AWS CLI v2 (2.40.2) and the **real** AWS.Tools 5.0.335 SDK against
the Bash repo's local fake RDS endpoint (`-A`: 5 regions, 231 servers, paged lists, 58 requests):

| Tool and back end | ms |
|---|---:|
| Bash + real AWS CLI | 12,059 |
| PowerShell + real AWS CLI (`-AwsBackend Cli`) | 13,256 |
| PowerShell + AWS.Tools (default) | **5,162** |

What the numbers say:
- PowerShell starts in about 0.8 s: `pwsh` itself, loading the module, and compiling the C# helpers once.
- The interpreted loops cost about 4.5 ms per server; jq does the same work in well under 1 ms.
- Against real AWS, the cost is dominated by the calls. The AWS CLI is a Python program that starts once per call (about 0.4 s per call in this run, 28 calls), and the SDK does not have that cost. A real account adds network latency to every call in both tools, so the AWS.Tools advantage grows with the number of calls.

## Pros and cons

**Bash + jq**
- Pros:
  - Shorter and denser: the rules read like a specification once you know jq.
  - Starts at once; fastest at rendering big fleets.
  - Runs anywhere Bash and jq are installed, including CloudShell with nothing to install.
  - Its test suite also checks the real CLI's command lines (`validate_cli.sh`).
- Cons:
  - Needs jq and GNU coreutils, and Git Bash on Windows (with path conversion).
  - One `aws` process per call.
  - jq is a skill few teams have.
  - Data passes through work files.
  - Errors in subshells must be caught through files.

**PowerShell**
- Pros:
  - Native on Windows, Linux and macOS.
  - Uses the AWS SDK (no process per call: 2.3× faster against an endpoint).
  - Typed, discoverable parameters with help and tab completion.
  - Callable as a module (exit code or report object).
  - No jq, and no curl for alerts.
  - Pester tests compare it with the Bash tool on every run.
- Cons:
  - More code.
  - About 0.8 s start-up, and slower rendering for very large fleets.
  - PowerShell's array unrolling and case-insensitive variables are easy to get wrong.
  - Needs about 140 lines of embedded C# to match jq exactly and fast enough.
  - The mock-based tests need Python for the mock CLI.

## When to use which

- **CloudShell, one account at a time, quick look:** either. Bash needs nothing installed. The port needs `-AwsBackend Cli`, or AWS.Tools installed once.
- **Windows desktop or jump box, many accounts through role profiles:** PowerShell. It runs natively, and with AWS.Tools each account and region costs much less.
- **CI pipelines:** either. PowerShell if the runner is Windows or already uses PowerShell; Bash if images are minimal Linux with jq.
- **Calling from other automation (dashboards, ticket bots):** PowerShell. `Import-Module` it, then use `Invoke-RdsPatchCompliance -ReturnReport`.
- **Very large fleets (thousands of servers per run) on Linux with the CLI:** Bash renders fastest. With AWS.Tools, PowerShell's faster API calls usually win back more time than the rendering costs.
- **Mixed teams:** use both. Save data with whichever tool fits each account, then merge with either one; the files are interchangeable.

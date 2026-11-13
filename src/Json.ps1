# src/Json.ps1 - JSON in and out, plus the small jq behaviours the port depends on.
#
# Why this file exists: the Bash tool does all data work in jq. To produce byte-identical CSV / JSON / HTML,
# the PowerShell port has to copy a few jq rules exactly:
#   - JSON objects keep their key order (OrderedDictionary with case-SENSITIVE keys, like jq)
#   - values sort in jq order: null < false < true < numbers < strings < arrays < objects
#   - numbers print like jq (100 not 100.0, 66.7, 1E+17), strings escape like jq
#   - sort_by is stable, group_by / unique sort first
# ConvertFrom-Json / ConvertTo-Json are NOT used: they turn ISO dates into DateTime (PowerShell 7.0-7.4),
# use case-insensitive keys and print numbers and escapes differently.

$script:Inv = [System.Globalization.CultureInfo]::InvariantCulture

# ---------------------------------------------------------------------------------------------- object helpers
# New-JqObject: an empty JSON object (ordered, case-sensitive keys). Optional hashtable/ordered seed is copied in.
function New-JqObject {
    param($From)
    $o = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    if ($null -ne $From) { foreach ($k in $From.Keys) { $o[[string]$k] = $From[$k] } }
    return , $o
}
# Copy-JqObject: shallow copy of a JSON object (jq values are immutable; this keeps that promise)
function Copy-JqObject {
    param($Object)
    $o = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    foreach ($k in $Object.Keys) { $o[$k] = $Object[$k] }
    return , $o
}
# Get-JqField: jq ".key // null" on an object (null when the object is null or has no such key)
function Get-JqField {
    param($Object, [string]$Name)
    if ($null -eq $Object -or $Object -isnot [System.Collections.IDictionary]) { return $null }
    if ($Object.Contains($Name)) { return $Object[$Name] }   # NB: arrays unroll; wrap the call in @() where an array is expected
    return $null
}
# Test-JqTruthy: jq truthiness (only null and false are false)
function Test-JqTruthy { param($Value) return -not ($null -eq $Value -or ($Value -is [bool] -and -not $Value)) }

# ---------------------------------------------------------------------------------------------- parse
# ConvertFrom-JqJson: JSON text -> OrderedDictionary / object[] / long / double / string / bool / null
function ConvertFrom-JqJson {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)
    $opts = [System.Text.Json.JsonDocumentOptions]::new()
    $opts.AllowTrailingCommas = $false
    $opts.MaxDepth = 256
    $doc = [System.Text.Json.JsonDocument]::Parse($Json, $opts)
    try { return , (ConvertFrom-JqElement $doc.RootElement) } finally { $doc.Dispose() }
}
# ConvertFrom-JqElement: one System.Text.Json element -> PowerShell value (recursive)
function ConvertFrom-JqElement {
    param([System.Text.Json.JsonElement]$E)
    switch ($E.ValueKind) {
        'Object' {
            $o = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
            foreach ($p in $E.EnumerateObject()) { $o[$p.Name] = ConvertFrom-JqElement $p.Value }   # duplicate key: last wins (jq too)
            return , $o
        }
        'Array' {
            $l = [System.Collections.Generic.List[object]]::new()
            foreach ($x in $E.EnumerateArray()) { $l.Add((ConvertFrom-JqElement $x)) }
            return , $l.ToArray()
        }
        'String' { return $E.GetString() }
        'Number' {
            [long]$n = 0
            if ($E.TryGetInt64([ref]$n)) { return $n }
            return $E.GetDouble()
        }
        'True' { return $true }
        'False' { return $false }
        default { return $null }
    }
}
# Read-JqJsonFile: parse a JSON file (UTF-8, BOM tolerated)
function Read-JqJsonFile {
    param([Parameter(Mandatory)][string]$Path)
    return , (ConvertFrom-JqJson ([System.IO.File]::ReadAllText((Resolve-PcrPath $Path))))
}

# Resolve-PcrPath: a path relative to the PowerShell location -> full file-system path. .NET file APIs
# resolve relative paths against the PROCESS directory, which Set-Location / Push-Location do not change.
function Resolve-PcrPath {
    param([string]$Path)
    if (-not $Path) { return $Path }
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

# ---------------------------------------------------------------------------------------------- print
# PcrJqJson (C#, compiled once per session): jq's JSON printer. Same rules as jq 1.7:
#   numbers: integral -> digits; otherwise shortest round-trip, exponent as 1E+20; NaN -> null
#   strings: escape " \ and control characters (\n \t \r \b \f, others \u00XX, DEL too); non-ASCII stays raw
#   pretty print = 2-space indent, "key": value; compact = no spaces (jq -c / tojson)
# (The first version was a recursive PowerShell function; it took ~5 ms per server row.)
if (-not ('PcrJqJson' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
public static class PcrJqJson {
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
    static readonly Regex Exp = new Regex(@"^(-?)(\d)(?:\.(\d+))?E([+-])(\d+)$");
    static object Unwrap(object v) { var p = v as System.Management.Automation.PSObject; return p != null ? p.BaseObject : v; }
    public static bool IsNumber(object v) { v = Unwrap(v); return v is long || v is int || v is double || v is decimal || v is float; }
    public static string Number(object n) {
        n = Unwrap(n);
        if (n is long || n is int || n is short || n is byte || n is uint || n is ulong) return Convert.ToInt64(n).ToString(Inv);
        double d = Convert.ToDouble(n, Inv);
        if (double.IsNaN(d)) return "null";
        if (double.IsInfinity(d)) return d > 0 ? "1.7976931348623157e+308" : "-1.7976931348623157e+308";
        if (Math.Floor(d) == d && Math.Abs(d) < 1e17) return ((long)d).ToString(Inv);
        string s = d.ToString("R", Inv);
        var m = Exp.Match(s);
        if (m.Success) {
            int e = int.Parse(m.Groups[5].Value, Inv);
            if (m.Groups[4].Value == "-" && e <= 5) return d.ToString("0.###################", Inv);
            return m.Groups[1].Value + m.Groups[2].Value + (m.Groups[3].Success ? "." + m.Groups[3].Value : "") + "E" + m.Groups[4].Value + e.ToString("00", Inv);
        }
        return s;
    }
    public static void Str(StringBuilder sb, string s) {
        sb.Append('"');
        foreach (char c in s) {
            switch (c) {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\t': sb.Append("\\t"); break;
                case '\r': sb.Append("\\r"); break;
                case '\b': sb.Append("\\b"); break;
                case '\f': sb.Append("\\f"); break;
                default:
                    if (c < 32 || c == 127) sb.AppendFormat(Inv, "\\u{0:x4}", (int)c); else sb.Append(c);
                    break;
            }
        }
        sb.Append('"');
    }
    public static string Str(string s) { var sb = new StringBuilder(s.Length + 2); Str(sb, s ?? ""); return sb.ToString(); }
    public static string Write(object v, bool compact) { var sb = new StringBuilder(); Value(sb, v, 0, compact); return sb.ToString(); }
    static void Indent(StringBuilder sb, int level) { sb.Append('\n').Append(' ', 2 * level); }
    static void Value(StringBuilder sb, object v, int level, bool compact) {
        v = Unwrap(v);
        if (v == null) { sb.Append("null"); return; }
        if (v is bool) { sb.Append((bool)v ? "true" : "false"); return; }
        if (v is string) { Str(sb, (string)v); return; }
        if (IsNumber(v)) { sb.Append(Number(v)); return; }
        var dict = v as IDictionary;
        if (dict != null) {
            if (dict.Count == 0) { sb.Append("{}"); return; }
            sb.Append('{'); bool first = true;
            foreach (DictionaryEntry kv in dict) {
                if (!first) sb.Append(','); first = false;
                if (!compact) Indent(sb, level + 1);
                Str(sb, Convert.ToString(kv.Key, Inv)); sb.Append(compact ? ":" : ": ");
                Value(sb, kv.Value, level + 1, compact);
            }
            if (!compact) Indent(sb, level);
            sb.Append('}'); return;
        }
        if (v is DateTime) { Str(sb, ((DateTime)v).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'+00:00'", Inv)); return; }
        var en = v as IEnumerable;
        if (en != null) {
            bool first = true; bool any = false;
            foreach (var x in en) {
                if (!any) { sb.Append('['); any = true; }
                if (!first) sb.Append(','); first = false;
                if (!compact) Indent(sb, level + 1);
                Value(sb, x, level + 1, compact);
            }
            if (!any) { sb.Append("[]"); return; }
            if (!compact) Indent(sb, level);
            sb.Append(']'); return;
        }
        Str(sb, Convert.ToString(v, Inv));
    }
}
'@
}
# Format-JqNumber: jq 1.7 number text (see PcrJqJson)
function Format-JqNumber { param($N) return [PcrJqJson]::Number($N) }
# ConvertTo-JqString: a JSON string literal escaped like jq (see PcrJqJson)
function ConvertTo-JqString { param([AllowNull()][AllowEmptyString()][string]$S) return [PcrJqJson]::Str($S) }
# Test-JqNumber / Test-JqArray / Test-JqObject: jq type checks on PowerShell values
function Test-JqNumber { param($V) return ($V -is [long] -or $V -is [int] -or $V -is [double] -or $V -is [decimal] -or $V -is [single]) }
function Test-JqObject { param($V) return ($V -is [System.Collections.IDictionary]) }
function Test-JqArray { param($V) return ($null -ne $V -and $V -isnot [string] -and $V -isnot [System.Collections.IDictionary] -and $V -is [System.Collections.IEnumerable]) }

# ConvertTo-JqJson: value -> JSON text. -Compact = jq -c / tojson; default = jq's 2-space pretty print
function ConvertTo-JqJson {
    param([AllowNull()]$Value, [switch]$Compact)
    return [PcrJqJson]::Write($Value, $Compact.IsPresent)
}
# ConvertTo-JqText: jq string interpolation "\(x)" (strings raw, null -> "null", numbers jq style, rest compact JSON)
function ConvertTo-JqText {
    param([AllowNull()]$V)
    if ($V -is [string]) { return $V }
    if ($null -eq $V) { return 'null' }
    if ($V -is [bool]) { if ($V) { return 'true' } else { return 'false' } }
    if (Test-JqNumber $V) { return (Format-JqNumber $V) }
    return (ConvertTo-JqJson $V -Compact)
}
# ConvertTo-JqHtml: jq @html (tostring, then & < > ' " escaped)
function ConvertTo-JqHtml {
    param([AllowNull()]$V)
    $s = ConvertTo-JqText $V
    return $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace("'", '&apos;').Replace('"', '&quot;')
}
# ConvertTo-JqCsvLine: jq @csv (strings quoted with "" doubling, numbers / booleans bare, null empty)
function ConvertTo-JqCsvLine {
    param([object[]]$Fields)
    $parts = foreach ($f in $Fields) {
        if ($null -eq $f) { '' }
        elseif ($f -is [bool]) { if ($f) { 'true' } else { 'false' } }
        elseif (Test-JqNumber $f) { Format-JqNumber $f }
        else { '"' + ([string]$f).Replace('"', '""') + '"' }
    }
    return ($parts -join ',')
}
# Get-JqDash: jq "dash" helper (null or "" -> "-", else tostring)
function Get-JqDash { param([AllowNull()]$V) if ($null -eq $V -or ($V -is [string] -and $V -eq '')) { return '-' } return (ConvertTo-JqText $V) }

# ---------------------------------------------------------------------------------------------- ordering
# PcrJqOrder (C#, compiled once per session): jq's total order. Sorting thousands of rows with a
# PowerShell comparison scriptblock took ~25 ms per server, so the comparer itself is compiled.
#   null < false < true < numbers < strings (code-point order) < arrays (element-wise, shorter prefix first)
#   < objects (sorted key list first, then the values key by key)
if (-not ('PcrJqOrder' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
public static class PcrJqOrder {
    static object Unwrap(object v) { var p = v as System.Management.Automation.PSObject; return p != null ? p.BaseObject : v; }
    static bool IsNumber(object v) { return v is long || v is int || v is double || v is decimal || v is float; }
    public static int Rank(object v) {
        v = Unwrap(v);
        if (v == null) return 0;
        if (v is bool) return ((bool)v) ? 2 : 1;
        if (IsNumber(v)) return 3;
        if (v is string) return 4;
        if (v is IDictionary) return 6;
        return 5;
    }
    static List<object> AsList(object v) {
        var l = new List<object>();
        var e = v as IEnumerable;
        if (e != null) { foreach (var x in e) l.Add(x); } else { l.Add(v); }
        return l;
    }
    public static int Compare(object a, object b) {
        a = Unwrap(a); b = Unwrap(b);
        int ra = Rank(a), rb = Rank(b);
        if (ra != rb) return Math.Sign(ra - rb);
        switch (ra) {
            case 3: { double x = Convert.ToDouble(a), y = Convert.ToDouble(b); return x < y ? -1 : (x > y ? 1 : 0); }
            case 4: return Math.Sign(string.CompareOrdinal((string)a, (string)b));
            case 5: {
                var xa = AsList(a); var xb = AsList(b); int n = Math.Min(xa.Count, xb.Count);
                for (int i = 0; i < n; i++) { int c = Compare(xa[i], xb[i]); if (c != 0) return c; }
                return Math.Sign(xa.Count - xb.Count);
            }
            case 6: {
                var da = (IDictionary)a; var db = (IDictionary)b;
                var ka = new List<string>(); foreach (var k in da.Keys) ka.Add(Convert.ToString(k)); ka.Sort(StringComparer.Ordinal);
                var kb = new List<string>(); foreach (var k in db.Keys) kb.Add(Convert.ToString(k)); kb.Sort(StringComparer.Ordinal);
                int c = Compare(ka, kb); if (c != 0) return c;
                foreach (var k in ka) { c = Compare(da[k], db[k]); if (c != 0) return c; }
                return 0;
            }
            default: return 0;
        }
    }
    // Stable sort: returns the item indexes ordered by key (ties keep input order, like jq sort_by)
    public static int[] SortIndex(object[] keys) {
        var idx = new int[keys.Length];
        for (int i = 0; i < idx.Length; i++) idx[i] = i;
        Array.Sort(idx, (x, y) => { int c = Compare(keys[x], keys[y]); return c != 0 ? c : x.CompareTo(y); });
        return idx;
    }
}
'@
}
# Get-JqTypeRank: jq's type order used when comparing values of different types
function Get-JqTypeRank { param($V) return [PcrJqOrder]::Rank($V) }
# Compare-JqValue: jq's total order (-1 / 0 / 1); see PcrJqOrder above
function Compare-JqValue { param($A, $B) return [PcrJqOrder]::Compare($A, $B) }
# Get-JqSortedBy: jq sort_by(f) - stable; $Key is a scriptblock that gets the item as $args[0] (or $_)
function Get-JqSortedBy {
    param([AllowNull()][object[]]$Items, [scriptblock]$Key)
    if ($null -eq $Items -or $Items.Count -eq 0) { return , @() }
    $n = $Items.Count
    $keys = [object[]]::new($n)
    for ($i = 0; $i -lt $n; $i++) { $it = $Items[$i]; $keys[$i] = & $Key $it }
    $idx = [PcrJqOrder]::SortIndex($keys)
    $out = [object[]]::new($n)
    for ($i = 0; $i -lt $n; $i++) { $out[$i] = $Items[$idx[$i]] }
    return , $out
}
# Group-JqBy: jq group_by(f) - sorted by the key, adjacent equal keys grouped; returns an array of arrays
function Group-JqBy {
    param([AllowNull()][object[]]$Items, [scriptblock]$Key)
    $sorted = Get-JqSortedBy $Items $Key
    $groups = [System.Collections.Generic.List[object]]::new()
    $cur = $null; $curKey = $null; $first = $true
    foreach ($it in $sorted) {
        $k = & $Key $it
        if ($first -or (Compare-JqValue $k $curKey) -ne 0) {
            if (-not $first) { $groups.Add($cur.ToArray()) }
            $cur = [System.Collections.Generic.List[object]]::new(); $curKey = $k; $first = $false
        }
        $cur.Add($it)
    }
    if (-not $first) { $groups.Add($cur.ToArray()) }
    return , $groups.ToArray()
}
# Get-JqUniqueBy: jq unique_by(f) - first item of each key group, in key order
function Get-JqUniqueBy {
    param([AllowNull()][object[]]$Items, [scriptblock]$Key)
    $out = [System.Collections.Generic.List[object]]::new()   # a List: a single array item is never unrolled
    foreach ($g in (Group-JqBy $Items $Key)) { $out.Add($g[0]) }
    return , $out.ToArray()
}
# Get-JqUnique: jq unique (sorted, duplicates removed)
function Get-JqUnique {
    param([AllowNull()][object[]]$Items)
    return , (Get-JqUniqueBy $Items { param($x) $x })
}
# Get-JqMax / Get-JqMin: jq max / min of an array (null when empty)
function Get-JqMax { param([AllowNull()][object[]]$Items) $m = $null; $f = $true; foreach ($x in $Items) { if ($f -or (Compare-JqValue $x $m) -ge 0) { $m = $x; $f = $false } }; return $m }
function Get-JqMin { param([AllowNull()][object[]]$Items) $m = $null; $f = $true; foreach ($x in $Items) { if ($f -or (Compare-JqValue $x $m) -lt 0) { $m = $x; $f = $false } }; return $m }
# ConvertTo-JqArray: always an object[] (never $null, never unrolled into a scalar)
function ConvertTo-JqArray { param([AllowNull()]$V) if ($null -eq $V) { return , @() } return , @($V) }

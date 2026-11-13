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
    return , (ConvertFrom-JqJson ([System.IO.File]::ReadAllText($Path)))
}

# ---------------------------------------------------------------------------------------------- print
# Format-JqNumber: jq 1.7 number text (integral -> digits; else shortest round-trip; exponent as 1E+17)
function Format-JqNumber {
    param($N)
    if ($N -is [long] -or $N -is [int] -or $N -is [int16] -or $N -is [byte] -or $N -is [uint32] -or $N -is [uint64]) { return ([long]$N).ToString($script:Inv) }
    $d = [double]$N
    if ([double]::IsNaN($d)) { return 'null' }
    if ([double]::IsInfinity($d)) { if ($d -gt 0) { return '1.7976931348623157e+308' } else { return '-1.7976931348623157e+308' } }
    if ([Math]::Floor($d) -eq $d -and [Math]::Abs($d) -lt 1e17) { return ([long]$d).ToString($script:Inv) }
    $s = $d.ToString('R', $script:Inv)
    if ($s -match '^(-?)(\d)(?:\.(\d+))?E([+-])(\d+)$') {   # 1E+20 style like jq; small exponents print as decimals in jq
        $exp = [int]$Matches[5]; if ($Matches[4] -eq '-' -and $exp -le 5) { return $d.ToString('0.###################', $script:Inv) }
        return "$($Matches[1])$($Matches[2])$(if ($Matches[3]) { '.' + $Matches[3] })E$($Matches[4])$('{0:00}' -f $exp)"
    }
    return $s
}
# ConvertTo-JqString: a JSON string literal escaped like jq (", \, control chars, DEL; non-ASCII stays raw)
function ConvertTo-JqString {
    param([AllowNull()][AllowEmptyString()][string]$S)
    $sb = [System.Text.StringBuilder]::new($S.Length + 2)
    [void]$sb.Append('"')
    foreach ($c in $S.ToCharArray()) {
        switch ([int]$c) {
            34 { [void]$sb.Append('\"') } 92 { [void]$sb.Append('\\') }
            10 { [void]$sb.Append('\n') } 9 { [void]$sb.Append('\t') } 13 { [void]$sb.Append('\r') }
            8 { [void]$sb.Append('\b') } 12 { [void]$sb.Append('\f') }
            default {
                if ([int]$c -lt 32 -or [int]$c -eq 127) { [void]$sb.AppendFormat('\u{0:x4}', [int]$c) } else { [void]$sb.Append($c) }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}
# Test-JqNumber / Test-JqArray / Test-JqObject: jq type checks on PowerShell values
function Test-JqNumber { param($V) return ($V -is [long] -or $V -is [int] -or $V -is [double] -or $V -is [decimal] -or $V -is [single]) }
function Test-JqObject { param($V) return ($V -is [System.Collections.IDictionary]) }
function Test-JqArray { param($V) return ($null -ne $V -and $V -isnot [string] -and $V -isnot [System.Collections.IDictionary] -and $V -is [System.Collections.IEnumerable]) }

# ConvertTo-JqJson: value -> JSON text. -Compact = jq -c / tojson; default = jq's 2-space pretty print
function ConvertTo-JqJson {
    param([AllowNull()]$Value, [switch]$Compact)
    $sb = [System.Text.StringBuilder]::new()
    Write-JqJsonValue $sb $Value 0 $Compact.IsPresent
    return $sb.ToString()
}
# Write-JqJsonValue: recursive writer behind ConvertTo-JqJson
function Write-JqJsonValue {
    param([System.Text.StringBuilder]$Sb, $V, [int]$Level, [bool]$Compact)
    if ($null -eq $V) { [void]$Sb.Append('null'); return }
    if ($V -is [bool]) { [void]$Sb.Append($(if ($V) { 'true' } else { 'false' })); return }
    if ($V -is [string]) { [void]$Sb.Append((ConvertTo-JqString $V)); return }
    if (Test-JqNumber $V) { [void]$Sb.Append((Format-JqNumber $V)); return }
    if ($V -is [System.Collections.IDictionary]) {
        if ($V.Count -eq 0) { [void]$Sb.Append('{}'); return }
        [void]$Sb.Append('{'); $first = $true
        foreach ($k in $V.Keys) {
            if (-not $first) { [void]$Sb.Append(',') }; $first = $false
            if (-not $Compact) { [void]$Sb.Append("`n").Append(' ' * (2 * ($Level + 1))) }
            [void]$Sb.Append((ConvertTo-JqString ([string]$k))).Append($(if ($Compact) { ':' } else { ': ' }))
            Write-JqJsonValue $Sb $V[$k] ($Level + 1) $Compact
        }
        if (-not $Compact) { [void]$Sb.Append("`n").Append(' ' * (2 * $Level)) }
        [void]$Sb.Append('}'); return
    }
    if ($V -is [System.Collections.IEnumerable]) {
        $items = @($V)
        if ($items.Count -eq 0) { [void]$Sb.Append('[]'); return }
        [void]$Sb.Append('['); $first = $true
        foreach ($x in $items) {
            if (-not $first) { [void]$Sb.Append(',') }; $first = $false
            if (-not $Compact) { [void]$Sb.Append("`n").Append(' ' * (2 * ($Level + 1))) }
            Write-JqJsonValue $Sb $x ($Level + 1) $Compact
        }
        if (-not $Compact) { [void]$Sb.Append("`n").Append(' ' * (2 * $Level)) }
        [void]$Sb.Append(']'); return
    }
    if ($V -is [datetime]) { [void]$Sb.Append((ConvertTo-JqString ($V.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'+00:00'", $script:Inv)))); return }
    [void]$Sb.Append((ConvertTo-JqString ([string]$V)))
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
# Get-JqTypeRank: jq's type order used when comparing values of different types
function Get-JqTypeRank {
    param($V)
    if ($null -eq $V) { return 0 }
    if ($V -is [bool]) { if ($V) { return 2 } else { return 1 } }
    if (Test-JqNumber $V) { return 3 }
    if ($V -is [string]) { return 4 }
    if ($V -is [System.Collections.IDictionary]) { return 6 }
    return 5
}
# Compare-JqValue: jq's total order (-1 / 0 / 1). Strings compare by code point, arrays element-wise
# (a shorter prefix sorts first), objects by sorted key list and then by values.
function Compare-JqValue {
    param($A, $B)
    $ra = Get-JqTypeRank $A; $rb = Get-JqTypeRank $B
    if ($ra -ne $rb) { return [Math]::Sign($ra - $rb) }
    switch ($ra) {
        3 { $x = [double]$A; $y = [double]$B; if ($x -lt $y) { return -1 } elseif ($x -gt $y) { return 1 } else { return 0 } }
        4 { return [Math]::Sign([string]::CompareOrdinal([string]$A, [string]$B)) }
        5 {
            $xa = @($A); $xb = @($B); $n = [Math]::Min($xa.Count, $xb.Count)
            for ($i = 0; $i -lt $n; $i++) { $c = Compare-JqValue $xa[$i] $xb[$i]; if ($c -ne 0) { return $c } }
            return [Math]::Sign($xa.Count - $xb.Count)
        }
        6 {
            $ka = [string[]]@($A.Keys); [Array]::Sort($ka, [System.StringComparer]::Ordinal)
            $kb = [string[]]@($B.Keys); [Array]::Sort($kb, [System.StringComparer]::Ordinal)
            $c = Compare-JqValue $ka $kb; if ($c -ne 0) { return $c }
            foreach ($k in $ka) { $c = Compare-JqValue $A[$k] $B[$k]; if ($c -ne 0) { return $c } }
            return 0
        }
        default { return 0 }
    }
}
# Sort-JqBy: jq sort_by(f) - stable; $Key is a scriptblock that gets the item as $args[0] (or $_)
function Sort-JqBy {
    param([AllowNull()][object[]]$Items, [scriptblock]$Key)
    if ($null -eq $Items -or $Items.Count -eq 0) { return , @() }
    $n = $Items.Count
    $keys = [object[]]::new($n)
    for ($i = 0; $i -lt $n; $i++) { $it = $Items[$i]; $keys[$i] = & $Key $it }
    $idx = [int[]](0..($n - 1))
    $cmp = [System.Comparison[int]] { param($a, $b) $c = Compare-JqValue $keys[$a] $keys[$b]; if ($c -ne 0) { return $c }; return $a.CompareTo($b) }
    [Array]::Sort($idx, $cmp)
    $out = [object[]]::new($n)
    for ($i = 0; $i -lt $n; $i++) { $out[$i] = $Items[$idx[$i]] }
    return , $out
}
# Group-JqBy: jq group_by(f) - sorted by the key, adjacent equal keys grouped; returns an array of arrays
function Group-JqBy {
    param([AllowNull()][object[]]$Items, [scriptblock]$Key)
    $sorted = Sort-JqBy $Items $Key
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

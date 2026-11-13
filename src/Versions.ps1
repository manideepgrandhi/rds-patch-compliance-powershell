# src/Versions.ps1 - engine-version parsing and minor-upgrade candidate selection.
# A line-by-line port of lib/versions.jq (shared by the Bash tools) plus derive_major from lib/compliance.jq.
# Same rules: digit runs compare as numbers (15.10 > 15.9, 3.05.2 = 3.5.2), letter runs as lower-case text,
# Oracle versions compare by RU date / patch line date / revision, and a target only counts inside the same
# major line (and, for Oracle, the same patch line unless -OracleAnyPatchLine).

# ConvertTo-JqNumberOrNull: jq "tonumber?" (a number, or $null when the text is not numeric)
function ConvertTo-JqNumberOrNull {
    param([AllowNull()]$S)
    if ($null -eq $S) { return $null }
    if (Test-JqNumber $S) { return $S }
    $t = [string]$S
    if ($t -match '^\s*-?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?\s*$') { return [double]::Parse($t.Trim(), $script:Inv) }
    return $null
}

# Get-VersionKey (jq vkey): "15.10" -> 15, 10 ; "19.0.0.0.ru-2024-01.rur-2024-01.r1" -> numbers and lower-case words
function Get-VersionKey {
    param([AllowNull()]$Version)
    $s = ConvertTo-JqText $Version
    $out = foreach ($m in [regex]::Matches($s, '[0-9]+|[A-Za-z]+')) {
        if ($m.Value -match '^[0-9]+$') { [double]$m.Value } else { $m.Value.ToLowerInvariant() }
    }
    return , @($out)
}

# Get-OracleVersionInfo (jq ora_parse): <major>.0.0.0.ru-<YYYY-MM>[.<line>-<YYYY-MM | N>].r<N>
# -> @{major; ru=[y,m]; line = none | rur | mrp | spb | <word>; line_key=[numbers]; rev} or $null when unknown
function Get-OracleVersionInfo {
    param([AllowNull()]$Version)
    if ($null -eq $Version) { return $null }
    $m = [regex]::Match([string]$Version, '^(?<maj>[0-9]+)\.0\.0\.0\.ru-(?<ry>[0-9]{4})-(?<rm>[0-9]{2})(\.(?<lt>[a-z]+)-(?<ld>[0-9]+(-[0-9]+)?))?\.r(?<rev>[0-9]+)$',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) { return $null }
    $lineKey = @(if ($m.Groups['ld'].Success) { [regex]::Matches($m.Groups['ld'].Value, '[0-9]+') | ForEach-Object { [double]$_.Value } })
    return @{
        major    = $m.Groups['maj'].Value
        ru       = @([double]$m.Groups['ry'].Value, [double]$m.Groups['rm'].Value)
        line     = if ($m.Groups['lt'].Success) { $m.Groups['lt'].Value.ToLowerInvariant() } else { 'none' }
        line_key = $lineKey
        rev      = [double]$m.Groups['rev'].Value
    }
}
# Get-LineLabel (jq line_label): "none" -> "plain RU"
function Get-LineLabel { param([string]$Line) if ($Line -eq 'none') { return 'plain RU' } return $Line }
# Get-OracleKey (jq ora_key): [RU year, RU month, line date..., revision] or $null
function Get-OracleKey {
    param([AllowNull()]$Version)
    $p = Get-OracleVersionInfo $Version
    if ($null -eq $p) { return $null }
    return , @(@($p.ru[0], $p.ru[1]) + @($p.line_key) + @($p.rev))
}

# Get-MajorOf (jq major_of): major line of a version string for an engine
#   postgres engines: first part (>= 10) else first two; oracle / sqlserver: first part as a number;
#   aurora-mysql: the Aurora major (8.0.mysql_aurora.3.05.2 -> 3); everything else: first two parts
function Get-MajorOf {
    param([AllowNull()]$Version, [string]$Engine)
    $v = ConvertTo-JqText $Version
    $k = $v.Split('.')
    $k1 = if ($k.Count -gt 1) { $k[1] } else { '0' }
    if ($Engine -cmatch 'postgres') {
        $n = ConvertTo-JqNumberOrNull $k[0]; if ($null -eq $n) { $n = 0 }
        if ($n -ge 10) { return $k[0] } else { return $k[0] + '.' + $k1 }
    }
    if ($Engine -cmatch '^oracle' -or $Engine -cmatch '^sqlserver') {
        $n = ConvertTo-JqNumberOrNull $k[0]
        if ($null -ne $n) { return (Format-JqNumber $n) } else { return $k[0] }
    }
    if ($Engine -eq 'aurora-mysql') {
        $m = [regex]::Match($v, 'mysql_aurora\.(?<a>[0-9]+)')
        if ($m.Success) { return $m.Groups['a'].Value }
        if ($k.Count -eq 3) { return $k[0] } else { return $k[0] + '.' + $k1 }
    }
    return $k[0] + '.' + $k1
}
# Get-DerivedMajor (jq derive_major in compliance.jq): major line when AWS no longer lists the version
function Get-DerivedMajor {
    param([AllowNull()]$Version, [string]$Engine)
    $k = (ConvertTo-JqText $Version).Split('.')
    $k1 = if ($k.Count -gt 1) { $k[1] } else { '0' }
    if ($Engine -cmatch 'postgres') {
        $n = ConvertTo-JqNumberOrNull $k[0]; if ($null -eq $n) { $n = 0 }
        if ($n -ge 10) { return $k[0] } else { return $k[0] + '.' + $k1 }
    }
    if ($Engine -cmatch '^oracle') { return $k[0] }
    return $k[0] + '.' + $k1
}
# Get-VersionOrderKey (jq ver_key): ordering key inside one major / patch line
function Get-VersionOrderKey {
    param([AllowNull()]$Version, [string]$Engine)
    if ($Engine -cmatch '^oracle') { $k = Get-OracleKey $Version; if ($null -ne $k) { return , $k } }
    return , (Get-VersionKey $Version)
}

# Select-MinorTarget (jq minor_select): choose the minor upgrade candidates from ValidUpgradeTarget[]
#   -> @{targets = [objects, oldest first]; versions = [...]; excluded = [{version, reason}]; warnings = [...]}
function Select-MinorTarget {
    param([AllowNull()][object[]]$Targets, [string]$Engine, [string]$Current, [AllowNull()]$CurrentMajor, [bool]$AnyLine)
    $ora = $Engine -cmatch '^oracle'
    $cmajP = Get-MajorOf $Current $Engine
    $cp = if ($ora) { Get-OracleVersionInfo $Current } else { $null }
    $cand = @(foreach ($t in @($Targets)) {
            if ($t -isnot [System.Collections.IDictionary]) { continue }
            $isMaj = Get-JqField $t 'IsMajorVersionUpgrade'; if ($null -eq $isMaj) { $isMaj = $false }
            $eng = Get-JqField $t 'Engine'; if ($null -eq $eng) { $eng = $Engine }
            $ev = Get-JqField $t 'EngineVersion'; if ($null -eq $ev) { $ev = '' }
            if ((Compare-JqValue $isMaj $false) -eq 0 -and (Compare-JqValue $eng $Engine) -eq 0 -and (Compare-JqValue $ev '') -ne 0) { , $t }
        })
    $cand = Get-JqUniqueBy $cand { param($x) , @(Get-JqField $x 'EngineVersion') }
    $sel = [System.Collections.Generic.List[object]]::new()
    $excluded = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $cand) {
        $v = $t['EngineVersion']; $tmaj = Get-MajorOf $v $Engine
        $tp = if ($ora) { Get-OracleVersionInfo $v } else { $null }
        $tMajorField = Get-JqField $t 'MajorEngineVersion'
        $d = @{}
        if ($tmaj -cne $cmajP) { $d.x = "excluded $v (different major version $tmaj; current is $cmajP)" }
        elseif ($null -ne $CurrentMajor -and $null -ne $tMajorField -and (Compare-JqValue $tMajorField $CurrentMajor) -ne 0) {
            $d.x = "excluded $v (different major version $(ConvertTo-JqText $tMajorField); current is $(ConvertTo-JqText $CurrentMajor))"
        }
        elseif ($ora -and ($null -eq $cp -or $null -eq $tp)) {
            $d.w = "oracle version format not recognised ($(if ($null -eq $cp) { $Current } else { $v })); generic compare used"
            $d.k = Get-VersionKey $v; $d.ck = Get-VersionKey $Current
        }
        elseif ($ora -and -not $AnyLine -and $tp.line -cne $cp.line) {
            $d.x = "excluded $v (different patch line $(Get-LineLabel $tp.line); current is $(Get-LineLabel $cp.line))"
        }
        elseif ($ora) { $d.k = Get-OracleKey $v; $d.ck = Get-OracleKey $Current; $d.xl = ($tp.line -cne $cp.line) }
        else { $d.k = Get-VersionKey $v; $d.ck = Get-VersionKey $Current }
        if ($d.ContainsKey('x')) { $excluded.Add((New-JqObject ([ordered]@{ version = $v; reason = $d.x }))); continue }
        if ($d.ContainsKey('w')) { $warnings.Add($d.w) }
        $c = Compare-JqValue $d.k $d.ck
        if ($c -gt 0 -or ($c -eq 0 -and $d.xl -eq $true)) { $sel.Add(@{ k = $d.k; t = $t }) }
    }
    $sorted = Sort-JqBy $sel.ToArray() { param($x) , @($x.k, $x.t['EngineVersion']) }
    $targetsOut = @(foreach ($x in $sorted) { , $x.t })
    return @{
        targets  = $targetsOut
        versions = @(foreach ($t in $targetsOut) { $t['EngineVersion'] })
        excluded = $excluded.ToArray()
        warnings = Get-JqUnique $warnings.ToArray()
    }
}

# Compare-EngineVersion (jq vcmp_e): -1 / 0 / 1 for two versions of one engine
function Compare-EngineVersion {
    param([string]$Engine, $A, $B)
    if ($Engine -cmatch '^oracle' -and ($null -eq (Get-OracleKey $A) -or $null -eq (Get-OracleKey $B))) {
        return (Compare-JqValue (Get-VersionKey $A) (Get-VersionKey $B))
    }
    return (Compare-JqValue (Get-VersionOrderKey $A $Engine) (Get-VersionOrderKey $B $Engine))
}
# Compare-VersionGeneric (jq vcmp in compliance.jq): generic -1 / 0 / 1
function Compare-VersionGeneric { param($A, $B) return (Compare-JqValue (Get-VersionKey $A) (Get-VersionKey $B)) }

# Get-LatestVersion (jq latest_of): highest version of a list; Oracle: one per patch line ("mrp: <v>; plain RU: <v>")
function Get-LatestVersion {
    param([AllowNull()][object[]]$Versions, [string]$Engine)
    $vs = Get-JqUnique @($Versions | Where-Object { $null -ne $_ })
    if ($vs.Count -eq 0) { return $null }
    if ($Engine -cmatch '^oracle') {
        $groups = Group-JqBy $vs { param($x) $p = Get-OracleVersionInfo $x; , @($(if ($null -eq $p) { '?' } else { $p.line })) }
        $tops = @(foreach ($g in $groups) { $s = Sort-JqBy $g { param($x) , (Get-VersionOrderKey $x $Engine) }; $s[-1] })
        if ($tops.Count -eq 1) { return $tops[0] }
        return (@(foreach ($t in $tops) {
                    $p = Get-OracleVersionInfo $t
                    $(if ($null -eq $p) { 'unrecognised format' } else { Get-LineLabel $p.line }) + ': ' + $t
                }) -join '; ')
    }
    $s = Sort-JqBy $vs { param($x) , (Get-VersionKey $x) }
    return $s[-1]
}

# src/Summary.ps1 - renderers for Invoke-RdsPatchComplianceSummary.ps1 (port of lib/summary.jq).
# Input: the finalized report (same object the full report prints with -Format json), so the numbers are
# identical to the full report. Modes: text | html | csv_nc | csv_summary | csv_regions | csv_accounts | alert.

$script:SummaryName = 'Invoke-RdsPatchComplianceSummary.ps1'
$script:SummaryVersion = '1.0.0'

# summary pad / rpad: like jq, NO truncation (the full report's pad truncates; this one never does)
function Format-SPad { param([AllowNull()]$V, [int]$N) $s = ConvertTo-JqText $V; if ($s.Length -ge $N) { return $s } return $s + (' ' * ($N - $s.Length)) }
function Format-SRPad { param([AllowNull()]$V, [int]$N) $s = ConvertTo-JqText $V; if ($s.Length -ge $N) { return $s } return (' ' * ($N - $s.Length)) + $s }
# Get-SGKey (jq gkey): members of one Aurora global database sort together
function Get-SGKey { param($R) $g = Get-JqField $R 'global_cluster'; if ($null -ne $g -and $g -ne '') { return "$($R['account_id'])|$g" } return "$($R['account_id'])|$($R['region'])|$($R['identifier'])" }
# Get-SGText (jq gtxt): "global-id (role)" / "unknown" / ""
function Get-SGText {
    param($R)
    $g = Get-JqField $R 'global_cluster'
    if ($null -ne $g -and $g -ne '') { return "$g ($(ConvertTo-JqText $R['global_role']))" }
    if ((Get-JqField $R 'global_role') -eq 'unknown') { return 'unknown' }
    return ''
}
# Get-SVb: versions_behind, 0 when unknown (jq: .versions_behind // 0)
function Get-SVb { param($R) $v = Get-JqField $R 'versions_behind'; if (Test-JqTruthy $v) { return $v } return [long]0 }
# Get-SNcRows (jq nc_rows): NON-COMPLIANT rows; worst global group first, primary first, most behind first
function Get-SNcRows {
    param($Rep)
    $nc = @($Rep['rows'] | Where-Object { $_['compliance_status'] -eq 'NON-COMPLIANT' })
    $gm = @{}
    foreach ($x in $nc) { $k = Get-SGKey $x; $old = if ($gm.ContainsKey($k)) { $gm[$k] } else { [long]0 }; $gm[$k] = Get-JqMax @($old, (Get-SVb $x)) }
    return , (Get-JqSortedBy $nc { param($r) $k = Get-SGKey $r; , @((-$gm[$k]), $k, $(if ((Get-JqField $r 'global_role') -eq 'primary') { [long]0 } else { [long]1 }), (-(Get-SVb $r)), (ConvertTo-AsciiLower $r['identifier']), $r['account_id'], $r['region']) })
}
# Get-SUnkRows (jq unk_rows)
function Get-SUnkRows {
    param($Rep)
    return , (Get-JqSortedBy @($Rep['rows'] | Where-Object { $_['compliance_status'] -eq 'UNKNOWN' }) { param($r) , @((ConvertTo-AsciiLower $r['identifier']), $r['account_id'], $r['region']) })
}
# Get-SWhy (jq why): first note part (jq: "" splits to [] -> null -> "null", kept as is)
function Get-SWhy {
    param($R)
    if (Test-JqTruthy (Get-JqField $R 'deprecated_version')) { return 'current version not returned by RDS (deprecated / not offered in region)' }
    $n = [string]$R['note']
    if ($n -eq '') { return $null }
    $first = $n.Split('; ')[0]
    if ($first -eq '') { return 'lookup failed' }
    return $first
}
# Get-SRule / Get-SAccts: the rule sentence and the "account (profile)" list of the summary header
function Get-SRule { param($S) return "NON-COMPLIANT when the current version is more than $($S['max_behind']) valid minor versions behind the latest ($($S['max_behind'] + 1) or more); counted from RDS ValidUpgradeTarget (same major; Oracle: same patch line)" }
function Get-SAccts { param($Rep) return (@($Rep['meta']['accounts'] | ForEach-Object { "$($_['account']) ($($_['profile']))" }) -join ', ') }
# Get-SRo (jq ro): region overview, or a default for old reports
function Get-SRo {
    param($Rep)
    $ro = Get-JqField $Rep['summary'] 'region_overview'
    if (Test-JqTruthy $ro) { return $ro }
    return (New-JqObject ([ordered]@{ checked = [long]@($Rep['meta']['regions']).Count; with_databases = [long]0; empty = [long]0; error = [long]0; empty_regions = @(); mode = 'explicit' }))
}
# Get-SRegionLine: "N checked, N with databases, ..." plus how regions were chosen
function Get-SRegionLine {
    param($Ro)
    $suffix = @{ discover = ' (discovery probe)'; full = ' (all scanned in full, -NoDiscover)'; explicit = ''; merge = ' (merged from saved data)' }[[string]$Ro['mode']]
    return "$($Ro['checked']) checked, $($Ro['with_databases']) with databases, $($Ro['empty']) empty, $($Ro['error']) error$(if ($Ro['error'] -eq 1) { '' } else { 's' })" + [string]$suffix
}
# Small jq-def ports used by the renderers: merged?, account rows, source state, merge line, shown regions,
# percent text / CSS class, latest-minor text, text length, x // 0, and T = jq string interpolation
function Test-SMerged { param($Rep) return ($null -ne (Get-JqField $Rep['meta'] 'merge')) }
function Get-SAcctRows { param($Rep) $a = Get-JqField $Rep['summary'] 'accounts'; if (Test-JqTruthy $a) { return , @($a) } return , @() }
function Get-SSrcState { param($X) $u = @($X['used']).Count; $s = @($X['superseded']).Count; if ($u -gt 0 -and $s -eq 0) { 'used' } elseif ($u -eq 0) { 'superseded (newer data used)' } else { 'partly used' } }
function Get-SMergeLine { param($Rep) return "$($Rep['meta']['merge']['files']) file(s), offline (0 AWS calls); days counted from $($Rep['meta']['generated_utc'])" }
function Get-SShownRegions { param($Rep) $r = Get-JqField $Rep['summary'] 'regions'; return , @(@($r) | Where-Object { $null -ne $_ -and $_['status'] -ne 'empty' }) }
function Get-SPctText { param($P) if ($null -eq $P) { return '-' } return "$(ConvertTo-JqText $P)%" }
function Get-SPctClass { param($P) if ($null -eq $P) { '' } elseif ($P -ge 100) { 'ok' } elseif ($P -ge 80) { 'warn' } else { 'bad' } }
function Get-SLatest { param($M) $l = Get-JqField $M 'latest_minor'; if (-not (Test-JqTruthy $l)) { $l = '-' }; return ([string]$l).Replace('; ', ' | ') }
function Get-SLen { param($V) if ($null -eq $V) { return 0 } return (ConvertTo-JqText $V).Length }
function Get-SOr0 { param($V) if (Test-JqTruthy $V) { return $V } return [long]0 }
function T { param([AllowNull()]$V) return (ConvertTo-JqText $V) }

# ConvertTo-SummaryText (jq text)
function ConvertTo-SummaryText {
    param($Rep)
    $s = $Rep['summary']; $m = $Rep['meta']; $nc = Get-SNcRows $Rep; $uk = Get-SUnkRows $Rep; $ro = Get-SRo $Rep
    $ew = [Math]::Max(6, [long](Get-JqMax @(@($s['engines']) | ForEach-Object { Get-SLen $_['engine'] }) ?? 6)) + 2
    $L = [System.Collections.Generic.List[string]]::new()
    $L.Add('RDS PATCH COMPLIANCE - SUMMARY')
    $L.Add("Run      : $(T $m['generated_utc']) / $(T $m['generated_local'])")
    if (Test-SMerged $Rep) { $L.Add("Merged   : $(Get-SMergeLine $Rep); accounts $(Get-SAccts $Rep)") }
    else {
        $line = "Scanned  : accounts $(Get-SAccts $Rep)" + $(if ($ro['mode'] -eq 'explicit') { "; regions $(@($m['regions']) -join ', ')" } else { '; all enabled regions' })
        if ($m['filters_text'] -ne '') { $line += "; filters: $(T $m['filters_text'])" }
        $L.Add($line)
    }
    $L.Add('Rule     : ' + (Get-SRule $s)); $L.Add('')
    $L.Add("Regions  : $(Get-SRegionLine $ro)"); $L.Add('')
    $L.Add("OVERALL  : $(T $s['total']) servers/clusters | COMPLIANT $(T $s['compliant']) | NON-COMPLIANT $(T $s['non_compliant']) | UNKNOWN $(T $s['unknown']) | $(T $s['pct_compliant'])% compliant")
    $gu = Get-SOr0 (Get-JqField $s 'global_unknown')
    $L.Add("GLOBAL   : Global databases: $(T (Get-SOr0 (Get-JqField $s 'global_databases'))) ($(T (Get-SOr0 (Get-JqField $s 'global_members'))) members)" + $(if ($gu -gt 0) { "; $(T $gu) Aurora cluster(s) global unknown (lookup failed / old data)" } else { '' }))
    $L.Add(''); $L.Add('PER ACCOUNT')
    $L.Add('  ' + (Format-SPad 'ACCOUNT' 14) + (Format-SPad 'NAME' 14) + (Format-SPad 'COLLECTED' 22) + (Format-SRPad 'REGIONS' 8) + (Format-SRPad 'TOTAL' 6) + (Format-SRPad 'COMPL' 7) + (Format-SRPad 'NON-C' 7) + (Format-SRPad 'UNKN' 6) + (Format-SRPad '%COMPL' 8) + (Format-SRPad 'PEND' 6))
    foreach ($a in (Get-SAcctRows $Rep)) {
        $L.Add('  ' + (Format-SPad $a['account_id'] 14) + (Format-SPad (Get-JqDash $a['profile']) 14) + (Format-SPad (Get-JqDash (Get-JqField $a 'collected_utc')) 22) + (Format-SRPad $a['regions_with_databases'] 8) +
            (Format-SRPad $a['total'] 6) + (Format-SRPad $a['compliant'] 7) + (Format-SRPad $a['non_compliant'] 7) + (Format-SRPad $a['unknown'] 6) + (Format-SRPad (Get-SPctText $a['pct_compliant']) 8) + (Format-SRPad $a['with_pending'] 6) +
            $(if ($a['errors'] -gt 0) { "  $(T $a['errors']) AWS error(s)" } else { '' }))
    }
    $L.Add(''); $L.Add('PER REGION')
    $L.Add('  ' + (Format-SPad 'ACCOUNT' 14) + (Format-SPad 'REGION' 16) + (Format-SRPad 'TOTAL' 6) + (Format-SRPad 'COMPL' 7) + (Format-SRPad 'NON-C' 7) + (Format-SRPad 'UNKN' 6) + (Format-SRPad '%COMPL' 8) + (Format-SRPad 'PEND' 6))
    $rt = Get-JqField $s 'regions_total'
    foreach ($x in @((Get-SShownRegions $Rep) + @($(if ($null -ne $rt) { , $rt })))) {
        $L.Add('  ' + (Format-SPad $x['account_id'] 14) + (Format-SPad $x['region'] 16) + (Format-SRPad $x['total'] 6) + (Format-SRPad $x['compliant'] 7) + (Format-SRPad $x['non_compliant'] 7) + (Format-SRPad $x['unknown'] 6) +
            (Format-SRPad (Get-SPctText $x['pct_compliant']) 8) + (Format-SRPad $x['with_pending'] 6) + $(if ($x['status'] -eq 'error') { '  AWS error - see ERRORS' } else { '' }))
    }
    $L.Add(''); $L.Add('PER ENGINE')
    $L.Add('  ' + (Format-SPad 'ENGINE' $ew) + (Format-SPad 'MAJOR' 8) + (Format-SRPad 'TOTAL' 6) + (Format-SRPad 'COMPL' 7) + (Format-SRPad 'NON-C' 7) + (Format-SRPad 'UNKN' 6) + (Format-SRPad '  %COMPL' 9) + '  LATEST MINOR')
    foreach ($e in @($s['engines'])) {
        $L.Add('  ' + (Format-SPad $e['engine'] $ew) + (Format-SPad 'all' 8) + (Format-SRPad $e['total'] 6) + (Format-SRPad $e['compliant'] 7) + (Format-SRPad $e['non_compliant'] 7) + (Format-SRPad $e['unknown'] 6) + (Format-SRPad "$(T $e['pct_compliant'])%" 9))
        foreach ($j in @($e['majors'])) {
            $L.Add('  ' + (Format-SPad '' $ew) + (Format-SPad $j['major'] 8) + (Format-SRPad $j['total'] 6) + (Format-SRPad $j['compliant'] 7) + (Format-SRPad $j['non_compliant'] 7) + (Format-SRPad $j['unknown'] 6) + (Format-SRPad '' 9) + '  ' + (Get-SLatest $j))
        }
    }
    $L.Add('')
    $L.Add("KEY FLAGS: past standard support (Extended Support charges) $(T $s['past_standard_support']) | standard support ending within $(T $s['warn_days']) days $(T $s['nearing_end_of_support']) | auto minor upgrade off $(T $s['auto_minor_off']) | pending maintenance $(T $s['with_pending'])" + $(if ($s['errors'] -gt 0) { " | AWS errors $(T $s['errors'])" } else { '' }))
    $L.Add('')
    if ($nc.Count -eq 0) { $L.Add("*** All servers compliant (no server is more than $(T $s['max_behind']) minor versions behind) ***") }
    else {
        $L.Add("!!! NON-COMPLIANT SERVERS ($($nc.Count)) - most behind first")
        $rw = Get-JqMax @($nc | ForEach-Object { Get-SLen $_['region'] }); $gw = Get-JqMax @($nc | ForEach-Object { Get-SLen $_['engine'] }); $iw = Get-JqMax @($nc | ForEach-Object { Get-SLen $_['identifier'] })
        $cv = { param($r) "$(T $r['current_version']) -> $(Get-JqDash $r['latest_minor_version'])" }
        $vw = Get-JqMax @($nc | ForEach-Object { (& $cv $_).Length })
        $L.Add('   ' + (Format-SPad 'ACCOUNT' 14) + (Format-SPad 'REGION' ($rw + 2)) + (Format-SPad 'ENGINE' ($gw + 2)) + (Format-SPad 'IDENTIFIER' ($iw + 2)) + (Format-SPad 'CURRENT -> LATEST MINOR' ($vw + 2)) + 'BEHIND  SUPPORT  GLOBAL DB')
        foreach ($r in $nc) {
            $L.Add('!! ' + (Format-SPad $r['account_id'] 14) + (Format-SPad $r['region'] ($rw + 2)) + (Format-SPad $r['engine'] ($gw + 2)) + (Format-SPad $r['identifier'] ($iw + 2)) +
                (Format-SPad (& $cv $r) ($vw + 2)) + (Format-SRPad $r['versions_behind'] 6) + '  ' + (Format-SPad $r['support_flag'] 7) + '  ' + (Get-SGText $r))
        }
    }
    if ($uk.Count -gt 0) {
        $L.Add(''); $L.Add("UNKNOWN ($($uk.Count))")
        foreach ($r in $uk) { $L.Add("?  $(T $r['account_id'])  $(T $r['region'])  $(T $r['engine'])  $(T $r['identifier'])  $(T $r['current_version']): $(T (Get-SWhy $r))") }
    }
    if (Test-SMerged $Rep) {
        $L.Add(''); $L.Add("MERGED INPUTS ($(T $m['merge']['files']))")
        foreach ($x in @($m['merge']['sources'])) { $L.Add("   $(T $x['file'])  collected $(T $x['collected_utc'])  account(s) $((@($x['used']) + @($x['superseded'])) -join ', ')  $(Get-SSrcState $x)") }
    }
    if (@($Rep['errors']).Count -gt 0) {
        $L.Add(''); $L.Add('ERRORS')
        foreach ($x in @($Rep['errors'])) { $L.Add("   $(T $x['profile'])/$(T $x['region']): $(T $x['call']): $(T $x['message'])") }
    }
    $L.Add(''); $L.Add('Read-only summary; full per-server details: Invoke-RdsPatchCompliance.ps1')
    return ($L -join "`n") + "`n"
}

# New-SCard (jq card)
function New-SCard { param($L, $V, $Cls, $Sub) return "<div class=`"card $Cls`"><div class=`"v`">$(Hx $V)</div><div class=`"l`">$(Hx $L)</div><div class=`"s`">$(Hx $Sub)</div></div>" }
function Get-SBad { param($N) if ($N -gt 0) { 'bad' } else { '' } }

# ConvertTo-SummaryHtml (jq html): one offline page, inline CSS + a tiny sort script
function ConvertTo-SummaryHtml {
    param($Rep)
    $s = $Rep['summary']; $m = $Rep['meta']; $nc = Get-SNcRows $Rep; $uk = Get-SUnkRows $Rep; $ro = Get-SRo $Rep
    $sb = [System.Text.StringBuilder]::new()
    $emit = { param($t) [void]$sb.Append($t) }
    & $emit "<!DOCTYPE html><html lang=`"en`"><head><meta charset=`"utf-8`"><title>RDS patch compliance summary - $(Hx $m['generated_utc'])</title><style>"
    & $emit 'body{font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;margin:0;background:#f5f6f8;color:#1f2933}header{background:#232f3e;color:#fff;padding:16px 26px}header h1{margin:0;font-size:21px}header p{margin:4px 0 0;color:#c9d1d9;font-size:13px}'
    & $emit 'main{padding:16px 26px;max-width:1300px}.rule{background:#fff;border-left:4px solid #232f3e;padding:8px 12px;font-size:13px;margin-bottom:14px}'
    & $emit '.cards{display:flex;flex-wrap:wrap;gap:12px;margin-bottom:16px}.card{background:#fff;border-radius:10px;padding:12px 16px;min-width:140px;box-shadow:0 1px 3px rgba(0,0,0,.12);border-top:4px solid #9aa5b1}.card .v{font-size:26px;font-weight:700}.card .l{font-size:13px;font-weight:600}.card .s{font-size:12px;color:#52606d}'
    & $emit '.card.ok{border-color:#2e7d32}.card.bad{border-color:#c62828}.card.bad .v{color:#c62828}.card.warn{border-color:#e08a00}.card.unk{border-color:#7b8794}'
    & $emit 'table{border-collapse:collapse;background:#fff;font-size:13px;box-shadow:0 1px 3px rgba(0,0,0,.12);margin-bottom:18px}th{background:#e9edf2;text-align:left;padding:6px 9px}td{padding:6px 9px;border-top:1px solid #e6e9ee}'
    & $emit 'td.n{text-align:right}.mono{font-family:SFMono-Regular,Consolas,monospace;font-size:12px}tr.eng td{font-weight:700;background:#f8f9fb}td.bad{color:#c62828;font-weight:700}td.ok{color:#2e7d32}'
    & $emit 'table.nc{border:2px solid #c62828}table.nc th{background:#c62828;color:#fff}table.nc tr td{background:#fdecea}h2{font-size:16px;margin:16px 0 6px}h2.bad{color:#c62828}'
    & $emit '.allok{background:#e6f4ea;color:#1b5e20;border:2px solid #2e7d32;border-radius:8px;padding:12px 16px;font-weight:700;margin-bottom:16px}footer{padding:8px 26px 22px;color:#7b8794;font-size:12px}'
    & $emit 'table.sortable th{cursor:pointer}td.warn{color:#b26a00;font-weight:600}tfoot td{border-top:2px solid #232f3e;background:#f0f3f7;font-weight:600}h2 .sub{font-size:12px;font-weight:400;color:#52606d}'
    & $emit '.err{background:#fdecea;color:#c62828;border-radius:8px;padding:1px 6px;font-size:11px;font-weight:600}</style></head><body>'
    & $emit "<header><h1>RDS patch compliance - summary</h1><p>$(Hx $m['generated_utc']) &middot; $(Hx $m['generated_local']) &middot; accounts $(Hx (Get-SAccts $Rep)) &middot; Regions: $(Hx (Get-SRegionLine $ro))$(if (Test-SMerged $Rep) { " &middot; merged from $(T $m['merge']['files']) file(s)" })$(if ($m['filters_text'] -ne '') { ' &middot; filters: ' + (Hx $m['filters_text']) })</p></header><main>"
    & $emit "<div class=`"rule`"><b>Rule:</b> $(Hx (Get-SRule $s))</div><div class=`"cards`">"
    $gu = Get-SOr0 (Get-JqField $s 'global_unknown')
    & $emit (New-SCard 'Servers / clusters' $s['total'] '' "$(@($m['accounts']).Count) account(s), $(@($m['regions']).Count) region(s)")
    & $emit (New-SCard '% compliant' "$(T $s['pct_compliant'])%" $(if ($s['non_compliant'] -gt 0) { 'warn' } else { 'ok' }) 'of all servers')
    & $emit (New-SCard 'Compliant' $s['compliant'] 'ok' "<= $(T $s['max_behind']) behind")
    & $emit (New-SCard 'Non-compliant' $s['non_compliant'] $(if ($s['non_compliant'] -gt 0) { 'bad' } else { 'ok' }) ">= $(T ($s['max_behind'] + 1)) behind")
    & $emit (New-SCard 'Unknown' $s['unknown'] 'unk' 'lookup failed / deprecated')
    & $emit (New-SCard 'Past standard support' $s['past_standard_support'] $(if ($s['past_standard_support'] -gt 0) { 'bad' } else { 'ok' }) 'Extended Support charges')
    & $emit (New-SCard 'Support ending' $s['nearing_end_of_support'] $(if ($s['nearing_end_of_support'] -gt 0) { 'warn' } else { 'ok' }) "within $(T $s['warn_days']) days")
    & $emit (New-SCard 'Auto minor upgrade off' $s['auto_minor_off'] $(if ($s['auto_minor_off'] -gt 0) { 'warn' } else { 'ok' }) 'incl. mixed clusters')
    & $emit (New-SCard 'Global databases' (Get-SOr0 (Get-JqField $s 'global_databases')) $(if ($gu -gt 0) { 'unk' } else { '' }) ("$(T (Get-SOr0 (Get-JqField $s 'global_members'))) members" + $(if ($gu -gt 0) { ", $(T $gu) unknown" } else { '' })))
    & $emit (New-SCard 'Pending maintenance' $s['with_pending'] $(if ($s['with_pending'] -gt 0) { 'warn' } else { 'ok' }) 'servers with actions')
    & $emit ((New-SCard 'Regions with databases' "$(T $ro['with_databases']) / $(T $ro['checked'])" $(if ($ro['error'] -gt 0) { 'bad' } else { '' }) "$(T $ro['empty']) empty, $(T $ro['error']) error(s)") + '</div>')
    if ($nc.Count -eq 0) { & $emit "<div class=`"allok`">All servers compliant - no server is more than $(T $s['max_behind']) minor versions behind.</div>" }
    else {
        & $emit "<h2 class=`"bad`">Non-compliant servers ($($nc.Count)) - most behind first</h2><table class=`"nc`"><tr><th>Account</th><th>Region</th><th>Engine</th><th>Identifier</th><th>Current &rarr; latest minor</th><th>Behind</th><th>Support</th><th>Global DB</th></tr>"
        foreach ($r in $nc) { & $emit "<tr><td>$(Hx $r['account_id'])</td><td>$(Hx $r['region'])</td><td>$(Hx $r['engine'])</td><td><b>$(Hx $r['identifier'])</b></td><td class=`"mono`">$(Hx $r['current_version']) &rarr; $(Hx (Get-JqDash $r['latest_minor_version']))</td><td class=`"n bad`">$(T $r['versions_behind'])</td><td>$(Hx $r['support_flag'])</td><td>$(Hx (Get-SGText $r))</td></tr>" }
        & $emit '</table>'
    }
    & $emit "<h2>Per account <span class=`"sub`">$(@($m['accounts']).Count) account(s) &middot; click a header to sort</span></h2><table class=`"sortable`" id=`"accounts`"><thead><tr><th>Account</th><th>Name</th><th>Collected</th><th>Regions with DBs</th><th>Total</th><th>Compliant</th><th>Non-compliant</th><th>Unknown</th><th>% compliant</th><th>Pending maint.</th><th>Past standard support</th></tr></thead><tbody>"
    foreach ($a in (Get-SAcctRows $Rep)) {
        $src = Get-JqField $a 'source'
        $pd = $a['pct_compliant']; $ds = if ($null -ne $pd) { T $pd } else { '-1' }
        & $emit "<tr><td><b>$(Hx $a['account_id'])</b></td><td>$(Hx (Get-JqDash $a['profile']))</td><td>$(Hx (Get-JqDash (Get-JqField $a 'collected_utc')))$(if (Test-JqTruthy $src) { '<br><span class="sub">' + (Hx $src) + '</span>' })</td><td class=`"n`">$(T $a['regions_with_databases'])</td><td class=`"n`">$(T $a['total'])</td><td class=`"n ok`">$(T $a['compliant'])</td><td class=`"n $(Get-SBad $a['non_compliant'])`">$(T $a['non_compliant'])</td><td class=`"n`">$(T $a['unknown'])</td><td class=`"n $(Get-SPctClass $pd)`" data-s=`"$ds`">$(Get-SPctText $pd)</td><td class=`"n $(if ($a['with_pending'] -gt 0) { 'warn' })`">$(T $a['with_pending'])</td><td class=`"n $(Get-SBad $a['past_standard_support'])`">$(T $a['past_standard_support'])</td></tr>"
    }
    & $emit '</tbody></table>'
    & $emit "<h2>Per region <span class=`"sub`">$(Hx (Get-SRegionLine $ro)) &middot; click a header to sort</span></h2><table class=`"sortable`"><thead><tr><th>Account</th><th>Region</th><th>Total</th><th>Compliant</th><th>Non-compliant</th><th>Unknown</th><th>% compliant</th><th>Pending maint.</th></tr></thead><tbody>"
    foreach ($x in (Get-SShownRegions $Rep)) {
        $pd = $x['pct_compliant']; $ds = if ($null -ne $pd) { T $pd } else { '-1' }
        & $emit "<tr><td>$(Hx $x['account_id'])</td><td><b>$(Hx $x['region'])</b>$(if ($x['status'] -eq 'error') { ' <span class="err">AWS error</span>' })</td><td class=`"n`">$(T $x['total'])</td><td class=`"n ok`">$(T $x['compliant'])</td><td class=`"n $(Get-SBad $x['non_compliant'])`">$(T $x['non_compliant'])</td><td class=`"n`">$(T $x['unknown'])</td><td class=`"n $(Get-SPctClass $pd)`" data-s=`"$ds`">$(Get-SPctText $pd)</td><td class=`"n $(if ($x['with_pending'] -gt 0) { 'warn' })`">$(T $x['with_pending'])</td></tr>"
    }
    & $emit '</tbody>'
    $rt = Get-JqField $s 'regions_total'
    if ($null -ne $rt) { & $emit "<tfoot><tr><td><b>All regions</b></td><td></td><td class=`"n`">$(T $rt['total'])</td><td class=`"n ok`">$(T $rt['compliant'])</td><td class=`"n $(Get-SBad $rt['non_compliant'])`">$(T $rt['non_compliant'])</td><td class=`"n`">$(T $rt['unknown'])</td><td class=`"n $(Get-SPctClass $rt['pct_compliant'])`">$(Get-SPctText $rt['pct_compliant'])</td><td class=`"n`">$(T $rt['with_pending'])</td></tr></tfoot>" }
    & $emit '</table>'
    & $emit '<h2>Per engine and major version</h2><table><tr><th>Engine</th><th>Major</th><th>Total</th><th>Compliant</th><th>Non-compliant</th><th>Unknown</th><th>% compliant</th><th>Latest minor</th></tr>'
    foreach ($e in @($s['engines'])) {
        & $emit "<tr class=`"eng`"><td>$(Hx $e['engine'])</td><td>all</td><td class=`"n`">$(T $e['total'])</td><td class=`"n ok`">$(T $e['compliant'])</td><td class=`"n $(Get-SBad $e['non_compliant'])`">$(T $e['non_compliant'])</td><td class=`"n`">$(T $e['unknown'])</td><td class=`"n`">$(T $e['pct_compliant'])%</td><td></td></tr>"
        foreach ($j in @($e['majors'])) { & $emit "<tr><td></td><td>$(Hx $j['major'])</td><td class=`"n`">$(T $j['total'])</td><td class=`"n ok`">$(T $j['compliant'])</td><td class=`"n $(Get-SBad $j['non_compliant'])`">$(T $j['non_compliant'])</td><td class=`"n`">$(T $j['unknown'])</td><td></td><td class=`"mono`">$(Hx (Get-SLatest $j))</td></tr>" }
    }
    & $emit '</table>'
    if ($uk.Count -gt 0) {
        & $emit "<h2>Unknown ($($uk.Count))</h2><table><tr><th>Account</th><th>Region</th><th>Engine</th><th>Identifier</th><th>Current</th><th>Why</th></tr>"
        foreach ($r in $uk) { & $emit "<tr><td>$(Hx $r['account_id'])</td><td>$(Hx $r['region'])</td><td>$(Hx $r['engine'])</td><td>$(Hx $r['identifier'])</td><td class=`"mono`">$(Hx $r['current_version'])</td><td>$(Hx (Get-SWhy $r))</td></tr>" }
        & $emit '</table>'
    }
    if (Test-SMerged $Rep) {
        & $emit "<h2>Merged inputs <span class=`"sub`">$(Hx (Get-SMergeLine $Rep))</span></h2><table id=`"sources`"><tr><th>File</th><th>Collected</th><th>Account(s)</th><th>Used</th><th>Script</th></tr>"
        foreach ($x in @($m['merge']['sources'])) {
            $cl = Get-JqField $x 'collected_local'; if (-not (Test-JqTruthy $cl)) { $cl = '' }
            $sv = Get-JqField $x 'script_version'; if (-not (Test-JqTruthy $sv)) { $sv = '?' }
            & $emit "<tr><td class=`"mono`">$(Hx $x['file'])</td><td>$(Hx $x['collected_utc'])<br><span class=`"sub`">$(Hx $cl)</span></td><td>$(Hx ((@($x['used']) + @($x['superseded'])) -join ', '))</td><td>$(Hx (Get-SSrcState $x))</td><td>v$(Hx $sv)</td></tr>"
        }
        & $emit '</table>'
    }
    if (@($Rep['errors']).Count -gt 0) { & $emit ('<h2>Errors</h2><ul>' + ((@($Rep['errors']) | ForEach-Object { "<li>$(Hx $_['profile'])/$(Hx $_['region']): $(Hx $_['call']): $(Hx $_['message'])</li>" }) -join '') + '</ul>') }
    & $emit "</main><script>(function(){Array.prototype.forEach.call(document.querySelectorAll('table.sortable'),function(t){var hs=t.tHead.rows[0].cells;"
    & $emit "Array.prototype.forEach.call(hs,function(th,i){var asc=false;th.title='Sort';th.addEventListener('click',function(){asc=!asc;var b=t.tBodies[0];"
    & $emit "var rs=Array.prototype.slice.call(b.rows);rs.sort(function(x,y){var a=x.cells[i],c=y.cells[i];var p=a.getAttribute('data-s')||a.textContent.trim(),q=c.getAttribute('data-s')||c.textContent.trim();"
    & $emit "var m=parseFloat(p),n=parseFloat(q);var r=(!isNaN(m)&&!isNaN(n)&&/^-?[0-9.]+%?$/.test(p)&&/^-?[0-9.]+%?$/.test(q))?m-n:p.localeCompare(q);return asc?r:-r;});"
    & $emit "rs.forEach(function(r){b.appendChild(r);});});});});})();</script><footer>$script:SummaryName v$(Hx $script:SummaryVersion) &middot; read-only; numbers from Invoke-RdsPatchCompliance.ps1 v$(Hx $m['version'])</footer></body></html>"
    return $sb.ToString() + "`n"
}

# CSV renderers (jq csv_nc / csv_summary / csv_regions / csv_accounts); each line ends in LF like jq -r
function Join-SCsv { param([object[]]$Lines) return (($Lines | ForEach-Object { ConvertTo-JqCsvLine $_ }) -join "`n") + "`n" }
# ConvertTo-SummaryCsvNc (jq csv_nc): NON-COMPLIANT servers, one row each
function ConvertTo-SummaryCsvNc {
    param($Rep)
    $cols = 'account_id', 'profile', 'region', 'engine', 'identifier', 'resource_type', 'major_version', 'current_version', 'latest_minor_version', 'versions_behind', 'support_flag', 'auto_minor_upgrade', 'pending_actions_count', 'global_cluster', 'global_role'
    return Join-SCsv (@(, [object[]]$cols) + @(foreach ($r in (Get-SNcRows $Rep)) { , [object[]]@(foreach ($c in $cols) { Get-JqField $r $c }) }))
}
# ConvertTo-SummaryCsvSummary (jq csv_summary): overall, per engine, per major, and the flag counts
function ConvertTo-SummaryCsvSummary {
    param($Rep)
    $s = $Rep['summary']
    $l = @(, [object[]]@('scope', 'engine', 'major', 'total', 'compliant', 'non_compliant', 'unknown', 'pct_compliant', 'latest_minor'))
    $l += , [object[]]@('overall', '', '', $s['total'], $s['compliant'], $s['non_compliant'], $s['unknown'], $s['pct_compliant'], '')
    foreach ($e in @($s['engines'])) {
        $l += , [object[]]@('engine', $e['engine'], '', $e['total'], $e['compliant'], $e['non_compliant'], $e['unknown'], $e['pct_compliant'], '')
        foreach ($j in @($e['majors'])) { $lm = Get-JqField $j 'latest_minor'; $l += , [object[]]@('major', $e['engine'], $j['major'], $j['total'], $j['compliant'], $j['non_compliant'], $j['unknown'], '', $(if (Test-JqTruthy $lm) { $lm } else { '' })) }
    }
    $l += , [object[]]@('flag', 'past_standard_support', '', $s['past_standard_support'], '', '', '', '', '')
    $l += , [object[]]@('flag', "nearing_end_of_support_$(T $s['warn_days'])d", '', $s['nearing_end_of_support'], '', '', '', '', '')
    $l += , [object[]]@('flag', 'auto_minor_upgrade_off', '', $s['auto_minor_off'], '', '', '', '', '')
    $l += , [object[]]@('flag', 'pending_maintenance', '', $s['with_pending'], '', '', '', '', '')
    return Join-SCsv $l
}
# ConvertTo-SummaryCsvRegions (jq csv_regions): regions with databases or errors, then the total line
function ConvertTo-SummaryCsvRegions {
    param($Rep)
    $l = @(, [object[]]@('account_id', 'profile', 'region', 'status', 'total', 'compliant', 'non_compliant', 'unknown', 'pct_compliant', 'servers_with_pending_maintenance', 'pending_actions', 'aws_errors'))
    $rt = Get-JqField $Rep['summary'] 'regions_total'
    foreach ($x in @((Get-SShownRegions $Rep) + @($(if ($null -ne $rt) { , $rt })))) {
        $p = $x['pct_compliant']; if ($null -eq $p) { $p = '' }
        $l += , [object[]]@($x['account_id'], $x['profile'], $x['region'], $x['status'], $x['total'], $x['compliant'], $x['non_compliant'], $x['unknown'], $p, $x['with_pending'], $x['pending_total'], $x['errors'])
    }
    return Join-SCsv $l
}
# ConvertTo-SummaryCsvAccounts (jq csv_accounts): one line per account
function ConvertTo-SummaryCsvAccounts {
    param($Rep)
    $l = @(, [object[]]@('account_id', 'profile', 'collected_utc', 'source_file', 'regions_with_databases', 'total', 'compliant', 'non_compliant', 'unknown', 'pct_compliant', 'servers_with_pending_maintenance', 'past_standard_support', 'aws_errors'))
    foreach ($a in (Get-SAcctRows $Rep)) {
        $p = $a['pct_compliant']; if ($null -eq $p) { $p = '' }
        $src = Get-JqField $a 'source'; if (-not (Test-JqTruthy $src)) { $src = '' }
        $l += , [object[]]@($a['account_id'], $a['profile'], (Get-JqField $a 'collected_utc'), $src, $a['regions_with_databases'], $a['total'], $a['compliant'], $a['non_compliant'], $a['unknown'], $p, $a['with_pending'], $a['past_standard_support'], $a['errors'])
    }
    return Join-SCsv $l
}
# Get-SummaryAlertData (jq alert): webhook "json" payload body
function Get-SummaryAlertData {
    param($Rep)
    $s = $Rep['summary']; $ro = Get-SRo $Rep
    $pick = { param($o, [string[]]$k) $x = New-JqObject; foreach ($n in $k) { $x[$n] = Get-JqField $o $n }; , $x }
    $mf = Get-JqField (Get-JqField $Rep['meta'] 'merge') 'files'
    return (New-JqObject ([ordered]@{
                summary       = (& $pick $s @('total', 'compliant', 'non_compliant', 'unknown', 'pct_compliant', 'max_behind', 'errors'))
                regions       = (& $pick $ro @('checked', 'with_databases', 'empty', 'error'))
                accounts      = @(foreach ($a in (Get-SAcctRows $Rep)) { , (& $pick $a @('account_id', 'profile', 'total', 'compliant', 'non_compliant', 'unknown', 'pct_compliant')) })
                merged_files  = $(if (Test-JqTruthy $mf) { $mf } else { $null })
                non_compliant = @(foreach ($r in (Get-SNcRows $Rep)) { , (& $pick $r @('account_id', 'region', 'engine', 'identifier', 'current_version', 'latest_minor_version', 'versions_behind', 'support_flag', 'global_cluster', 'global_role')) })
            }))
}

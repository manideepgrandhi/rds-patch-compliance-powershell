# src/Render.ps1 - report output: text | csv (+ region csv) | json | html | alert payload.
# Port of the rendering modes of lib/compliance.jq. The HTML uses the SAME CSS, sort script and page script
# as the Bash report (assets/report.css, assets/report_sort.js, assets/compliance_page.js), so it looks and
# behaves the same: filters, clickable cards, engine table, search and offline CSV export.

$script:Cols = @('account_id', 'profile', 'region', 'resource_type', 'identifier', 'members', 'engine', 'major_version', 'current_version', 'latest_minor_version',
    'versions_behind', 'newer_versions', 'default_auto_upgrade_target', 'compliance_status', 'auto_minor_upgrade', 'standard_support_end', 'extended_support_end', 'support_flag',
    'pending_actions_count', 'pending_actions', 'deprecated_version', 'maint_window_utc', 'maint_window_ist')
$script:ExtraCols = @('next_maintenance', 'days_until_maintenance', 'global_cluster', 'global_role', 'account_name')

# ---------------------------------------------------------------------------------------------- text helpers
# Format-Pad (jq pad): left-aligned, cut to $N; Format-RPad (jq rpad): right-aligned, never cut
function Format-Pad { param([AllowNull()]$V, [int]$N) $s = ConvertTo-JqText $V; if ($s.Length -ge $N) { return $s.Substring(0, $N) } return $s + (' ' * ($N - $s.Length)) }
function Format-RPad { param([AllowNull()]$V, [int]$N) $s = ConvertTo-JqText $V; if ($s.Length -ge $N) { return $s } return (' ' * ($N - $s.Length)) + $s }
# Format-ShortList (jq short_list): at most 4 versions, else "a, b, c, ... +N (latest x)"
function Format-ShortList {
    param([AllowNull()][object[]]$L)
    $L = @($L)
    if ($L.Count -eq 0) { return '-' }
    if ($L.Count -le 4) { return ($L -join ', ') }
    return (($L[0..2]) -join ', ') + ", ... +$($L.Count - 3) (latest $($L[-1]))"
}
# Get-RegionLine (jq region_line): "N checked, N with databases, N empty, N errors"
function Get-RegionLine { param($Ro) return "$($Ro['checked']) checked, $($Ro['with_databases']) with databases, $($Ro['empty']) empty, $($Ro['error']) error$(if ($Ro['error'] -eq 1) { '' } else { 's' })" }
# Get-RegionModeText (jq region_mode_txt)
function Get-RegionModeText {
    param($Ro)
    switch ($Ro['mode']) {
        'discover' { return "discovery probe, $(ConvertTo-JqText $Ro['probe_parallel']) in parallel; full scan only where databases or a probe error" }
        'full' { return 'every enabled region scanned in full (--no-discover)' }
        'explicit' { return 'queried directly, no probe' }
        'merge' { return 'merged offline from saved data' }
        default { return (ConvertTo-JqText $Ro['mode']) }
    }
}
# Get-ShownRegions (jq shown_regions): regions with databases or an error (empty ones are only counted)
function Get-ShownRegions { param($R) return , @($R['summary']['regions'] | Where-Object { $_['status'] -ne 'empty' }) }
# Get-PendSummary (jq pend_summary)
function Get-PendSummary {
    param($S)
    $x = @(foreach ($k in $S['pending_by_action'].Keys) { "$k $($S['pending_by_action'][$k])" }) -join ', '
    if ($x -eq '') { $x = 'none' }
    return "on $($S['with_pending']) server(s): $x"
}
# Get-AccountLabel: "name (number)" or the number
function Get-AccountLabel { param($Name, $Id) if ($null -ne $Name -and $Name -ne '') { return "$Name ($Id)" } return [string]$Id }

# ---------------------------------------------------------------------------------------------- text
# ConvertTo-PcrText (jq mode text): the plain-text report
function ConvertTo-PcrText {
    param($R)
    $s = $R['summary']; $ro = $s['region_overview']; $rows = @($R['rows'])
    $vw = (@(12) + @(foreach ($x in $rows) { (ConvertTo-JqText $x['current_version']).Length; (ConvertTo-JqText $x['latest_minor_version']).Length }) | Measure-Object -Maximum).Maximum + 2
    $ew = (@(20) + @(foreach ($e in $s['engines']) { ([string]$e['engine']).Length }) | Measure-Object -Maximum).Maximum + 2
    $L = [System.Collections.Generic.List[string]]::new()
    $L.Add("RDS PATCH COMPLIANCE REPORT - $($R['meta']['generated_utc']) ($($R['meta']['generated_local']))")
    $acc = @(foreach ($a in $R['meta']['accounts']) { "$($a['account'])$(if ((Get-JqField $a 'name') -and $a['name'] -ne '') { ' ' + $a['name'] } else { '' }) ($($a['profile']))" }) -join ', '
    $tail = if ($ro['mode'] -eq 'explicit') { "   Regions: $(@($R['meta']['regions']).Count) given" } elseif ($ro['mode'] -eq 'merge') { "   Merged: $($R['meta']['merge']['files']) file(s)" } else { '   Regions: all enabled' }
    $L.Add("Accounts : $acc$tail")
    $L.Add("Regions  : $(Get-RegionLine $ro)")
    $L.Add("Rule     : NON-COMPLIANT when more than $($s['max_behind']) valid minor versions behind (same major)")
    if ((Get-JqField $R['meta'] 'filters_text') -and $R['meta']['filters_text'] -ne '') { $L.Add("Filters  : $($R['meta']['filters_text'])") }
    $L.Add('')
    $L.Add('SUMMARY')
    $L.Add("  Servers/clusters : $($s['total'])   COMPLIANT $($s['compliant'])   NON-COMPLIANT $($s['non_compliant'])   UNKNOWN $($s['unknown'])   -> $(ConvertTo-JqText $s['pct_compliant'])% compliant")
    $L.Add("  Support          : $($s['past_standard_support']) past standard support (Extended Support charges), $($s['nearing_end_of_support']) ending within $($s['warn_days']) days")
    $L.Add('  Pending maint.   : ' + $(if ($s['with_pending'] -eq 0) { 'none' } else { (Get-PendSummary $s) + " ($($s['pending_total']) action(s))" }))
    $L.Add("  Global databases : $($s['global_databases']) ($($s['global_members']) members)" + $(if ($s['global_unknown'] -gt 0) { "; $($s['global_unknown']) Aurora cluster(s) with unknown membership" } else { '' }))
    $L.Add("  Other flags      : auto minor upgrade off $($s['auto_minor_off']), current version not returned / deprecated $($s['deprecated'])")
    if ($s['errors'] -gt 0) { $L.Add("  AWS errors       : $($s['errors']) (see ERRORS at the end; affected regions may be missing)") }
    $L.Add('')
    $L.Add('PER ENGINE / MAJOR VERSION')
    $L.Add('  ' + (Format-Pad 'ENGINE' $ew) + (Format-Pad 'MAJOR' 10) + (Format-RPad 'TOTAL' 6) + (Format-RPad 'COMPL' 7) + (Format-RPad 'NON-C' 7) + (Format-RPad 'UNKN' 6) + '  ' + (Format-Pad 'LATEST MINOR' $vw) + 'SUPPORT')
    foreach ($e in $s['engines']) {
        foreach ($m in $e['majors']) {
            $lmin = Get-JqDash $m['latest_minor']
            $line = '  ' + (Format-Pad $e['engine'] $ew) + (Format-Pad $m['major'] 10) + (Format-RPad $m['total'] 6) + (Format-RPad $m['compliant'] 7) + (Format-RPad $m['non_compliant'] 7) + (Format-RPad $m['unknown'] 6) + '  ' +
            $(if ($lmin.Contains('; ')) { Format-Pad 'per patch line, below' $vw } else { Format-Pad $lmin $vw }) + (Get-JqDash $m['support_flag']) +
            $(if ($null -ne $m['standard_support_end']) { " (standard end $($m['standard_support_end']))" } else { '' })
            $lm = if (Test-JqTruthy $m['latest_minor']) { [string]$m['latest_minor'] } else { '' }
            if ($lm.Contains('; ')) { $line += "`n" + (@($lm.Split('; ') | ForEach-Object { '        latest minor, ' + $_ }) -join "`n") }
            $L.Add($line)
        }
    }
    foreach ($e in $s['engines']) {
        $L.Add('  ' + (Format-Pad $e['engine'] $ew) + (Format-Pad 'all' 10) + (Format-RPad $e['total'] 6) + (Format-RPad $e['compliant'] 7) + (Format-RPad $e['non_compliant'] 7) + (Format-RPad $e['unknown'] 6) + "  $(ConvertTo-JqText $e['pct_compliant'])% compliant")
    }
    $L.Add('')
    if ($s['global_databases'] -gt 0) {
        $L.Add('GLOBAL DATABASES')
        foreach ($g in $s['globals']) {
            $L.Add("  $($g['global_cluster']) [$($g['engine'])] account $($g['account_id']): $($g['overall_status'])" + $(if ($g['region_status_mismatch']) { '  ** region status mismatch **' } else { '' }) + $(if ($g['version_differs']) { "  (versions differ: $(@($g['versions']) -join ', '))" } else { '' }))
            foreach ($m in $g['members']) {
                $L.Add('      ' + (Format-Pad $m['role'] 10) + (Format-Pad $m['region'] 16) + (Format-Pad $m['identifier'] 32) + (Format-Pad (Get-JqDash $m['current_version']) $vw) + $m['compliance_status'] +
                    $(if ($m['headless'] -eq $true) { ' (headless)' } else { '' }) + $(if ($null -ne $m['versions_behind']) { ", $($m['versions_behind']) behind" } else { '' }))
            }
            foreach ($p in @($g['pending'])) { if ($null -ne $p) { $L.Add('      pending: ' + $p) } }
        }
        $L.Add('')
    }
    $L.Add('PER REGION')
    $L.Add('  ' + (Format-Pad 'ACCOUNT' 14) + (Format-Pad 'REGION' 16) + (Format-Pad 'STATUS' 11) + (Format-RPad 'TOTAL' 6) + (Format-RPad 'COMPL' 7) + (Format-RPad 'NON-C' 7) + (Format-RPad 'UNKN' 6) + (Format-RPad '%COMPL' 8) + (Format-RPad 'PEND' 6) + (Format-RPad 'PAST-STD' 10))
    foreach ($x in (Get-ShownRegions $R) + @(, $s['regions_total'])) {
        $L.Add('  ' + (Format-Pad $x['account_id'] 14) + (Format-Pad $x['region'] 16) + (Format-Pad $x['status'] 11) + (Format-RPad $x['total'] 6) + (Format-RPad $x['compliant'] 7) + (Format-RPad $x['non_compliant'] 7) + (Format-RPad $x['unknown'] 6) +
            (Format-RPad $(if ($null -eq $x['pct_compliant']) { '-' } else { "$(ConvertTo-JqText $x['pct_compliant'])%" }) 8) + (Format-RPad $x['with_pending'] 6) + (Format-RPad $x['past_standard_support'] 10) +
            $(if ($x['status'] -eq 'error') { '  see ERRORS' + $(if ($x['total'] -eq 0) { ' (no data)' } else { ' (partial)' }) } else { '' }))
    }
    $L.Add('')
    $L.Add('PER ACCOUNT')
    $L.Add('  ' + (Format-Pad 'ACCOUNT' 14) + (Format-Pad 'PROFILE' 16) + (Format-Pad 'COLLECTED' 22) + (Format-RPad 'REG' 4) + (Format-RPad 'TOTAL' 6) + (Format-RPad 'COMPL' 7) + (Format-RPad 'NON-C' 7) + (Format-RPad 'UNKN' 6) + (Format-RPad '%COMPL' 8) + (Format-RPad 'PEND' 6) + '  NAME')
    foreach ($x in $s['accounts']) {
        $L.Add('  ' + (Format-Pad $x['account_id'] 14) + (Format-Pad $x['profile'] 16) + (Format-Pad $x['collected_utc'] 22) + (Format-RPad $x['regions_with_databases'] 4) + (Format-RPad $x['total'] 6) + (Format-RPad $x['compliant'] 7) + (Format-RPad $x['non_compliant'] 7) + (Format-RPad $x['unknown'] 6) +
            (Format-RPad $(if ($null -eq $x['pct_compliant']) { '-' } else { "$(ConvertTo-JqText $x['pct_compliant'])%" }) 8) + (Format-RPad $x['with_pending'] 6) + '  ' + (Get-JqDash $x['account_name']))
    }
    $L.Add('')
    foreach ($e in $s['engines']) {
        $L.Add("=== $($e['engine']): $($e['total']) (compliant $($e['compliant']), non-compliant $($e['non_compliant']), unknown $($e['unknown'])) ===")
        $L.Add('  ' + (Format-Pad 'STATUS' 14) + (Format-RPad 'BEHIND' 6) + '  ' + (Format-Pad 'IDENTIFIER' 32) + (Format-Pad 'TYPE' 17) + (Format-Pad 'CURRENT' $vw) + (Format-Pad 'LATEST MINOR' $vw) + (Format-Pad 'AUTO' 7) + (Format-RPad 'PEND' 4) + '  ' + (Format-Pad 'ACCOUNT' 13) + (Format-Pad 'REGION' 15) + 'FLAGS')
        foreach ($x in $rows) {
            if ($x['engine'] -cne $e['engine']) { continue }
            $flags = @()
            if ($x['support_flag'] -ne 'ok' -and -not ([string]$x['support_flag']).StartsWith('n/a')) { $flags += $x['support_flag'] }
            if ($x['deprecated_version'] -eq $true) { $flags += 'current version not returned (deprecated?)' }
            $L.Add('  ' + (Format-Pad $x['compliance_status'] 14) + (Format-RPad (Get-JqDash $x['versions_behind']) 6) + '  ' + (Format-Pad $x['identifier'] 32) + (Format-Pad $x['resource_type'] 17) + (Format-Pad $x['current_version'] $vw) + (Format-Pad (Get-JqDash $x['latest_minor_version']) $vw) +
                (Format-Pad $x['auto_minor_upgrade'] 7) + (Format-RPad $x['pending_actions_count'] 4) + '  ' + (Format-Pad $x['account_id'] 13) + (Format-Pad $x['region'] 15) + (Get-JqDash ($flags -join '; ')))
            foreach ($p in @($x['pending_actions_detail'])) {
                if ($null -eq $p) { continue }
                $L.Add('      pending: ' + $p['text'] + $(if (Test-JqTruthy $p['auto_applied_after_ist']) { " [auto-apply $($p['auto_applied_after_ist'])]" } else { '' }))
            }
        }
        $L.Add('')
    }
    if ($rows.Count -eq 0) { $L.Add('No servers matched.'); $L.Add('') }
    if (@($R['errors']).Count -gt 0) {
        $L.Add('ERRORS')
        foreach ($x in $R['errors']) { $L.Add("  $($x['account']) $($x['profile'])/$($x['region']): $($x['call']): $($x['message'])") }
        $L.Add('')
    }
    $L.Add('ABOUT THIS REPORT')
    $L.Add("  Rule    : COMPLIANT = at most $($s['max_behind']) valid minor upgrade target(s) for the current version; NON-COMPLIANT = $($s['max_behind'] + 1)+; UNKNOWN = lookup failed or current version not returned (deprecated).")
    $L.Add('  Source  : ValidUpgradeTarget (IsMajorVersionUpgrade=false) of describe-db-engine-versions --engine-version <current>, per server; latest minor per major = highest valid target seen.')
    $L.Add("  Regions : $(Get-RegionModeText $ro); empty regions are only counted; PER REGION lists regions with databases or an AWS error.")
    $L.Add('  Pending : maintenance actions AWS scheduled or offered and not yet applied (clusters include member actions).')
    $L.Add('  Globals : Aurora global databases from describe-global-clusters; overall = worst member; mismatch = same version, different status across regions.')
    $L.Add('  Read-only: nothing was changed.')
    return (($L -join "`n") + "`n")
}

# ---------------------------------------------------------------------------------------------- csv / json / alert
# ConvertTo-PcrCsv (jq mode csv): one row per server/cluster, 28 columns, RFC 4180 quoting
function ConvertTo-PcrCsv {
    param($R)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append((ConvertTo-JqCsvLine ($script:Cols + $script:ExtraCols))).Append("`n")
    foreach ($x in $R['rows']) {
        $f = foreach ($c in $script:Cols) {
            $v = Get-JqField $x $c
            if (Test-JqArray $v) { (@($v) | ForEach-Object { ConvertTo-JqText $_ }) -join ' ' } elseif ($null -eq $v) { '' } else { , $v }
        }
        $f = @($f) + @(foreach ($c in $script:ExtraCols) { $v = Get-JqField $x $c; if (Test-JqTruthy $v) { , $v } else { '' } })
        [void]$sb.Append((ConvertTo-JqCsvLine $f)).Append("`n")
    }
    return $sb.ToString()
}
# ConvertTo-PcrRegionCsv (jq mode csv_regions): region-wise breakdown next to the per-server CSV
function ConvertTo-PcrRegionCsv {
    param($R)
    $map = @(@('account_id', 'account_id'), @('profile', 'profile'), @('region', 'region'), @('status', 'status'), @('total', 'total'), @('compliant', 'compliant'),
        @('non_compliant', 'non_compliant'), @('unknown', 'unknown'), @('pct_compliant', 'pct_compliant'), @('servers_with_pending_maintenance', 'with_pending'),
        @('pending_actions', 'pending_total'), @('past_standard_support', 'past_standard_support'), @('aws_errors', 'errors'),
        @('probe_instances_max20', 'probe_instances'), @('probe_clusters_max20', 'probe_clusters'))
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append((ConvertTo-JqCsvLine @($map | ForEach-Object { $_[0] }))).Append("`n")
    foreach ($x in (Get-ShownRegions $R) + @(, $R['summary']['regions_total'])) {
        $f = foreach ($m in $map) { $v = Get-JqField $x $m[1]; if ($null -eq $v) { '' } else { , $v } }
        [void]$sb.Append((ConvertTo-JqCsvLine @($f))).Append("`n")
    }
    return $sb.ToString()
}
# ConvertTo-PcrJson (jq mode json): the whole finalized report, pretty-printed like jq
function ConvertTo-PcrJson { param($R) return (ConvertTo-JqJson $R) + "`n" }
# Get-PcrAlertData (jq mode alert): summary + the NON-COMPLIANT servers + errors (webhook "json" format)
function Get-PcrAlertData {
    param($R)
    return (New-JqObject ([ordered]@{
                summary       = $R['summary']
                non_compliant = @(foreach ($x in $R['rows']) {
                        if ($x['compliance_status'] -ne 'NON-COMPLIANT') { continue }
                        New-JqObject ([ordered]@{ account_id = $x['account_id']; region = $x['region']; identifier = $x['identifier']; engine = $x['engine']
                                current_version = $x['current_version']; latest_minor_version = $x['latest_minor_version']; versions_behind = $x['versions_behind'] })
                    })
                errors        = @($R['errors'])
            }))
}

# ---------------------------------------------------------------------------------------------- html
function Get-StatusClass { param($S) switch ($S) { 'COMPLIANT' { 'ok' } 'NON-COMPLIANT' { 'bad' } 'UNKNOWN' { 'unk' } default { 'unk' } } }
function Get-SupportClass { param([string]$F) if ($F.StartsWith('past')) { 'bad' } elseif ($F.StartsWith('standard support ends')) { 'warn' } elseif ($F -eq 'ok') { 'ok' } else { 'muted' } }
function Get-RegionClass { param($S) switch ($S) { 'databases' { 'db' } 'error' { 'bad' } 'empty' { 'unk' } default { 'unk' } } }
function Get-PctClass { param($P) if ($null -eq $P) { 'muted' } elseif ($P -ge 100) { 'ok' } elseif ($P -ge 80) { 'warn' } else { 'bad' } }
function Get-RiskClass { param($N, $C) if ($N -gt 0) { $C } else { 'zero' } }
function Hx { param([AllowNull()]$V) return (ConvertTo-JqHtml $V) }
# Get-CardKey: data-k attribute (label lower-case, non-letters -> "-")
function Get-CardKey { param([string]$Label) return [regex]::Replace((ConvertTo-AsciiLower $Label), '[^a-z]+', '-') }
# New-HtmlCard (jq cardx): clickable card (role=button) with an optional icon and hover pop-up
function New-HtmlCard {
    param([string]$Label, $Val, [string]$Cls, [string]$Sub, [string]$Act, [string]$Ic, [bool]$Pop)
    $s = "<div class=`"card $Cls`" data-k=`"$(Get-CardKey $Label)`" data-act=`"$Act`" role=`"button`" tabindex=`"0`">"
    if ($Ic -ne '') { $s += "<span class=`"ic`" aria-hidden=`"true`">$Ic</span>" }
    $s += "<div class=`"v`">$(Hx $Val)</div><div class=`"l`">$(Hx $Label)</div><div class=`"s`">$(Hx $Sub)</div>"
    if ($Pop) { $s += '<div class="pop" role="tooltip"></div>' }
    return $s + '</div>'
}
# Format-DaysLeft (jq dleft)
function Format-DaysLeft { param($D) if ($null -eq $D) { '' } elseif ($D -lt 0) { "$(-$D) day(s) overdue" } elseif ($D -eq 0) { 'today' } else { "in $D day(s)" } }
# Get-PendTip (jq pend_tip): hover text with UTC = IST dates
function Get-PendTip {
    param($X)
    return (@(foreach ($p in @($X['pending_actions_detail'])) {
                if ($null -eq $p) { continue }
                $p['text'] + $(if (Test-JqTruthy $p['auto_applied_after_utc']) { " | auto-apply $($p['auto_applied_after_utc']) = $(ConvertTo-JqText $p['auto_applied_after_ist'])" } else { '' }) +
                $(if (Test-JqTruthy $p['forced_apply_utc']) { " | forced $($p['forced_apply_utc']) = $(ConvertTo-JqText $p['forced_apply_ist'])" } else { '' })
            }) -join "`n")
}
# Get-GlobalBadge (jq gbadge)
function Get-GlobalBadge {
    param($X)
    if ($X['global_role'] -eq 'unknown') { return ' <span class="gb unk" title="describe-global-clusters unavailable for this account">global: unknown</span>' }
    $gc = Get-JqField $X 'global_cluster'
    if ($null -ne $gc -and $gc -ne '') {
        return " <span class=`"gb$(if ($X['_gmm']) { ' mm' } else { '' })`" title=`"$(if ($X['_gmm']) { 'Global DB members differ (version or status across regions)' } else { 'Aurora global database' })`">global: $(Hx $gc) &middot; $(Hx $X['global_role'])$(if ($X['member_count'] -eq 0) { ' (headless)' } else { '' })</span>"
    }
    return ''
}
# ConvertTo-HtmlRow (jq html_row): one server row of the main tables
function ConvertTo-HtmlRow {
    param($X)
    $vb = $X['versions_behind']; $vbs = if ($null -eq $vb) { -1 } else { $vb }
    $s = "<tr data-i=`"$($X['_i'])`"><td><span class=`"st $(Get-StatusClass $X['compliance_status'])`">$(Hx $X['compliance_status'])</span></td><td data-s=`"$(Hx $vbs)`">$(Get-JqDash $vb)</td>"
    $s += "<td><b>$(Hx $X['identifier'])</b>" + (Get-GlobalBadge $X) + $(if ($X['members'] -ne '') { "<div class=`"sub`">$(Hx $X['members'])</div>" } else { '' }) + '</td>'
    $s += "<td>$(Hx $X['resource_type'])</td><td>$(Hx $X['major_version'])</td><td class=`"mono`">$(Hx $X['current_version'])$(if ($X['deprecated_version'] -eq $true) { ' <span class="st bad">DEPRECATED</span>' } else { '' })</td><td class=`"mono`">$(Hx (Get-JqDash $X['latest_minor_version']))</td>"
    $s += "<td class=`"mono small`">$(Hx (Format-ShortList $X['newer_versions']))</td><td class=`"mono small`">$(Hx (Get-JqDash $X['default_auto_upgrade_target']))</td>"
    $am = $X['auto_minor_upgrade']
    $s += "<td class=`"$(if ($am -eq 'true') { 'ok' } elseif ($am -eq 'unknown') { 'muted' } else { 'warn' })`">$(Hx $am)</td>"
    $s += "<td>$(Hx (Get-JqDash $X['standard_support_end']))</td><td>$(Hx (Get-JqDash $X['extended_support_end']))</td><td class=`"$(Get-SupportClass ([string]$X['support_flag']))`">$(Hx $X['support_flag'])</td>"
    $s += "<td data-s=`"$(Hx $X['pending_actions_count'])`">"
    if ($X['pending_actions_count'] -eq 0) { $s += '<span class="muted">0</span>' }
    else {
        $s += "<details class=`"pend`" title=`"$(Hx (Get-PendTip $X))`"><summary><span class=`"badge`">$(Hx $X['pending_actions_count'])</span></summary><ul>"
        foreach ($p in @($X['pending_actions_detail'])) {
            if ($null -eq $p) { continue }
            $s += "<li>$(Hx $p['text'])" + $(if (Test-JqTruthy $p['auto_applied_after_ist']) { "<div class=`"sub`">auto-apply $(Hx $p['auto_applied_after_utc']) = $(Hx $p['auto_applied_after_ist'])</div>" } else { '' }) +
            $(if (Test-JqTruthy $p['forced_apply_ist']) { "<div class=`"sub`">forced $(Hx $p['forced_apply_utc']) = $(Hx $p['forced_apply_ist'])</div>" } else { '' }) + '</li>'
        }
        $s += '</ul></details>'
        $du = $X['days_until_maintenance']
        if ($null -ne $du) { $s += "<div class=`"sub $(if ($du -lt 0) { 'bad' } elseif ($du -le 14) { 'warn' } else { '' })`">next $(Hx $X['next_maintenance']) &middot; $(Format-DaysLeft $du)</div>" }
    }
    $s += "</td><td class=`"small`">$(Hx (Get-JqDash $X['maint_window_utc'])) UTC<br>$(Hx (Get-JqDash $X['maint_window_ist'])) IST</td>"
    $s += "<td>$(Hx (Get-AccountLabel (Get-JqField $X 'account_name') $X['account_id']))<div class=`"sub`">$(Hx $X['profile']) &middot; $(Hx $X['region'])</div></td>"
    return $s + '</tr>'
}
# ConvertTo-HtmlCountCells: the shared count / % / pending / past-std cells of region and account rows
function ConvertTo-HtmlCountCells {
    param($X)
    $p = $X['pct_compliant']
    $s = "<td class=`"n`" data-s=`"$($X['total'])`"><b>$($X['total'])</b></td><td class=`"n $(if ($X['compliant'] -gt 0) { 'ok' } else { '' })`" data-s=`"$($X['compliant'])`">$($X['compliant'])</td>"
    $s += "<td class=`"n $(if ($X['non_compliant'] -gt 0) { 'bad' } else { '' })`" data-s=`"$($X['non_compliant'])`">$($X['non_compliant'])</td><td class=`"n`" data-s=`"$($X['unknown'])`">$($X['unknown'])</td>"
    $s += "<td class=`"n $(Get-PctClass $p)`" data-s=`"$(if ($null -eq $p) { '-1' } else { ConvertTo-JqText $p })`">" + $(if ($null -eq $p) { '-' } else { "$(ConvertTo-JqText $p)%<div class=`"bar`"><i class=`"$(Get-PctClass $p)`" style=`"width:$(ConvertTo-JqText $p)%`"></i></div>" }) + '</td>'
    $s += "<td class=`"n $(if ($X['with_pending'] -gt 0) { 'warn' } else { '' })`" data-s=`"$($X['with_pending'])`">$($X['with_pending'])$(if ($X['pending_total'] -gt 0) { '<div class="sub">' + (ConvertTo-JqText $X['pending_total']) + ' action(s)</div>' } else { '' })</td>"
    $s += "<td class=`"n $(if ($X['past_standard_support'] -gt 0) { 'bad' } else { '' })`" data-s=`"$($X['past_standard_support'])`">$($X['past_standard_support'])</td></tr>"
    return $s
}
# ConvertTo-HtmlRegionRow (jq region_tr)
function ConvertTo-HtmlRegionRow {
    param($X, [bool]$Foot)
    $s = "<tr$(if ($Foot) { ' class="foot"' } else { ' data-k="' + (Hx $X['account_id']) + '|' + (Hx $X['region']) + '"' })><td>$(if ($Foot) { '<b>All regions</b>' } else { (Hx (Get-AccountLabel (Get-JqField $X 'account_name') $X['account_id'])) + '<div class="sub">' + (Hx $X['profile']) + '</div>' })</td>"
    $s += "<td>$(if ($Foot) { '' } else { '<b>' + (Hx $X['region']) + '</b>' })</td>"
    $s += "<td data-s=`"$(if ($Foot) { 9 } else { Get-RegionRank $X['status'] })`">$(if ($Foot) { '' } else { '<span class="st ' + (Get-RegionClass $X['status']) + '">' + (Hx $X['status']) + '</span>' + $(if ($X['status'] -eq 'error') { '<div class="sub">see Errors' + $(if ($X['total'] -eq 0) { ', no data' } else { ', partial' }) + '</div>' } else { '' }) })</td>"
    return $s + (ConvertTo-HtmlCountCells $X)
}
# ConvertTo-HtmlAccountRow (jq account_tr)
function ConvertTo-HtmlAccountRow {
    param($X)
    $s = "<tr data-a=`"$(Hx $X['account_id'])`"><td><b>$(Hx (Get-AccountLabel (Get-JqField $X 'account_name') $X['account_id']))</b><div class=`"sub`">$(Hx $X['profile'])</div></td><td class=`"small`">$(Hx (Get-JqDash $X['collected_utc']))$(if (Test-JqTruthy $X['source']) { '<div class="sub">' + (Hx $X['source']) + '</div>' } else { '' })</td>"
    $s += "<td class=`"n`" data-s=`"$($X['regions_with_databases'])`">$($X['regions_with_databases'])$(if ($X['errors'] -gt 0) { '<div class="sub bad">' + (ConvertTo-JqText $X['errors']) + ' error(s)</div>' } else { '' })</td>"
    return $s + (ConvertTo-HtmlCountCells $X)
}
# Get-PageData (jq page_data): the JSON the in-page script reads (filters, cards, CSV export)
function Get-PageData {
    param($R)
    $accts = @($R['meta']['accounts'])
    $drop = @('pending_actions_detail', 'excluded_targets', 'version_warnings', 'tags', 'arn', 'note', 'global_arn', 'global_pending_raw', 'upgrade_command')
    $d = New-JqObject ([ordered]@{
            cols = @($script:Cols + $script:ExtraCols)
            csv_acct = $(if ($accts.Count -eq 1) { $accts[0]['account'] } else { '' })
            csv_stamp = $(($R['meta']['generated_utc'] -replace '[^0-9]', '') | ForEach-Object { $_.Substring(0, [Math]::Min(12, $_.Length)) })
            nc_only = [bool]$script:O.NcOnly
            accounts = @(foreach ($a in $accts) { New-JqObject ([ordered]@{ account = $a['account']; profile = $a['profile']; name = $(if (Test-JqTruthy (Get-JqField $a 'name')) { $a['name'] } else { '' }) }) })
            globals = @(foreach ($g in $R['summary']['globals']) { New-JqObject ([ordered]@{ a = $g['account_id']; g = $g['global_cluster'] }) })
            engines = @(foreach ($e in $R['summary']['engines']) {
                    New-JqObject ([ordered]@{ engine = $e['engine']; anchor = $e['anchor']; majors = @(foreach ($m in $e['majors']) { New-JqObject ([ordered]@{ major = $m['major']; latest_minor = $m['latest_minor']; standard_support_end = $m['standard_support_end']; support_flag = $m['support_flag'] }) }) })
                })
            rows = @(foreach ($x in $R['rows']) { $c = Copy-JqObject $x; foreach ($k in $drop) { $c.Remove($k) }; , $c })
        })
    return (ConvertTo-JqJson $d -Compact).Replace('<', '\u003c').Replace([string][char]0x2028, '\u2028').Replace([string][char]0x2029, '\u2029')
}
# ConvertTo-PcrHtml (jq mode html): the offline, single-file HTML report
function ConvertTo-PcrHtml {
    param($R)
    $s = $R['summary']; $ro = $s['region_overview']; $meta = $R['meta']; $multi = @($meta['accounts']).Count -gt 1
    $gmm = @{}; foreach ($g in $s['globals']) { if ($g['version_differs'] -or $g['region_status_mismatch']) { $gmm["$($g['account_id'])|$($g['global_cluster'])"] = $true } }
    $irows = for ($i = 0; $i -lt @($R['rows']).Count; $i++) {
        $x = Copy-JqObject $R['rows'][$i]; $x['_i'] = $i
        $gc = Get-JqField $x 'global_cluster'; $x['_gmm'] = [bool]$gmm["$($x['account_id'])|$(if ($null -ne $gc) { $gc } else { '' })"]
        , $x
    }
    $b = [System.Text.StringBuilder]::new()
    $null = $b.Append("<!DOCTYPE html><html lang=`"en`"><head><meta charset=`"utf-8`"><title>RDS patch compliance - $(Hx $meta['generated_utc'])</title><style>").Append($script:Assets.Css).Append('</style></head><body>')
    $alab = @(foreach ($a in $meta['accounts']) { if ($null -ne (Get-JqField $a 'name') -and $a['name'] -ne '') { "$($a['name']) ($($a['account']))" } else { "$($a['account']) ($($a['profile']))" } }) -join ', '
    $null = $b.Append("<header id=`"top`"><h1>RDS patch compliance report</h1><p>$(Hx $meta['generated_utc']) &middot; $(Hx $meta['generated_local']) &middot; accounts $(Hx $alab) &middot; Regions: $(Get-RegionLine $ro)$(if (Test-JqTruthy (Get-JqField $meta 'merge')) { " &middot; merged from $($meta['merge']['files']) file(s)" } else { '' })</p></header><main>")
    $null = $b.Append('<div class="toolbar" id="filters"><select id="f-acct" aria-label="Account"><option value="">All accounts</option></select><select id="f-region" aria-label="Region"><option value="">All regions</option></select>')
    $null = $b.Append('<select id="f-engine" aria-label="Engine"><option value="">All engines</option></select><select id="f-status" aria-label="Compliance status"><option value="">All statuses</option></select><span id="g-box" class="gchk"><label><input type="checkbox" id="f-gl"> Global</label><label><input type="checkbox" id="f-sa"> Standalone</label></span>')
    $null = $b.Append('<input id="q" type="search" placeholder="Search DB, account, engine, version" aria-label="Search"><select id="f-flag" aria-label="Flag"><option value="">Flag: any</option><option value="past">Extended Support</option><option value="near">Support ending</option><option value="aoff">Auto minor upgrade off</option><option value="pend">Pending maintenance</option><option value="dep">Version not returned</option></select>')
    $null = $b.Append('<button id="f-reset" type="button">Reset</button><button id="f-csv" class="pri" type="button">Export CSV</button><span class="cnt" id="f-count"></span></div>')
    $null = $b.Append('<p id="empty" class="empty" hidden>No servers match. <button type="button" id="empty-reset">Clear filters</button></p><p class="flt-note">Filtered view: cards and tables show only matching servers.</p>')
    $null = $b.Append("<p class=`"muted rule`"><b>Rule:</b> NON-COMPLIANT when more than $($s['max_behind']) valid minor versions behind (same major). <a href=`"#about`">About this report</a></p>")
    $null = $b.Append('<div class="cards stat">' + (New-HtmlCard 'Servers / clusters' $s['total'] 'c-tot' "$(@($meta['accounts']).Count) account(s), $(@($meta['regions']).Count) region(s)" 'reset' '#' $false))
    $null = $b.Append((New-HtmlCard 'Compliant' $s['compliant'] 'c-ok' "$(ConvertTo-JqText $s['pct_compliant'])% of all" 's:COMPLIANT' '✓' $false))
    $null = $b.Append((New-HtmlCard 'Non-compliant' $s['non_compliant'] 'c-bad' "> $($s['max_behind']) behind" 's:NON-COMPLIANT' '✕' $true))
    $null = $b.Append((New-HtmlCard 'Unknown' $s['unknown'] 'c-unk' 'lookup failed / not returned' 's:UNKNOWN' '?' $true) + '</div>')
    $null = $b.Append('<div class="cards risk">')
    $null = $b.Append((New-HtmlCard 'Extended Support' $s['past_standard_support'] (Get-RiskClass $s['past_standard_support'] 'bad') 'past standard support' 'f:past' '' $false))
    $null = $b.Append((New-HtmlCard 'Support ending' $s['nearing_end_of_support'] (Get-RiskClass $s['nearing_end_of_support'] 'warn') "within $($s['warn_days']) days" 'f:near' '' $false))
    $null = $b.Append((New-HtmlCard 'Auto minor upgrade off' $s['auto_minor_off'] (Get-RiskClass $s['auto_minor_off'] 'warn') 'incl. mixed clusters' 'f:aoff' '' $false))
    $pba = @(foreach ($k in $s['pending_by_action'].Keys) { "$k $($s['pending_by_action'][$k])" }) -join ', '; if ($pba -eq '') { $pba = 'none' }
    $null = $b.Append((New-HtmlCard 'Pending maintenance' $s['with_pending'] (Get-RiskClass $s['with_pending'] 'warn') $pba 'f:pend' '' $false))
    $null = $b.Append((New-HtmlCard 'Version not returned' $s['deprecated'] (Get-RiskClass $s['deprecated'] 'bad') 'deprecated / not offered' 'f:dep' '' $false))
    $mm = @($s['globals'] | Where-Object { $_['version_differs'] -or $_['region_status_mismatch'] }).Count
    $gsub = "$($s['global_members']) members" + $(if ($mm -gt 0) { " · $mm mismatched" } else { '' }) + $(if ($s['global_unknown'] -gt 0) { "; $($s['global_unknown']) unknown" } else { '' })
    $null = $b.Append((New-HtmlCard 'Global databases' $s['global_databases'] $(if ($s['global_unknown'] -gt 0) { 'warn' } else { Get-RiskClass $s['global_databases'] 'info' }) $gsub 'gl' '' $false))
    $null = $b.Append((New-HtmlCard 'Regions' "$($ro['with_databases']) / $($ro['checked'])" $(if ($ro['error'] -gt 0) { 'bad' } else { 'info' }) "with DBs; $($ro['empty']) empty, $($ro['error']) error(s)" 'scroll:regions' '' $false) + '</div>')
    $null = $b.Append('<section id="engines"><h2>Engine compliance <span class="ftag">Filtered</span><label class="tgl"><input type="checkbox" id="eng-all"> Show all majors</label></h2>')
    $null = $b.Append('<div class="escroll"><table class="eng" id="eng-tbl"><thead><tr><th data-c="e">Engine</th><th data-c="n">Servers</th><th data-c="p">% compliant</th><th data-c="nc">Non-compliant</th><th data-c="s">Support</th><th>Latest minor</th></tr></thead><tbody>')
    foreach ($e in $s['engines']) { $null = $b.Append("<tr class=`"er`"><td><a href=`"#$($e['anchor'])`">$(Hx $e['engine'])</a></td><td class=`"n`">$($e['total'])</td><td class=`"n`">$(ConvertTo-JqText $e['pct_compliant'])%</td><td class=`"n`">$($e['non_compliant'])</td><td></td><td></td></tr>") }
    $null = $b.Append('</tbody></table></div></section>')
    # per account
    $null = $b.Append("<section id=`"accounts`"><h2>Per account <span class=`"muted`">$(@($s['accounts']).Count) account(s) &middot; click a header to sort</span></h2>")
    $null = $b.Append('<table class="sortable accounts"><thead><tr><th>Account</th><th>Collected</th><th>Regions with DBs</th><th>Total</th><th>Compliant</th><th>Non-compliant</th><th>Unknown</th><th>% compliant</th><th>Pending maint.</th><th>Past standard support</th></tr></thead><tbody>')
    foreach ($a in $s['accounts']) { $null = $b.Append((ConvertTo-HtmlAccountRow $a)) }
    $null = $b.Append('</tbody></table></section>')
    # per region
    $null = $b.Append("<section id=`"regions`"><h2>Per region <span class=`"muted`">$(Get-RegionLine $ro) &middot; $(Hx (Get-RegionModeText $ro))$(if ($multi) { ' &middot; per account x region' } else { '' }) &middot; click a header to sort</span></h2>")
    $null = $b.Append('<table class="sortable regions"><thead><tr><th>Account</th><th>Region</th><th>Status</th><th>Total</th><th>Compliant</th><th>Non-compliant</th><th>Unknown</th><th>% compliant</th><th>Pending maint.</th><th>Past standard support</th></tr></thead><tbody>')
    foreach ($x in (Get-ShownRegions $R)) { $null = $b.Append((ConvertTo-HtmlRegionRow $x $false)) }
    $null = $b.Append('</tbody><tfoot>' + (ConvertTo-HtmlRegionRow $s['regions_total'] $true) + '</tfoot></table></section>')
    # global databases
    if ($s['global_databases'] -ne 0) {
        $null = $b.Append("<section id=`"globals`"><h3>Global databases <span class=`"muted`" id=`"g-cnt`">$($s['global_databases'])</span></h3>")
        foreach ($g in $s['globals']) {
            $np = @($g['members'] | Where-Object { $_['role'] -eq 'primary' }).Count; $ns = @($g['members']).Count - $np
            $null = $b.Append("<details class=`"gdb`" data-g=`"$(Hx $g['global_cluster'])`" data-a=`"$(Hx $g['account_id'])`"$(if ($g['region_status_mismatch'] -or $g['version_differs']) { ' data-mm="1"' } else { '' })><summary><b>$(Hx $g['global_cluster'])</b>")
            $null = $b.Append(" <span class=`"st $(Get-StatusClass $g['overall_status'])`">$(Hx $g['overall_status'])</span>")
            $null = $b.Append(" <span class=`"muted`">$(Hx (Get-AccountLabel $g['account_name'] $g['account_id'])) &middot; $(Hx $g['engine']) &middot; $np $(if ($np -eq 1) { 'primary' } else { 'primaries' }) + $ns $(if ($ns -eq 1) { 'secondary' } else { 'secondaries' })</span>")
            if ($g['region_status_mismatch']) { $null = $b.Append(' <span class="st warn">status mismatch</span>') }
            if ($g['version_differs']) { $null = $b.Append(' <span class="st warn">versions differ</span>') }
            $null = $b.Append('</summary><table class="globals"><thead><tr><th>Role</th><th>Region</th><th>Cluster</th><th>Version</th><th>Status</th></tr></thead><tbody>')
            foreach ($m in $g['members']) {
                $null = $b.Append("<tr><td>$(Hx $m['role'])</td><td>$(Hx $m['region'])</td><td>$(Hx $m['identifier'])$(if ($m['headless'] -eq $true) { ' <span class="muted">(headless)</span>' } else { '' })</td><td class=`"mono`">$(Hx (Get-JqDash $m['current_version']))</td>")
                $null = $b.Append("<td><span class=`"st $(Get-StatusClass $m['compliance_status'])`">$(Hx $m['compliance_status'])</span>$(if ($null -ne $m['versions_behind']) { ' <span class="muted">' + (ConvertTo-JqText $m['versions_behind']) + ' behind</span>' } else { '' })</td></tr>")
            }
            $null = $b.Append('</tbody></table>')
            $notes = @(); if ($g['not_scanned'] -gt 0) { $notes += "$($g['not_scanned']) member(s) not scanned" }; foreach ($p in @($g['pending'])) { if ($null -ne $p) { $notes += 'pending: ' + (Hx $p) } }
            if ($notes.Count) { $null = $b.Append('<p class="small muted">' + ($notes -join ' &middot; ') + '</p>') }
            $null = $b.Append('</details>')
        }
        $null = $b.Append('</section>')
    }
    # servers by engine
    $null = $b.Append('<h2 class="secs">Servers by engine <button type="button" id="x-open">Expand all</button><button type="button" id="x-close">Collapse all</button></h2>')
    foreach ($e in $s['engines']) {
        $null = $b.Append("<details class=`"eng-sec`" id=`"$($e['anchor'])`" data-e=`"$(Hx $e['engine'])`"><summary><b>$(Hx $e['engine'])</b> <span class=`"es muted`">$($e['total']) &middot; non-compliant $($e['non_compliant']) &middot; $(ConvertTo-JqText $e['pct_compliant'])%</span></summary>")
        $null = $b.Append('<table class="main"><thead><tr><th>Status</th><th>Behind</th><th>Identifier / members</th><th>Type</th><th>Major</th><th>Current</th><th>Latest minor</th><th>Valid minor targets</th><th>Auto-upgrade default</th><th>Auto minor</th><th>Standard end</th><th>Extended end</th><th>Support</th><th>Pending maint.</th><th>Maint. window</th><th>Account</th></tr></thead><tbody>')
        foreach ($x in @($irows)) { if ($x['engine'] -ceq $e['engine']) { $null = $b.Append((ConvertTo-HtmlRow $x)) } }
        $null = $b.Append('</tbody></table></details>')
    }
    if (@($R['rows']).Count -eq 0) { $null = $b.Append('<p>No servers matched.</p>') }
    if (@($R['errors']).Count -gt 0) { $null = $b.Append('<h2>Errors</h2><ul>' + (@(foreach ($x in $R['errors']) { "<li>$(Hx $x['profile'])/$(Hx $x['region']): $(Hx $x['call']): $(Hx $x['message'])</li>" }) -join '') + '</ul>') }
    # merged inputs
    $mg = Get-JqField $meta 'merge'
    if ($null -ne $mg) {
        $null = $b.Append("<section id=`"sources`"><h2>Merged inputs <span class=`"muted`">$($mg['files']) file(s) &middot; per account the newest collection wins &middot; days to maintenance / support counted from merge time ($(Hx $meta['generated_utc']))</span></h2>")
        $null = $b.Append('<table class="sources"><thead><tr><th>File</th><th>Collected</th><th>Accounts used</th><th>Accounts ignored (newer file exists)</th><th>Script</th></tr></thead><tbody>')
        foreach ($x in $mg['sources']) {
            $cl = Get-JqField $x 'collected_local'; if (-not (Test-JqTruthy $cl)) { $cl = '' }
            $null = $b.Append("<tr><td class=`"mono small`">$(Hx $x['file'])</td><td class=`"small`">$(Hx $x['collected_utc'])<div class=`"sub`">$(Hx $cl)</div></td><td>$(Hx (Get-JqDash (@($x['used']) -join ', ')))</td><td class=`"muted`">$(Hx (Get-JqDash (@($x['superseded']) -join ', ')))</td><td class=`"small`">v$(Hx $x['script_version'])</td></tr>")
        }
        $null = $b.Append('</tbody></table></section>')
    }
    $null = $b.Append('<details id="about" class="about"><summary>About this report</summary><ul>')
    $null = $b.Append("<li><b>COMPLIANT</b> = at most $($s['max_behind']) valid minor upgrade target(s) for the current version; <b>NON-COMPLIANT</b> = $($s['max_behind'] + 1) or more; <b>UNKNOWN</b> = lookup failed or current version not returned (deprecated).</li>")
    $null = $b.Append("<li>Counted are only the valid minor upgrade targets RDS returns for the server's current version (describe-db-engine-versions --engine-version &lt;current&gt;, ValidUpgradeTarget with IsMajorVersionUpgrade=false). Latest minor per major = highest valid target seen (or the current version when up to date).</li>")
    $null = $b.Append("<li><b>Regions:</b> $(Hx (Get-RegionModeText $ro)). Empty regions are only counted; tables list regions with databases or an AWS error.</li>")
    $null = $b.Append("<li><b>Pending maint.</b> = maintenance actions AWS has scheduled or offered for this server that haven't been applied yet (cluster rows include their member instances' actions); click the badge to expand, hover for IST dates.</li>")
    $null = $b.Append('<li><b>Global databases</b> (Aurora): membership from describe-global-clusters (one call per account). Overall status = the worst member; <i>region status mismatch</i> = members on the same version but with a different status (valid targets differ per region). Automatic minor version upgrade does not apply to global database members.</li>')
    $null = $b.Append('<li>Read-only: nothing was changed.</li></ul></details>')
    $null = $b.Append('<script type="application/json" id="pc-data">' + (Get-PageData $R) + '</script>')
    $null = $b.Append("</main><footer>$(Hx $meta['script']) v$(Hx $meta['version']) &middot; read-only</footer>")
    $null = $b.Append('<script>' + $script:Assets.SortJs + '</script><script>' + $script:Assets.PageJs + '</script></body></html>')
    return $b.ToString() + "`n"
}

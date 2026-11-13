# tests/Unit.Tests.ps1 - unit tests of the jq-compatible helpers and the version rules (no AWS, no mock CLI).
# Where jq is installed, the helpers are checked against jq itself on the same input.

BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/RdsPatchCompliance.psm1') -Force
    $script:HasJq = [bool](Get-Command jq -ErrorAction SilentlyContinue)
}

Describe 'jq-compatible JSON' {
    It 'prints numbers like jq: <In> -> <Out>' -TestCases @(
        @{ In = [long]5; Out = '5' }, @{ In = 2.5; Out = '2.5' }, @{ In = 57.89473684210527; Out = '57.89473684210527' }
        @{ In = 100.0; Out = '100' }, @{ In = 1e20; Out = '1E+20' }, @{ In = -0.25; Out = '-0.25' }
    ) {
        InModuleScope RdsPatchCompliance -Parameters @{ In = $In; Out = $Out } { param($In, $Out) Format-JqNumber $In | Should -BeExactly $Out }
    }
    It 'round-trips a document byte for byte like jq . (pretty) and jq -c' -Skip:(-not (Get-Command jq -ErrorAction SilentlyContinue)) {
        $doc = '{"b":[1,2.5,{"x":null,"y":true}],"a":"q\"uote\\ tab\t nl\n uni é ☃ ctl \u0001","n":-3,"e":[],"o":{}}'
        $pretty = ($doc | jq .) -join "`n"
        $compact = ($doc | jq -c .) -join "`n"
        InModuleScope RdsPatchCompliance -Parameters @{ D = $doc; P = $pretty; C = $compact } {
            param($D, $P, $C)
            $v = ConvertFrom-JqJson $D
            ConvertTo-JqJson $v | Should -BeExactly $P
            ConvertTo-JqJson $v -Compact | Should -BeExactly $C
        }
    }
    It 'sorts in jq order (null < false < true < numbers < strings < arrays < objects), stable' {
        InModuleScope RdsPatchCompliance {
            $items = @('b', [long]2, $null, @(1), $true, 'a', [long]1, $false, (New-JqObject ([ordered]@{ k = 1 })), 'B')
            $s = Get-JqSortedBy $items { param($x) , $x }
            ConvertTo-JqJson $s -Compact | Should -BeExactly '[null,false,true,1,2,"B","a","b",[1],{"k":1}]'
        }
    }
    It '@csv and @html escaping match jq' -Skip:(-not (Get-Command jq -ErrorAction SilentlyContinue)) {
        $row = @('plain', 'with "quotes"', 'a,b', [long]3, $null, $true)
        $jqCsv = ('["plain","with \"quotes\"","a,b",3,null,true]' | jq -r '@csv') -join ''
        $jqHtml = ('"<b> & \"x\" ''y''"' | jq -r '@html') -join ''
        InModuleScope RdsPatchCompliance -Parameters @{ R = $row; C = $jqCsv; H = $jqHtml } {
            param($R, $C, $H)
            ConvertTo-JqCsvLine $R | Should -BeExactly $C
            ConvertTo-JqHtml "<b> & `"x`" 'y'" | Should -BeExactly $H
        }
    }
}

Describe 'Version rules' {
    It 'orders engine versions numerically, not as text' {
        InModuleScope RdsPatchCompliance {
            Get-LatestVersion @('13.9', '13.10', '13.18', '13.2') 'postgres' | Should -BeExactly '13.18'
            Get-LatestVersion @('8.0.mysql_aurora.3.05.2', '8.0.mysql_aurora.3.10.0', '8.0.mysql_aurora.3.9.0') 'aurora-mysql' | Should -BeExactly '8.0.mysql_aurora.3.10.0'
        }
    }
    It 'derives the major version: <Engine> <Version> -> <Major>' -TestCases @(
        @{ Engine = 'postgres'; Version = '16.8'; Major = '16' }
        @{ Engine = 'mysql'; Version = '8.0.36'; Major = '8.0' }
        @{ Engine = 'aurora-mysql'; Version = '8.0.mysql_aurora.3.05.2'; Major = '8.0' }
        @{ Engine = 'sqlserver-se'; Version = '15.00.4410.1.v1'; Major = '15.00' }
        @{ Engine = 'oracle-ee'; Version = '19.0.0.0.ru-2025-01.rur-2025-01.r1'; Major = '19' }
    ) {
        InModuleScope RdsPatchCompliance -Parameters @{ E = $Engine; V = $Version; M = $Major } { param($E, $V, $M) Get-DerivedMajor $V $E | Should -BeExactly $M }
    }
}

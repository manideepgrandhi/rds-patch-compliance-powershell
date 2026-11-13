# tests/Lint.Tests.ps1 - static checks: PSScriptAnalyzer (no errors, no warnings beyond the settings file)
# and a check for a PowerShell trap that bit this port several times: variable names are
# case-insensitive, so jq-style $L / $l in one function are the SAME variable.

Describe 'Static analysis' {
    BeforeAll { $script:Root = Split-Path -Parent $PSScriptRoot }
    It 'PSScriptAnalyzer: no errors or warnings in src/ and the scripts' -Skip:(-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
        $files = @(Get-ChildItem "$script:Root/src/*.ps1", "$script:Root/src/*.psm1", "$script:Root/*.ps1")
        $found = foreach ($f in $files) { Invoke-ScriptAnalyzer -Path $f.FullName -Settings "$script:Root/PSScriptAnalyzerSettings.psd1" }
        @($found | ForEach-Object { "$($_.ScriptName):$($_.Line) $($_.RuleName) $($_.Message)" }) | Should -BeNullOrEmpty
    }
    It 'PSScriptAnalyzer: no errors anywhere (tests included)' -Skip:(-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
        @(Invoke-ScriptAnalyzer -Path $script:Root -Recurse -Severity Error) | Should -BeNullOrEmpty
    }
    It 'no function uses two spellings of one variable ($L and $l are the same variable)' {
        $hits = foreach ($f in Get-ChildItem "$script:Root/src/*.ps1", "$script:Root/*.ps1", "$script:Root/tests/*.ps1", "$script:Root/tests/*.psm1") {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
                $names = $fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { $_.VariablePath.UserPath } | Sort-Object -Unique -CaseSensitive
                $names | Group-Object { $_.ToLowerInvariant() } | Where-Object { @($_.Group | Sort-Object -Unique -CaseSensitive).Count -gt 1 } | ForEach-Object { "$($f.Name) $($fn.Name): $($_.Group -join ' / ')" }
            }
        }
        @($hits) | Should -BeNullOrEmpty
    }
    It 'every function has a comment line right above it' {
        $missing = foreach ($f in Get-ChildItem "$script:Root/src/*.ps1") {
            $lines = Get-Content $f.FullName
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -notmatch '^\s*function\s+([\w-]+)') { continue }
                $name = $Matches[1]
                # a run of one-line functions may share the comment above the run
                $j = $i - 1; while ($j -ge 0 -and $lines[$j] -match '^\s*function\s+[\w-]+.*\}\s*$') { $j-- }
                if ($j -lt 0 -or $lines[$j] -notmatch '^\s*(#|\.[A-Z]+|#>)') { "$($f.Name):$($i + 1) $name" }
            }
        }
        @($missing) | Should -BeNullOrEmpty
    }
}

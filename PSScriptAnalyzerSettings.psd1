# PSScriptAnalyzerSettings.psd1 - used by tests/Lint.Tests.ps1 and CI.
# The gate is: no Error-severity findings at all. Warnings are reported; the rules below are
# excluded because they do not fit a port whose helpers mirror jq builtins one to one:
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # module-private helpers named after the jq builtin they mirror (Get-JqUniqueBy, Group-JqBy ...)
        'PSUseSingularNouns'
        # read-only tool: the "state-changing" verbs here (New-*, Set-PcrParams ...) only build in-memory objects
        'PSUseShouldProcessForStateChangingFunctions'
        # false positives: parameters used inside nested script blocks / functions (probe block, merge filters)
        'PSReviewUnusedParameter'
        # source files are UTF-8 without BOM (PowerShell 7 default); Windows PowerShell 5.1 is not supported
        'PSUseBOMForUnicodeEncodedFile'
    )
}

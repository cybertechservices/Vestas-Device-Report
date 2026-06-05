<#
    Test-GetRequestSplat.ps1

    Non-destructive unit check for Get-RequestSplat's TimeoutSec behaviour.

    It does NOT dot-source Device-Reports.ps1 (that would execute the whole
    script / menu). Instead it parses the file, extracts ONLY the
    Get-RequestSplat function definition via the PowerShell AST, defines that
    one function in this scope, and asserts:
      1. a default TimeoutSec=120 is injected when the caller omits it,
      2. a caller-supplied TimeoutSec is preserved (not clobbered),
      3. the caller's other Base keys are carried through unchanged.

    Usage:  pwsh -File tests\Test-GetRequestSplat.ps1
    Exit:   0 = all pass, 1 = one or more failures. No network calls.
#>
$ErrorActionPreference = 'Stop'

$scriptPath = Resolve-Path (Join-Path $PSScriptRoot '..\Device-Reports.ps1')
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
$fn  = $ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-RequestSplat'
}, $true) | Select-Object -First 1
if (-not $fn) { throw "Get-RequestSplat not found in $scriptPath" }

# Define just the function in this scope (no script body runs).
. ([scriptblock]::Create($fn.Extent.Text))

$script:failures = 0
function Assert([bool]$Cond, [string]$Msg) {
    if ($Cond) { Write-Host "PASS: $Msg" -ForegroundColor Green }
    else       { Write-Host "FAIL: $Msg" -ForegroundColor Red; $script:failures++ }
}

# 1. Default TimeoutSec injected when omitted.
$r = Get-RequestSplat -Base @{ Method = 'GET'; Uri = 'https://example.invalid' }
Assert ($r.ContainsKey('TimeoutSec') -and $r['TimeoutSec'] -eq 120) 'default TimeoutSec=120 injected when caller omits it'

# 2. Caller-supplied TimeoutSec preserved.
$r = Get-RequestSplat -Base @{ Method = 'GET'; Uri = 'https://example.invalid'; TimeoutSec = 300 }
Assert ($r['TimeoutSec'] -eq 300) 'caller TimeoutSec=300 override preserved (not clobbered)'

# 3. Other Base keys carried through unchanged.
$r = Get-RequestSplat -Base @{ Method = 'POST'; Uri = 'https://example.invalid' }
Assert ($r['Method'] -eq 'POST' -and $r['Uri'] -eq 'https://example.invalid') 'base keys (Method/Uri) carried through'

if ($script:failures -gt 0) {
    Write-Host "`n$($script:failures) check(s) FAILED." -ForegroundColor Red
    exit 1
}
Write-Host "`nAll Get-RequestSplat checks passed." -ForegroundColor Green
exit 0

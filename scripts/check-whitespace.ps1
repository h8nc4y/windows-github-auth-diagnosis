[CmdletBinding()]
param(
    [string]$Path = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = Split-Path -Parent $scriptRoot
}

$root = (Resolve-Path -LiteralPath $Path).Path

# Backported from 019 check-whitespace.ps1: single entry point for the whitespace
# lint so CI and contributors run the same command and the git empty-tree hash
# lives in exactly one place. Comparing against the empty tree checks every
# committed line; a bare `git diff --check` only inspects the working-tree diff
# and always passes on CI's clean checkout, which made the old step a no-op.
$emptyTreeHash = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'

& git -C $root diff --check $emptyTreeHash HEAD
$exitCode = $LASTEXITCODE

if ($exitCode -ne 0) {
    Write-Host 'Whitespace check failed: trailing whitespace or conflict markers found.'
    exit $exitCode
}

Write-Host 'Whitespace check passed.'
exit 0

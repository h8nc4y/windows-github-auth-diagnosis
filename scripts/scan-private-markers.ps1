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
$ownRepoUrlPattern = '^https://github\.com/h8nc4y/windows-github-auth-diagnosis(?:\.git)?$'

$rules = @(
    @{ Name = 'openai-api-key-prefix'; Pattern = ('s' + 'k-'); Kind = 'literal' },
    @{ Name = 'github-classic-token-prefix'; Pattern = ('g' + 'hp_'); Kind = 'literal' },
    @{ Name = 'github-fine-grained-token-prefix'; Pattern = ('github' + '_pat_'); Kind = 'literal' },
    @{ Name = 'slack-bot-token-prefix'; Pattern = ('xo' + 'xb-'); Kind = 'literal' },
    @{ Name = 'bearer-token-header'; Pattern = ('Bearer' + ' '); Kind = 'literal' },
    @{ Name = 'private-key-block'; Pattern = ('BEGIN ' + 'PRIVATE KEY'); Kind = 'literal' },
    @{ Name = 'private-inventory-repo'; Pattern = ('h8nc4y' + '/codex-global-context'); Kind = 'literal' },
    @{ Name = 'private-projects-path'; Pattern = ('D:' + '\Agent\Codex\Projects'); Kind = 'literal' },
    @{ Name = 'private-user-path'; Pattern = ('C:' + '\Users\h8nc4'); Kind = 'literal' },
    @{ Name = 'email-address'; Pattern = '\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b'; Kind = 'regex' },
    @{ Name = 'windows-absolute-path'; Pattern = '\b[A-Za-z]:\\(?:[^\\/:*?"<>|\r\n]+\\?){2,}'; Kind = 'regex' }
)

$githubUrlPattern = 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?'
$findings = New-Object System.Collections.Generic.List[object]

function Test-SelfReferenceLine {
    param(
        [string]$RelativePath,
        [string]$Line
    )

    if ($RelativePath -eq 'scripts/scan-private-markers.ps1') {
        return $true
    }

    return $false
}

$files = Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {
    $_.FullName -notmatch '\\.git(\\|$)' -and
    $_.FullName -notmatch '\\node_modules(\\|$)' -and
    $_.FullName -notmatch '\\.cache(\\|$)'
}

foreach ($file in $files) {
    $relative = $file.FullName
    if ($relative.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        $relative = $relative.Substring($root.Length).TrimStart([char]92)
    }
    $relative = $relative.Replace([string][char]92, '/')
    $lineNumber = 0

    foreach ($line in Get-Content -LiteralPath $file.FullName) {
        $lineNumber++

        foreach ($match in [regex]::Matches($line, $githubUrlPattern)) {
            if ($match.Value -notmatch $ownRepoUrlPattern -and -not (Test-SelfReferenceLine -RelativePath $relative -Line $line)) {
                $findings.Add([pscustomobject]@{
                    File = $relative
                    Line = $lineNumber
                    Rule = 'non-allowlisted-github-repo-url'
                    Match = $match.Value
                }) | Out-Null
            }
        }

        foreach ($rule in $rules) {
            $matched = $false
            if ($rule.Kind -eq 'literal') {
                $matched = $line.Contains($rule.Pattern)
            } else {
                $matched = [regex]::IsMatch($line, $rule.Pattern, 'IgnoreCase')
            }

            if ($matched -and -not (Test-SelfReferenceLine -RelativePath $relative -Line $line)) {
                $findings.Add([pscustomobject]@{
                    File = $relative
                    Line = $lineNumber
                    Rule = $rule.Name
                    Match = '<redacted>'
                }) | Out-Null
            }
        }
    }
}

if ($findings.Count -gt 0) {
    Write-Host 'Private marker scan failed:'
    $findings | Sort-Object File, Line, Rule | Format-Table -AutoSize
    exit 1
}

Write-Host "Private marker scan passed for $root"

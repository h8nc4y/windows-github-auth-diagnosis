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

$rules = New-Object System.Collections.Generic.List[object]

function Add-ScanRule {
    param(
        [string]$Name,
        [string]$Pattern,
        [ValidateSet('literal', 'regex')]
        [string]$Kind
    )

    if ([string]::IsNullOrWhiteSpace($Pattern)) {
        return
    }

    $rules.Add([pscustomobject]@{
        Name = $Name
        Pattern = $Pattern
        Kind = $Kind
    }) | Out-Null
}

Add-ScanRule -Name 'openai-api-key-prefix' -Pattern ('s' + 'k-') -Kind 'literal'
Add-ScanRule -Name 'github-classic-token-prefix' -Pattern ('g' + 'hp_') -Kind 'literal'
Add-ScanRule -Name 'github-fine-grained-token-prefix' -Pattern ('github' + '_pat_') -Kind 'literal'
Add-ScanRule -Name 'slack-bot-token-prefix' -Pattern ('xo' + 'xb-') -Kind 'literal'
Add-ScanRule -Name 'bearer-token-header' -Pattern ('Bearer' + ' ') -Kind 'literal'
Add-ScanRule -Name 'private-key-block' -Pattern ('BEGIN ' + 'PRIVATE KEY') -Kind 'literal'
Add-ScanRule -Name 'email-address' -Pattern '\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b' -Kind 'regex'
Add-ScanRule -Name 'windows-absolute-path' -Pattern '\b[A-Za-z]:\\(?:[^\\/:*?"<>|\r\n]+\\?){2,}' -Kind 'regex'

$localMarkerIndex = 0

function Add-LocalMarker {
    param([string]$Marker)

    $trimmed = $Marker.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
        return
    }

    $script:localMarkerIndex++
    Add-ScanRule -Name "local-private-marker-$script:localMarkerIndex" -Pattern $trimmed -Kind 'literal'
}

$localMarkerFile = Join-Path $root '.private-markers.local'
if (Test-Path -LiteralPath $localMarkerFile -PathType Leaf) {
    foreach ($line in Get-Content -LiteralPath $localMarkerFile) {
        Add-LocalMarker -Marker $line
    }
}

$environmentMarkers = [Environment]::GetEnvironmentVariable('WINDOWS_GITHUB_AUTH_DIAGNOSIS_PRIVATE_MARKERS')
if (-not [string]::IsNullOrWhiteSpace($environmentMarkers)) {
    foreach ($line in ($environmentMarkers -split "\r?\n")) {
        Add-LocalMarker -Marker $line
    }
}

$githubUrlPattern = 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?'
$findings = New-Object System.Collections.Generic.List[object]

$files = Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {
    $_.FullName -notmatch '\\.git(\\|$)' -and
    $_.FullName -notmatch '\\node_modules(\\|$)' -and
    $_.FullName -notmatch '\\.cache(\\|$)' -and
    $_.Name -ne '.private-markers.local'
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
            if ($match.Value -notmatch $ownRepoUrlPattern) {
                $findings.Add([pscustomobject]@{
                    File = $relative
                    Line = $lineNumber
                    Rule = 'non-allowlisted-github-repo-url'
                    Match = '<redacted>'
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

            if ($matched) {
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

Write-Host 'Private marker scan passed.'
exit 0

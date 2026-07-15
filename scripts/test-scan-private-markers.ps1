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
$scanner = Join-Path $root 'scripts/scan-private-markers.ps1'
if (-not (Test-Path -LiteralPath $scanner -PathType Leaf)) {
    throw "Missing scanner script: $scanner"
}

$powerShellCommand = Get-Command pwsh -ErrorAction SilentlyContinue
if ($null -eq $powerShellCommand) {
    $powerShellCommand = Get-Command powershell -ErrorAction Stop
}

$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message) | Out-Null
}

function Invoke-Scanner {
    param([string]$ScanPath)

    $arguments = @('-NoProfile')
    $commandName = Split-Path -Leaf $powerShellCommand.Source
    if ($commandName -like 'powershell*') {
        $arguments += @('-ExecutionPolicy', 'Bypass')
    }
    $arguments += @('-File', $scanner, '-Path', $ScanPath)

    $output = & $powerShellCommand.Source @arguments 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = ($output | Out-String)
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("windows-github-auth-diagnosis-scan-test-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null

try {
    $cleanRoot = Join-Path $tempRoot 'clean'
    New-Item -ItemType Directory -Path $cleanRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $cleanRoot 'README.md') -Value @(
        '# Clean synthetic fixture'
        'See docs/codex-task-scanner-hardening.md for scanner hardening notes.'
    ) -Encoding UTF8

    $cleanResult = Invoke-Scanner -ScanPath $cleanRoot
    if ($cleanResult.ExitCode -ne 0) {
        Add-Failure "Expected clean fixture to pass, but scanner exited $($cleanResult.ExitCode): $($cleanResult.Output.Trim())"
    }

    $markerRoot = Join-Path $tempRoot 'marker'
    New-Item -ItemType Directory -Path $markerRoot | Out-Null
    $syntheticMarker = ('g' + 'hp_') + 'synthetic_placeholder_only'
    Set-Content -LiteralPath (Join-Path $markerRoot 'leak.txt') -Value "synthetic marker: $syntheticMarker" -Encoding UTF8

    $markerResult = Invoke-Scanner -ScanPath $markerRoot
    if ($markerResult.ExitCode -eq 0) {
        Add-Failure 'Expected synthetic marker fixture to fail, but scanner exited 0.'
    }
    if ($markerResult.Output -notmatch 'github-classic-token-prefix') {
        Add-Failure "Expected synthetic marker output to name github-classic-token-prefix. Output: $($markerResult.Output.Trim())"
    }

    # Higher-recall cloud / PEM prefixes, with one redaction regression each.
    # Fixtures are synthetic placeholders only; no real secrets are used.
    $prefixCases = @(
        @{ Rule = 'openai-api-key-prefix';            Marker = ('s' + 'k-') + 'SyntheticOpenAI000000000000' }
        @{ Rule = 'aws-access-key-id';                Marker = ('A' + 'KIA') + 'EXAMPLE0000000000000' }
        @{ Rule = 'gcp-api-key-prefix';               Marker = ('AIza') + 'Synthetic0000000000000000000000000000' }
        @{ Rule = 'slack-user-token-prefix';          Marker = ('xo' + 'xp-') + 'synthetic-placeholder' }
        @{ Rule = 'slack-legacy-app-token-prefix';    Marker = ('xo' + 'xa-') + 'synthetic-placeholder' }
        @{ Rule = 'slack-app-level-token-prefix';     Marker = ('xa' + 'pp-') + 'synthetic-placeholder' }
        @{ Rule = 'stripe-live-secret-key';           Marker = ('s' + 'k') + '_live_SyntheticPlaceholder0000' }
        @{ Rule = 'pem-private-key-block';            Marker = '-----' + ('BEGIN ' + 'OPENSSH PRIVATE KEY') + '-----' }
    )

    foreach ($case in $prefixCases) {
        $prefixRoot = Join-Path $tempRoot ('prefix-' + $case.Rule)
        New-Item -ItemType Directory -Path $prefixRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $prefixRoot 'leak.txt') -Value "synthetic marker: $($case.Marker)" -Encoding UTF8

        $prefixResult = Invoke-Scanner -ScanPath $prefixRoot
        if ($prefixResult.ExitCode -eq 0) {
            Add-Failure "Expected $($case.Rule) fixture to fail, but scanner exited 0."
        }
        if ($prefixResult.Output -notmatch [regex]::Escape($case.Rule)) {
            Add-Failure "Expected output to name $($case.Rule). Output: $($prefixResult.Output.Trim())"
        }
        # Preserve redaction: the raw marker value must never appear in output.
        if ($prefixResult.Output.Contains($case.Marker)) {
            Add-Failure "Expected $($case.Rule) finding to be redacted, but the raw marker leaked into output."
        }
        if ($prefixResult.Output -notmatch '<redacted>') {
            Add-Failure "Expected $($case.Rule) finding to report '<redacted>'. Output: $($prefixResult.Output.Trim())"
        }
    }

    # windows-absolute-path: private-looking paths should be findings.
    # Split the literal so this test file does not make the scanner flag itself.
    $winPathRealRoot = Join-Path $tempRoot 'winpath-real'
    New-Item -ItemType Directory -Path $winPathRealRoot | Out-Null
    $realWinPath = 'C' + ':\Users\realperson\Secrets\config'
    Set-Content -LiteralPath (Join-Path $winPathRealRoot 'doc.md') -Value "See $realWinPath for details." -Encoding UTF8
    $winPathRealResult = Invoke-Scanner -ScanPath $winPathRealRoot
    if ($winPathRealResult.ExitCode -eq 0) {
        Add-Failure 'Expected real-looking Windows path fixture to fail, but scanner exited 0.'
    }
    if ($winPathRealResult.Output -notmatch 'windows-absolute-path') {
        Add-Failure "Expected real Windows path output to name windows-absolute-path. Output: $($winPathRealResult.Output.Trim())"
    }

    # windows-absolute-path: documented placeholders should not be findings.
    $winPathDocRoot = Join-Path $tempRoot 'winpath-doc'
    New-Item -ItemType Directory -Path $winPathDocRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $winPathDocRoot 'doc.md') -Value @'
Use a placeholder path such as C:\path\to\repo in examples.
You can also write C:\Users\<name>\project to describe a user directory.
'@ -Encoding UTF8
    $winPathDocResult = Invoke-Scanner -ScanPath $winPathDocRoot
    if ($winPathDocResult.ExitCode -ne 0) {
        Add-Failure "Expected placeholder Windows path doc to pass, but scanner exited $($winPathDocResult.ExitCode): $($winPathDocResult.Output.Trim())"
    }

    # bearer-token-header (backport 019/020): prose containing the bare keyword must
    # not be a finding. The keyword is split so this test file does not flag itself
    # under older literal-rule builds.
    $bearerProseRoot = Join-Path $tempRoot 'bearer-prose'
    New-Item -ItemType Directory -Path $bearerProseRoot | Out-Null
    $bearerProse = 'The ' + ('Bear' + 'er') + ' of this note is trusted.'
    Set-Content -LiteralPath (Join-Path $bearerProseRoot 'doc.md') -Value $bearerProse -Encoding UTF8
    $bearerProseResult = Invoke-Scanner -ScanPath $bearerProseRoot
    if ($bearerProseResult.ExitCode -ne 0) {
        Add-Failure "Expected bare Bearer prose fixture to pass, but scanner exited $($bearerProseResult.ExitCode): $($bearerProseResult.Output.Trim())"
    }

    # bearer-token-header: a token-shaped value after the keyword must still fail.
    $bearerTokenRoot = Join-Path $tempRoot 'bearer-token'
    New-Item -ItemType Directory -Path $bearerTokenRoot | Out-Null
    $bearerTokenMarker = ('Bear' + 'er ') + 'SyntheticHeaderValue0000'
    Set-Content -LiteralPath (Join-Path $bearerTokenRoot 'leak.txt') -Value "synthetic marker: $bearerTokenMarker" -Encoding UTF8
    $bearerTokenResult = Invoke-Scanner -ScanPath $bearerTokenRoot
    # Failure messages avoid the header keyword followed by a long token-shaped
    # word, so this test file cannot trip the shipped rule on itself.
    if ($bearerTokenResult.ExitCode -eq 0) {
        Add-Failure 'Expected the token-shaped header fixture to fail, but scanner exited 0.'
    }
    if ($bearerTokenResult.Output -notmatch 'bearer-token-header') {
        Add-Failure "Expected the header fixture output to name bearer-token-header. Output: $($bearerTokenResult.Output.Trim())"
    }
    if ($bearerTokenResult.Output.Contains($bearerTokenMarker)) {
        Add-Failure 'Expected bearer-token-header finding to be redacted, but the raw marker leaked into output.'
    }

    # email-address allowlist (backport 017/019/020): documentation placeholders must
    # not be findings. These literals are safe here because the shipped scanner
    # allowlists them as well.
    $emailPlaceholderRoot = Join-Path $tempRoot 'email-placeholder'
    New-Item -ItemType Directory -Path $emailPlaceholderRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $emailPlaceholderRoot 'doc.md') -Value @(
        'Contact: user@example.com'
        'Sender: noreply@service.example.org'
        'Trailer: octocat@users.noreply.github.com'
    ) -Encoding UTF8
    $emailPlaceholderResult = Invoke-Scanner -ScanPath $emailPlaceholderRoot
    if ($emailPlaceholderResult.ExitCode -ne 0) {
        Add-Failure "Expected placeholder email fixture to pass, but scanner exited $($emailPlaceholderResult.ExitCode): $($emailPlaceholderResult.Output.Trim())"
    }

    # email-address: a real-looking (non-placeholder) address must still fail. The
    # address is assembled at runtime so this test file itself carries no literal.
    $emailRealRoot = Join-Path $tempRoot 'email-real'
    New-Item -ItemType Directory -Path $emailRealRoot | Out-Null
    $realEmail = 'someone' + '@' + 'privatecorp.co.jp'
    Set-Content -LiteralPath (Join-Path $emailRealRoot 'doc.md') -Value "Contact: $realEmail" -Encoding UTF8
    $emailRealResult = Invoke-Scanner -ScanPath $emailRealRoot
    if ($emailRealResult.ExitCode -eq 0) {
        Add-Failure 'Expected real-looking email fixture to fail, but scanner exited 0.'
    }
    if ($emailRealResult.Output -notmatch 'email-address') {
        Add-Failure "Expected real email output to name email-address. Output: $($emailRealResult.Output.Trim())"
    }

    $localMarkerRoot = Join-Path $tempRoot 'local-marker'
    New-Item -ItemType Directory -Path $localMarkerRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $localMarkerRoot '.private-markers.local') -Value 'local-only-marker' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $localMarkerRoot 'leak.txt') -Value 'synthetic local-only-marker fixture' -Encoding UTF8

    $localMarkerResult = Invoke-Scanner -ScanPath $localMarkerRoot
    if ($localMarkerResult.ExitCode -eq 0) {
        Add-Failure 'Expected local marker fixture to fail, but scanner exited 0.'
    }
    if ($localMarkerResult.Output -notmatch 'local-private-marker-1') {
        Add-Failure "Expected local marker output to name local-private-marker-1. Output: $($localMarkerResult.Output.Trim())"
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

if ($failures.Count -gt 0) {
    Write-Host 'Private marker scan self-test failed:'
    foreach ($failure in $failures) {
        Write-Host "- $failure"
    }
    exit 1
}

Write-Host 'Private marker scan self-test passed.'
exit 0

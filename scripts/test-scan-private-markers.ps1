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
$processBoundary = Join-Path $root 'scripts/private-marker-process.ps1'
if (-not (Test-Path -LiteralPath $processBoundary -PathType Leaf)) {
    throw "Missing process boundary script: $processBoundary"
}
. $processBoundary

$currentPowerShellExecutable = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
if ([string]::IsNullOrWhiteSpace($currentPowerShellExecutable) -or
    -not (Test-Path -LiteralPath $currentPowerShellExecutable -PathType Leaf)) {
    $hostExecutableName = if ($PSVersionTable.PSVersion.Major -le 5) {
        'powershell.exe'
    } elseif (Test-PrivateMarkerWindowsHost) {
        'pwsh.exe'
    } else {
        'pwsh'
    }
    $currentPowerShellExecutable = Join-Path $PSHOME $hostExecutableName
}
if (-not (Test-Path -LiteralPath $currentPowerShellExecutable -PathType Leaf)) {
    throw "Cannot resolve the current PowerShell host executable: $currentPowerShellExecutable"
}

$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message) | Out-Null
}

function Test-ByteArrayContainsSequence {
    param(
        [byte[]]$Haystack,
        [byte[]]$Needle
    )

    if ($Needle.Length -eq 0) {
        return $true
    }
    if ($Haystack.Length -lt $Needle.Length) {
        return $false
    }
    for ($offset = 0;
        $offset -le ($Haystack.Length - $Needle.Length);
        $offset++) {
        $matched = $true
        for ($needleIndex = 0;
            $needleIndex -lt $Needle.Length;
            $needleIndex++) {
            if ($Haystack[$offset + $needleIndex] -ne $Needle[$needleIndex]) {
                $matched = $false
                break
            }
        }
        if ($matched) {
            return $true
        }
    }
    return $false
}

function Test-ByteArraysEqual {
    param(
        [byte[]]$Expected,
        [byte[]]$Actual
    )

    if ($Expected.Length -ne $Actual.Length) {
        return $false
    }
    for ($index = 0; $index -lt $Expected.Length; $index++) {
        if ($Expected[$index] -ne $Actual[$index]) {
            return $false
        }
    }
    return $true
}

function Get-ProcessEnvironmentSnapshot {
    $snapshot = @{}
    $environment = [Environment]::GetEnvironmentVariables('Process')
    foreach ($name in $environment.Keys) {
        $snapshot["$name"] = [string]$environment[$name]
    }
    return $snapshot
}

function Assert-ProcessEnvironmentUnchanged {
    param(
        [hashtable]$Expected,
        [string]$Context
    )

    $actual = Get-ProcessEnvironmentSnapshot
    $differentNames = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($Expected.Keys + $actual.Keys) | Sort-Object -Unique) {
        if ($Expected.ContainsKey($name) -ne $actual.ContainsKey($name) -or
            ($Expected.ContainsKey($name) -and $Expected[$name] -cne $actual[$name])) {
            # 周辺環境には秘密値があり得るため、差分は変数名だけを報告する。
            $differentNames.Add("$name") | Out-Null
        }
    }
    if ($differentNames.Count -gt 0) {
        Add-Failure "$Context changed parent environment variables: $($differentNames -join ', ')."
    }
}

function Set-SyntheticGitControlFile {
    param(
        [string]$Path,
        [hashtable]$Values
    )

    # fake Gitの挙動制御はchild environmentへ載せず、random temp配下の
    # 隣接control fileへ固定する。値はbase64化し、改行や区切り文字を曖昧にしない。
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($Values.Keys | Sort-Object)) {
        $encodedValue = [Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes([string]$Values[$name])
        )
        $lines.Add("$name=$encodedValue") | Out-Null
    }
    [System.IO.File]::WriteAllLines(
        $Path,
        [string[]]$lines,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Invoke-Scanner {
    param(
        [string]$ScanPath,
        [hashtable]$EnvironmentOverrides = @{},
        [string[]]$AdditionalArguments = @(),
        [string]$ScannerPath = $scanner
    )

    $arguments = @('-NoProfile')
    if ($PSVersionTable.PSVersion.Major -le 5 -and
        (Test-PrivateMarkerWindowsHost)) {
        $arguments += @('-ExecutionPolicy', 'Bypass')
    }
    $arguments += @('-File', $ScannerPath, '-Path', $ScanPath)
    $arguments += $AdditionalArguments
    $result = Invoke-PrivateMarkerProcess `
        -FileName $currentPowerShellExecutable `
        -Arguments $arguments `
        -WorkingDirectory $root `
        -EnvironmentOverrides $EnvironmentOverrides `
        -MaximumStandardOutputBytes 4194304 `
        -TimeoutMilliseconds 30000
    return ConvertTo-TestProcessResult -Result $result
}

function Invoke-HermeticGit {
    param(
        [string]$WorkingDirectory,
        [string[]]$Arguments,
        [string]$IsolationRoot
    )

    $gitCommand = Get-Command git -ErrorAction Stop
    $result = Invoke-PrivateMarkerProcess `
        -FileName $gitCommand.Source `
        -Arguments $Arguments `
        -WorkingDirectory $WorkingDirectory `
        -SanitizeGitEnvironment `
        -IsolationRoot $IsolationRoot `
        -TimeoutMilliseconds 20000
    return ConvertTo-TestProcessResult -Result $result
}

function ConvertTo-TestProcessResult {
    param([pscustomobject]$Result)

    $stdout = [System.Text.UTF8Encoding]::new($false).GetString(
        $Result.StandardOutputBytes
    )
    $stderr = [System.Text.UTF8Encoding]::new($false).GetString(
        $Result.StandardErrorBytes
    )
    $healthyBoundary = $Result.ContainmentEstablished -and
        $Result.StreamsCompleted -and
        $Result.TreeStopped -and
        -not $Result.TimedOut -and
        -not $Result.OutputLimitExceeded -and
        -not $Result.InputWriteFailed -and
        -not $Result.PipeLeakDetected
    $exitCode = if ($healthyBoundary) { $Result.ExitCode } else { -1 }
    $diagnostics = New-Object System.Collections.Generic.List[string]
    if (-not $Result.ContainmentEstablished) {
        $diagnostics.Add('containment-not-established')
    }
    if (-not $Result.StreamsCompleted) { $diagnostics.Add('streams-incomplete') }
    if (-not $Result.TreeStopped) { $diagnostics.Add('tree-cleanup-failed') }
    if ($Result.TimedOut) { $diagnostics.Add('timed-out') }
    if ($Result.OutputLimitExceeded) { $diagnostics.Add('output-limit') }
    if ($Result.InputWriteFailed) { $diagnostics.Add('input-write') }
    if ($Result.PipeLeakDetected) { $diagnostics.Add('pipe-leak') }
    $output = (@($stdout, $stderr) -join [Environment]::NewLine).TrimEnd()
    if ($diagnostics.Count -gt 0) {
        $output += [Environment]::NewLine + (
            'bounded-process-failure: ' + ($diagnostics -join ',')
        )
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        RawExitCode = $Result.ExitCode
        Output = $output
        TimedOut = $Result.TimedOut
        OutputLimitExceeded = $Result.OutputLimitExceeded
        InputWriteFailed = $Result.InputWriteFailed
        PipeLeakDetected = $Result.PipeLeakDetected
        ContainmentEstablished = $Result.ContainmentEstablished
        StreamsCompleted = $Result.StreamsCompleted
        TreeStopped = $Result.TreeStopped
        StandardOutputBytes = [byte[]]$Result.StandardOutputBytes
        StandardErrorBytes = [byte[]]$Result.StandardErrorBytes
    }
}

function Test-FixedIntegrityFailureResult {
    param(
        [pscustomobject]$Result,
        [string]$Reason,
        [string[]]$SensitiveTexts = @()
    )

    $expectedDiagnostic =
        "Private marker scan failed closed (integrity: $Reason)."
    $expectedStandardError = [Text.Encoding]::UTF8.GetBytes(
        $expectedDiagnostic + [Environment]::NewLine
    )
    if ($Result.ExitCode -ne 2 -or
        $Result.TimedOut -or
        $Result.OutputLimitExceeded -or
        $Result.InputWriteFailed -or
        $Result.PipeLeakDetected -or
        -not $Result.StreamsCompleted -or
        -not $Result.TreeStopped -or
        $Result.StandardOutputBytes.Length -ne 0 -or
        -not (Test-ByteArraysEqual `
            -Expected $expectedStandardError `
            -Actual $Result.StandardErrorBytes)) {
        return $false
    }

    [byte[]]$combinedBytes =
        @($Result.StandardOutputBytes) +
        @($Result.StandardErrorBytes)
    foreach ($sensitiveText in $SensitiveTexts) {
        if ([string]::IsNullOrEmpty($sensitiveText)) {
            continue
        }
        foreach ($encoding in @(
            [Text.Encoding]::UTF8,
            [Text.Encoding]::Unicode,
            [Text.Encoding]::BigEndianUnicode
        )) {
            if (Test-ByteArrayContainsSequence `
                    -Haystack $combinedBytes `
                    -Needle $encoding.GetBytes($sensitiveText)) {
                return $false
            }
        }
    }
    return $true
}

function Test-HermeticEnvironmentProbeRetryableTimeout {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Result
    )

    # hosted Windows PowerShell 5.1のcold startだけを再試行対象にする。
    # PS7/Linux/macOSでは同じhealthy timeoutでも初回結果をそのまま返し、
    # production timeoutや別runtimeのfailureをtest-only retryで覆わない。
    return (Test-PrivateMarkerWindowsHost) -and
        $PSVersionTable.PSVersion.Major -eq 5 -and
        $PSVersionTable.PSVersion.Minor -eq 1 -and
        $Result.TimedOut -and
        $Result.ExitCode -eq 0 -and
        $Result.StandardOutputBytes.Length -eq 0 -and
        $Result.StandardErrorBytes.Length -eq 0 -and
        -not $Result.OutputLimitExceeded -and
        -not $Result.InputWriteFailed -and
        -not $Result.PipeLeakDetected -and
        $Result.ContainmentEstablished -and
        $Result.StreamsCompleted -and
        $Result.TreeStopped
}

# retry helper単体でも、healthy timeoutがWindows PowerShell 5.1以外では
# 必ず拒否されることを実測する。production Git timeoutとは共有しない。
$healthyHermeticTimeoutFixture = [pscustomobject]@{
    TimedOut = $true
    ExitCode = 0
    StandardOutputBytes = [byte[]]@()
    StandardErrorBytes = [byte[]]@()
    OutputLimitExceeded = $false
    InputWriteFailed = $false
    PipeLeakDetected = $false
    ContainmentEstablished = $true
    StreamsCompleted = $true
    TreeStopped = $true
}
$isWindowsPowerShell51 =
    (Test-PrivateMarkerWindowsHost) -and
    $PSVersionTable.PSVersion.Major -eq 5 -and
    $PSVersionTable.PSVersion.Minor -eq 1
$healthyHermeticTimeoutIsRetryable =
    Test-HermeticEnvironmentProbeRetryableTimeout `
        -Result $healthyHermeticTimeoutFixture
if ($healthyHermeticTimeoutIsRetryable -ne $isWindowsPowerShell51) {
    Add-Failure 'Expected hermetic environment retry eligibility only on Windows PowerShell 5.1.'
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("windows-github-auth-diagnosis-scan-test-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$emptyCommandPath = Join-Path $tempRoot 'empty-command-path'
New-Item -ItemType Directory -Path $emptyCommandPath | Out-Null
$preexistingScannerIsolationRoots = @(
    Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) `
        -Directory `
        -Filter 'windows-github-auth-diagnosis-git-*' `
        -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name }
)

try {
    # process helperの初回呼出しを文字列化しやすいASCIIでは済ませない。
    # 00/80/FFをstdinから受け、そのままstdout/stderrへ返すfixtureで、
    # Windowsのsuspended CreateProcessW経路を含む3本のpipeが最初から
    # binary-safeであることをexact byte列として固定する。
    $binaryEchoPath = Join-Path $tempRoot 'BinaryEcho.ps1'
    $binaryEchoSource = @'
$inputStream = [Console]::OpenStandardInput()
$memory = New-Object System.IO.MemoryStream
$buffer = New-Object byte[] 16
try {
    while (($count = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $memory.Write($buffer, 0, $count)
    }
    [byte[]]$payload = $memory.ToArray()
    $outputStream = [Console]::OpenStandardOutput()
    $errorStream = [Console]::OpenStandardError()
    $outputStream.Write($payload, 0, $payload.Length)
    $outputStream.Flush()
    $errorStream.Write($payload, 0, $payload.Length)
    $errorStream.Flush()
}
finally {
    $memory.Dispose()
}
'@
    [System.IO.File]::WriteAllText(
        $binaryEchoPath,
        $binaryEchoSource,
        [System.Text.UTF8Encoding]::new($true)
    )
    [byte[]]$binaryProbeBytes = @(0x00, 0x80, 0xFF)
    $binaryHostArguments = @('-NoProfile')
    if ($PSVersionTable.PSVersion.Major -le 5 -and
        (Test-PrivateMarkerWindowsHost)) {
        $binaryHostArguments += @('-ExecutionPolicy', 'Bypass')
    }
    $binaryPipeResult = Invoke-PrivateMarkerProcess `
        -FileName $currentPowerShellExecutable `
        -Arguments ($binaryHostArguments + @('-File', $binaryEchoPath)) `
        -StandardInputBytes $binaryProbeBytes `
        -WorkingDirectory $tempRoot `
        -MaximumStandardInputBytes $binaryProbeBytes.Length `
        -MaximumStandardOutputBytes $binaryProbeBytes.Length `
        -MaximumStandardErrorBytes $binaryProbeBytes.Length `
        -TimeoutMilliseconds 10000
    if ($binaryPipeResult.ExitCode -ne 0 -or
        $binaryPipeResult.TimedOut -or
        $binaryPipeResult.OutputLimitExceeded -or
        $binaryPipeResult.InputWriteFailed -or
        $binaryPipeResult.PipeLeakDetected -or
        -not $binaryPipeResult.ContainmentEstablished -or
        -not $binaryPipeResult.StreamsCompleted -or
        -not $binaryPipeResult.TreeStopped -or
        -not (Test-ByteArraysEqual `
            -Expected $binaryProbeBytes `
            -Actual $binaryPipeResult.StandardOutputBytes) -or
        -not (Test-ByteArraysEqual `
            -Expected $binaryProbeBytes `
            -Actual $binaryPipeResult.StandardErrorBytes)) {
        Add-Failure 'Expected first bounded-process invocation to preserve exact 00/80/FF bytes across stdin, stdout, and stderr.'
    }

    # external setsidはBusyBoxとutil-linuxの共通operand形だけを使う。
    # optionを足す回帰をOS非依存のpure argument builderで検出する。
    $portableSetsidArguments = @(
        Get-PrivateMarkerPosixSetsidArguments `
            -PowerShellExecutable '/synthetic/pwsh' `
            -EncodedCommand 'synthetic-encoded-command'
    )
    $expectedPortableSetsidArguments = @(
        '/synthetic/pwsh',
        '-NoProfile',
        '-EncodedCommand',
        'synthetic-encoded-command'
    )
    $portableSetsidArgumentsMatch =
        $portableSetsidArguments.Count -eq
            $expectedPortableSetsidArguments.Count
    if ($portableSetsidArgumentsMatch) {
        for ($argumentIndex = 0;
            $argumentIndex -lt $expectedPortableSetsidArguments.Count;
            $argumentIndex++) {
            if ($portableSetsidArguments[$argumentIndex] -cne
                $expectedPortableSetsidArguments[$argumentIndex]) {
                $portableSetsidArgumentsMatch = $false
                break
            }
        }
    }
    if (-not $portableSetsidArgumentsMatch) {
        Add-Failure 'Expected external POSIX setsid arguments to use the BusyBox-compatible operand form.'
    }

    # sanitized Git childはGIT_*だけでなく、非Git名のcredential・marker・
    # loader変数と明示overrideも捨て、固定した最小環境だけを受け取る。
    $hermeticEnvironmentProbe = @'
$ErrorActionPreference = 'Stop'
$forbiddenNames = @(
    'PRIVATE_MARKER_AMBIENT_SECRET_PROBE',
    'WINDOWS_GITHUB_AUTH_DIAGNOSIS_PRIVATE_MARKERS',
    'AWS_ACCESS_KEY_ID',
    'GH_TOKEN',
    'SSH_AUTH_SOCK',
    'LD_PRELOAD',
    'GIT_PRIVATE_MARKER_AMBIENT_PROBE'
)
$failedNames = New-Object System.Collections.Generic.List[string]
foreach ($name in $forbiddenNames) {
    if ($null -ne [Environment]::GetEnvironmentVariable($name, 'Process')) {
        $failedNames.Add($name) | Out-Null
    }
}
foreach ($name in @(
    'HOME',
    'USERPROFILE',
    'XDG_CONFIG_HOME',
    'PATH',
    'TEMP',
    'TMP'
)) {
    if ([string]::IsNullOrWhiteSpace(
            [Environment]::GetEnvironmentVariable($name, 'Process')
        )) {
        $failedNames.Add($name) | Out-Null
    }
}
if (-not [System.IO.Path]::DirectorySeparatorChar.Equals([char]92) -and
    [string]::IsNullOrWhiteSpace($env:TMPDIR)) {
    $failedNames.Add('TMPDIR') | Out-Null
}
if ($env:PATH -like '*PRIVATE_MARKER_AMBIENT_PATH_PROBE*') {
    $failedNames.Add('PATH') | Out-Null
}
if ($env:GIT_CONFIG_NOSYSTEM -cne '1' -or
    $env:GIT_NO_LAZY_FETCH -cne '1' -or
    $env:GIT_NO_REPLACE_OBJECTS -cne '1') {
    $failedNames.Add('GIT_HERMETIC_CONTROLS') | Out-Null
}
if ($failedNames.Count -gt 0) {
    [Console]::Error.Write($failedNames -join ',')
    exit 72
}
[Console]::Out.Write('hermetic-environment-pass')
'@
    $hermeticEnvironmentEncoded = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($hermeticEnvironmentProbe)
    )
    $hermeticEnvironmentArguments = @('-NoProfile')
    if ($PSVersionTable.PSVersion.Major -le 5 -and
        (Test-PrivateMarkerWindowsHost)) {
        $hermeticEnvironmentArguments += @('-ExecutionPolicy', 'Bypass')
    }
    $hermeticEnvironmentArguments += @(
        '-EncodedCommand',
        $hermeticEnvironmentEncoded
    )
    # hosted WindowsのPS5.1 cold startは、processを一度も実行できないまま
    # 30秒へ達することがある。production Git timeoutは変えず、outputなし・
    # 境界内完全停止のhealthy timeoutだけをfresh isolationで1回再試行する。
    $hermeticEnvironmentProbeTimeoutMilliseconds = 30000
    $hermeticEnvironmentProbeMaximumAttempts = 2
    $hermeticEnvironmentAttemptCount = 0
    $hermeticEnvironmentResult = $null
    for (
        $hermeticEnvironmentAttempt = 1;
        $hermeticEnvironmentAttempt -le
            $hermeticEnvironmentProbeMaximumAttempts;
        $hermeticEnvironmentAttempt++
    ) {
        $hermeticEnvironmentAttemptCount = $hermeticEnvironmentAttempt
        $hermeticEnvironmentIsolationRoot = Join-Path `
            $tempRoot `
            "hermetic-child-environment-$hermeticEnvironmentAttempt"
        $beforeHermeticEnvironmentProbe = Get-ProcessEnvironmentSnapshot
        $hermeticEnvironmentResult = Invoke-PrivateMarkerProcess `
            -FileName $currentPowerShellExecutable `
            -Arguments $hermeticEnvironmentArguments `
            -WorkingDirectory $tempRoot `
            -EnvironmentOverrides @{
                PRIVATE_MARKER_AMBIENT_SECRET_PROBE = 'synthetic-secret'
                WINDOWS_GITHUB_AUTH_DIAGNOSIS_PRIVATE_MARKERS = 'synthetic-marker'
                AWS_ACCESS_KEY_ID = 'synthetic-credential'
                GH_TOKEN = 'synthetic-credential'
                SSH_AUTH_SOCK = 'synthetic-agent'
                LD_PRELOAD = 'synthetic-loader'
                GIT_PRIVATE_MARKER_AMBIENT_PROBE = 'synthetic-git-value'
                PATH = 'PRIVATE_MARKER_AMBIENT_PATH_PROBE'
            } `
            -SanitizeGitEnvironment `
            -IsolationRoot $hermeticEnvironmentIsolationRoot `
            -MaximumStandardOutputBytes 128 `
            -MaximumStandardErrorBytes 4096 `
            -TimeoutMilliseconds `
                $hermeticEnvironmentProbeTimeoutMilliseconds
        Assert-ProcessEnvironmentUnchanged `
            -Expected $beforeHermeticEnvironmentProbe `
            -Context 'Hermetic Git child probe'

        $shouldRetryHermeticEnvironmentProbe =
            $hermeticEnvironmentAttempt -lt
                $hermeticEnvironmentProbeMaximumAttempts -and
            (Test-HermeticEnvironmentProbeRetryableTimeout `
                -Result $hermeticEnvironmentResult)
        if (-not $shouldRetryHermeticEnvironmentProbe) {
            break
        }
    }
    $hermeticEnvironmentExpected =
        [Text.Encoding]::UTF8.GetBytes('hermetic-environment-pass')
    if ($hermeticEnvironmentResult.ExitCode -ne 0 -or
        $hermeticEnvironmentResult.TimedOut -or
        $hermeticEnvironmentResult.OutputLimitExceeded -or
        $hermeticEnvironmentResult.InputWriteFailed -or
        $hermeticEnvironmentResult.PipeLeakDetected -or
        -not $hermeticEnvironmentResult.ContainmentEstablished -or
        -not $hermeticEnvironmentResult.StreamsCompleted -or
        -not $hermeticEnvironmentResult.TreeStopped -or
        -not (Test-ByteArraysEqual `
            -Expected $hermeticEnvironmentExpected `
            -Actual $hermeticEnvironmentResult.StandardOutputBytes)) {
        $hermeticEnvironmentDetail = if (
            $hermeticEnvironmentResult.ExitCode -eq 72
        ) {
            'probe-variable-check-failed'
        } else {
            "exit=$($hermeticEnvironmentResult.ExitCode)," +
                "attempts=$hermeticEnvironmentAttemptCount," +
                "stdout-bytes=$($hermeticEnvironmentResult.StandardOutputBytes.Length)," +
                "stderr-bytes=$($hermeticEnvironmentResult.StandardErrorBytes.Length)," +
                "timed-out=$($hermeticEnvironmentResult.TimedOut)," +
                "output-limit=$($hermeticEnvironmentResult.OutputLimitExceeded)," +
                "input-failed=$($hermeticEnvironmentResult.InputWriteFailed)," +
                "pipe-leak=$($hermeticEnvironmentResult.PipeLeakDetected)," +
                "containment=$($hermeticEnvironmentResult.ContainmentEstablished)," +
                "streams=$($hermeticEnvironmentResult.StreamsCompleted)," +
                "tree-stopped=$($hermeticEnvironmentResult.TreeStopped)"
        }
        Add-Failure "Expected sanitized Git child to receive only the fixed hermetic environment allowlist. Detail: $hermeticEnvironmentDetail"
    }

    if (Test-PrivateMarkerWindowsHost) {
        # Job割当前・resume前・assigned Job close失敗時はtargetを一度も
        # 実行せず、direct TerminateProcess fallback後にPIDを有限時間で除去する。
        foreach ($launchFailureMode in @(
            'assign',
            'resume',
            'resume-close'
        )) {
            $launchFailureSentinel = Join-Path `
                $tempRoot `
                "windows-launch-failure-$launchFailureMode.txt"
            $escapedLaunchFailureSentinel =
                $launchFailureSentinel.Replace("'", "''")
            $launchFailureScript = @"
[IO.File]::WriteAllText('$escapedLaunchFailureSentinel', 'ran')
"@
            $launchFailureEncoded = [Convert]::ToBase64String(
                [Text.Encoding]::Unicode.GetBytes($launchFailureScript)
            )
            $launchFailureArguments = @('-NoProfile')
            if ($PSVersionTable.PSVersion.Major -le 5) {
                $launchFailureArguments += @(
                    '-ExecutionPolicy',
                    'Bypass'
                )
            }
            $launchFailureArguments += @(
                '-EncodedCommand',
                $launchFailureEncoded
            )

            $launchFailureStopwatch =
                [Diagnostics.Stopwatch]::StartNew()
            $launchFailureObserved = $false
            $launchFailureException = $null
            try {
                [void](Invoke-PrivateMarkerProcess `
                    -FileName $currentPowerShellExecutable `
                    -Arguments $launchFailureArguments `
                    -WorkingDirectory $tempRoot `
                    -TimeoutMilliseconds 10000 `
                    -ForceWindowsLaunchFailure $launchFailureMode)
            }
            catch {
                # 例外本文にはローカルpathが入り得るため、公開可能な判定だけを保持する。
                $launchFailureObserved = $true
                $launchFailureException = $_.Exception
            }
            $launchFailureStopwatch.Stop()

            $launchFailureProcessId =
                [PrivateMarker.ContainedProcess]::
                    LastSyntheticFailureProcessId
            $launchFailureProcessGone = $false
            if ($launchFailureProcessId -gt 0) {
                # API結果だけでなくkernel process tableからの消失も最大1秒で確認し、
                # handleを閉じただけの誤実装を検出する。
                for ($pidCheckAttempt = 0;
                    $pidCheckAttempt -lt 20;
                    $pidCheckAttempt++) {
                    if ($null -eq (Get-Process `
                        -Id $launchFailureProcessId `
                        -ErrorAction SilentlyContinue)) {
                        $launchFailureProcessGone = $true
                        break
                    }
                    Start-Sleep -Milliseconds 50
                }
            }
            Start-Sleep -Milliseconds 100
            if (-not $launchFailureObserved -or
                $launchFailureProcessId -le 0 -or
                -not $launchFailureProcessGone -or
                $launchFailureStopwatch.ElapsedMilliseconds -ge 6000 -or
                (Test-Path -LiteralPath $launchFailureSentinel)) {
                Add-Failure "Expected $launchFailureMode launch failure to remove its PID without resuming the suspended target."
            }

            if ($launchFailureMode -ceq 'resume-close') {
                # public PowerShell境界はC# AggregateExceptionを固定messageへ包む。
                # source contractでinner順を固定し、runtimeではprimary/cleanupの
                # 両sentinelが外側診断まで失われないことを独立に確認する。
                $launchFailureMessage = [string]$launchFailureException.Message
                $resumePrimaryMessage = 'Synthetic ResumeThread failure.'
                $assignedJobCleanupMessage =
                    'Synthetic assigned Job close failure.'
                $resumePrimaryIndex =
                    $launchFailureMessage.IndexOf(
                        $resumePrimaryMessage,
                        [StringComparison]::Ordinal
                    )
                $assignedJobCleanupIndex =
                    $launchFailureMessage.IndexOf(
                        $assignedJobCleanupMessage,
                        [StringComparison]::Ordinal
                    )
                if ([regex]::Matches(
                        $launchFailureMessage,
                        [regex]::Escape($resumePrimaryMessage)
                    ).Count -ne 1 -or
                    [regex]::Matches(
                        $launchFailureMessage,
                        [regex]::Escape($assignedJobCleanupMessage)
                    ).Count -ne 1 -or
                    $resumePrimaryIndex -lt 0 -or
                    $assignedJobCleanupIndex -le $resumePrimaryIndex) {
                    Add-Failure 'Expected resume-close aggregate to retain the synthetic resume primary failure alongside cleanup failure.'
                }
            }
        }

        # environment/CreateProcess/Job assign中にcaller期限を跨いだ場合も、
        # resume直前の同一clock確認でtargetを一度も実行せず回収する。
        $windowsExpiredReleaseSentinel =
            Join-Path $tempRoot 'windows-expired-release-ran.txt'
        $escapedWindowsExpiredReleaseSentinel =
            $windowsExpiredReleaseSentinel.Replace("'", "''")
        $windowsExpiredReleaseScript = @"
[IO.File]::WriteAllText('$escapedWindowsExpiredReleaseSentinel', 'ran')
"@
        $windowsExpiredReleaseEncoded = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes(
                $windowsExpiredReleaseScript
            )
        )
        $windowsExpiredReleaseArguments = @('-NoProfile')
        if ($PSVersionTable.PSVersion.Major -le 5) {
            $windowsExpiredReleaseArguments += @(
                '-ExecutionPolicy',
                'Bypass'
            )
        }
        $windowsExpiredReleaseArguments += @(
            '-EncodedCommand',
            $windowsExpiredReleaseEncoded
        )
        $windowsExpiredReleaseResult = Invoke-PrivateMarkerProcess `
            -FileName $currentPowerShellExecutable `
            -Arguments $windowsExpiredReleaseArguments `
            -WorkingDirectory $tempRoot `
            -TimeoutMilliseconds 25 `
            -ForceWindowsLaunchFailure 'deadline'
        Start-Sleep -Milliseconds 100
        if (-not $windowsExpiredReleaseResult.TimedOut -or
            -not $windowsExpiredReleaseResult.ContainmentEstablished -or
            -not $windowsExpiredReleaseResult.TreeStopped -or
            (Test-Path -LiteralPath $windowsExpiredReleaseSentinel)) {
            Add-Failure 'Expected Windows target release to remain blocked after the caller deadline.'
        }

        # 正常launch後のJob closeを2回synthetic failureにし、main cleanupから
        # Stop、Disposeへ同じhandleが保持され、3回目で回収されることを実測する。
        $jobCloseReady = Join-Path $tempRoot 'job-close-child-ready.txt'
        $jobCloseSentinel = Join-Path $tempRoot 'job-close-child-ran.txt'
        $escapedJobCloseReady = $jobCloseReady.Replace("'", "''")
        $escapedJobCloseSentinel =
            $jobCloseSentinel.Replace("'", "''")
        $jobCloseChildScript = @"
[IO.File]::WriteAllText('$escapedJobCloseReady', 'ready')
Start-Sleep -Milliseconds 1200
[IO.File]::WriteAllText('$escapedJobCloseSentinel', 'ran')
"@
        $jobCloseChildEncoded = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes($jobCloseChildScript)
        )
        $escapedPowerShellExecutable =
            $currentPowerShellExecutable.Replace("'", "''")
        $jobCloseParentScript = @"
`$childArguments = @('-NoProfile')
if (`$PSVersionTable.PSVersion.Major -le 5) {
    `$childArguments += @('-ExecutionPolicy', 'Bypass')
}
`$childArguments += @('-EncodedCommand', '$jobCloseChildEncoded')
Start-Process -FilePath '$escapedPowerShellExecutable' ``
    -ArgumentList `$childArguments -WindowStyle Hidden | Out-Null
for (`$attempt = 0; `$attempt -lt 100; `$attempt++) {
    if (Test-Path -LiteralPath '$escapedJobCloseReady') {
        exit 0
    }
    Start-Sleep -Milliseconds 20
}
exit 77
"@
        $jobCloseParentEncoded = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes($jobCloseParentScript)
        )
        $jobCloseArguments = @('-NoProfile')
        if ($PSVersionTable.PSVersion.Major -le 5) {
            $jobCloseArguments += @('-ExecutionPolicy', 'Bypass')
        }
        $jobCloseArguments += @(
            '-EncodedCommand',
            $jobCloseParentEncoded
        )
        $jobCloseFailureObserved = $false
        $jobCloseStopwatch = [Diagnostics.Stopwatch]::StartNew()
        try {
            [void](Invoke-PrivateMarkerProcess `
                -FileName $currentPowerShellExecutable `
                -Arguments $jobCloseArguments `
                -WorkingDirectory $tempRoot `
                -TimeoutMilliseconds 10000 `
                -ForceWindowsLaunchFailure 'close')
        }
        catch {
            $jobCloseFailureObserved = $true
        }
        $jobCloseStopwatch.Stop()
        $jobCloseProcessId =
            [PrivateMarker.ContainedProcess]::LastSyntheticFailureProcessId
        $jobCloseProcessGone = $false
        if ($jobCloseProcessId -gt 0) {
            for ($pidCheckAttempt = 0;
                $pidCheckAttempt -lt 20;
                $pidCheckAttempt++) {
                if ($null -eq (Get-Process `
                    -Id $jobCloseProcessId `
                    -ErrorAction SilentlyContinue)) {
                    $jobCloseProcessGone = $true
                    break
                }
                Start-Sleep -Milliseconds 50
            }
        }
        # childの遅延副作用より長く待ち、Job fallbackがtree全体を止めたことを確認する。
        Start-Sleep -Milliseconds 1400
        if (-not $jobCloseFailureObserved -or
            -not (Test-Path -LiteralPath $jobCloseReady) -or
            (Test-Path -LiteralPath $jobCloseSentinel) -or
            $jobCloseProcessId -le 0 -or
            -not $jobCloseProcessGone -or
            $jobCloseStopwatch.ElapsedMilliseconds -ge 6000) {
            Add-Failure 'Expected repeated Job close failures to retain the handle through Stop/Dispose and contain every child.'
        }

        # cleanupの先頭streamがDispose失敗しても、残るstreamとnative handleを
        # 必ず試行する。reflection fixtureはproduction ContainedProcess.Dispose
        # 自体を通し、先頭例外で後続cleanupをskipする回帰をREDに固定する。
        if ($null -eq ('PrivateMarker.Testing.DisposeProbeStream' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.IO;

namespace PrivateMarker.Testing
{
    public sealed class DisposeProbeStream : MemoryStream
    {
        private readonly int slot;
        private readonly bool fail;
        public static readonly int[] Calls = new int[3];

        public DisposeProbeStream(int slot, bool fail)
        {
            this.slot = slot;
            this.fail = fail;
        }

        protected override void Dispose(bool disposing)
        {
            Calls[slot]++;
            if (fail)
            {
                throw new InvalidOperationException(
                    "Synthetic stream cleanup failure.");
            }
            base.Dispose(disposing);
        }
    }
}
'@
        }
        for ($probeIndex = 0; $probeIndex -lt 3; $probeIndex++) {
            [PrivateMarker.Testing.DisposeProbeStream]::Calls[$probeIndex] = 0
        }
        $containedConstructor = @(
            [PrivateMarker.ContainedProcess].GetConstructors(
                [System.Reflection.BindingFlags]'Instance,NonPublic'
            ) | Where-Object {
                $_.GetParameters().Count -eq 7
            }
        )[0]
        $disposeProbeStreams = @(
            [PrivateMarker.Testing.DisposeProbeStream]::new(0, $true),
            [PrivateMarker.Testing.DisposeProbeStream]::new(1, $true),
            [PrivateMarker.Testing.DisposeProbeStream]::new(2, $false)
        )
        $disposeProbeProcess = $containedConstructor.Invoke(
            [object[]]@(
                [IntPtr]::Zero,
                $disposeProbeStreams[0],
                $disposeProbeStreams[1],
                $disposeProbeStreams[2],
                [IntPtr]::Zero,
                $false,
                0
            )
        )
        $disposeProbeFailureObserved = $false
        try {
            $disposeProbeProcess.Dispose()
        }
        catch {
            $disposeProbeFailureObserved = $true
        }
        if (-not $disposeProbeFailureObserved -or
            [PrivateMarker.Testing.DisposeProbeStream]::Calls[0] -ne 1 -or
            [PrivateMarker.Testing.DisposeProbeStream]::Calls[1] -ne 1 -or
            [PrivateMarker.Testing.DisposeProbeStream]::Calls[2] -ne 1) {
            Add-Failure 'Expected ContainedProcess cleanup to attempt every stream and aggregate multiple Dispose failures.'
        }

        # native handleはCloseHandle成功後だけownershipを0へ移す。失敗時に
        # ownershipを失うとDispose/finalizerが再試行できないため、invalid
        # synthetic handleで例外とref値保持を同時に検証する。
        $closeOwnedHandleMethod = [PrivateMarker.ContainedProcess].GetMethod(
            'CloseOwnedHandle',
            [System.Reflection.BindingFlags]'Static,NonPublic'
        )
        # 実在handleを一度closeしたstale値なら、偶然有効な数値を選ばず
        # CloseHandle失敗を決定的に作れる。再割当を挟まず直ちにprobeする。
        $closedHandleFixture = [System.Threading.EventWaitHandle]::new(
            $false,
            [System.Threading.EventResetMode]::ManualReset
        )
        $invalidOwnedHandle =
            $closedHandleFixture.SafeWaitHandle.DangerousGetHandle()
        $closedHandleFixture.Dispose()
        $closeOwnedArguments = [object[]]@($invalidOwnedHandle)
        $closeOwnedFailureObserved = $false
        try {
            [void]$closeOwnedHandleMethod.Invoke(
                $null,
                $closeOwnedArguments
            )
        }
        catch {
            $closeOwnedFailureObserved = $true
        }
        if (-not $closeOwnedFailureObserved -or
            [IntPtr]$closeOwnedArguments[0] -ne $invalidOwnedHandle) {
            Add-Failure 'Expected failed native handle close to preserve ownership for a later retry.'
        }
    }

    # PowerShell scriptはstdin先頭のUTF-8 BOMを受理し得るため、上のechoだけでは
    # Windows PowerShell 5.1のstdin復元を証明できない。native Gitのbatch
    # protocolへBOMなしASCIIを渡し、header・binary blob・終端LFをbyte単位で比較する。
    $rawGitCommands = @(
        Get-Command git -CommandType Application -ErrorAction SilentlyContinue
    )
    if ($rawGitCommands.Count -eq 0) {
        Add-Failure 'Expected native Git to be available for the raw transport regression.'
    } else {
        $rawGitPath = $rawGitCommands[0].Source
        $rawGitRoot = Join-Path $tempRoot 'raw-git-transport'
        $rawGitIsolationRoot = Join-Path $tempRoot 'raw-git-isolation'
        New-Item -ItemType Directory -Path $rawGitRoot | Out-Null
        New-Item -ItemType Directory -Path $rawGitIsolationRoot | Out-Null

        $rawGitInitResult = Invoke-HermeticGit `
            -WorkingDirectory $rawGitRoot `
            -IsolationRoot $rawGitIsolationRoot `
            -Arguments @('init', '-q')
        if ($rawGitInitResult.ExitCode -ne 0) {
            Add-Failure 'Expected the raw native Git transport fixture to initialize.'
        } else {
            [byte[]]$rawGitBlobBytes = @(0, 128, 255, 10, 13, 1, 2)
            [System.IO.File]::WriteAllBytes(
                (Join-Path $rawGitRoot 'blob.bin'),
                $rawGitBlobBytes
            )
            $rawGitHashResult = Invoke-HermeticGit `
                -WorkingDirectory $rawGitRoot `
                -IsolationRoot $rawGitIsolationRoot `
                -Arguments @('hash-object', '-w', '--', 'blob.bin')
            $rawGitObjectId = $rawGitHashResult.Output.Trim()
            if ($rawGitHashResult.ExitCode -ne 0 -or
                $rawGitObjectId -notmatch
                    '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') {
                Add-Failure 'Expected the raw native Git transport fixture to create a blob object.'
            } else {
                # helperが内部でencodingを調整する実装へ変わっても、callerの
                # console contractは呼出し前とbyte-for-byte同じ状態へ戻す。
                $inputCodePageBefore = [Console]::InputEncoding.CodePage
                $inputPreambleBefore = [Convert]::ToBase64String(
                    [Console]::InputEncoding.GetPreamble()
                )
                $rawGitBatchInput = [Text.Encoding]::ASCII.GetBytes(
                    "$rawGitObjectId`n"
                )
                $rawGitHeaderBytes = [Text.Encoding]::ASCII.GetBytes(
                    "$rawGitObjectId blob $($rawGitBlobBytes.Length)`n"
                )
                [byte[]]$expectedRawGitOutput = @(
                    @($rawGitHeaderBytes) +
                    @($rawGitBlobBytes) +
                    @(10)
                )
                $rawGitBatchResult = Invoke-PrivateMarkerProcess `
                    -FileName $rawGitPath `
                    -Arguments @('cat-file', '--batch') `
                    -StandardInputBytes $rawGitBatchInput `
                    -WorkingDirectory $rawGitRoot `
                    -SanitizeGitEnvironment `
                    -IsolationRoot $rawGitIsolationRoot `
                    -MaximumStandardInputBytes $rawGitBatchInput.Length `
                    -MaximumStandardOutputBytes $expectedRawGitOutput.Length `
                    -MaximumStandardErrorBytes 4096 `
                    -TimeoutMilliseconds 20000
                if ($rawGitBatchResult.ExitCode -ne 0 -or
                    $rawGitBatchResult.TimedOut -or
                    $rawGitBatchResult.OutputLimitExceeded -or
                    $rawGitBatchResult.InputWriteFailed -or
                    $rawGitBatchResult.PipeLeakDetected -or
                    -not $rawGitBatchResult.StreamsCompleted -or
                    -not $rawGitBatchResult.TreeStopped -or
                    $rawGitBatchResult.StandardErrorBytes.Length -ne 0 -or
                    -not (Test-ByteArraysEqual `
                        -Expected $expectedRawGitOutput `
                        -Actual $rawGitBatchResult.StandardOutputBytes)) {
                    Add-Failure 'Expected native Git cat-file batch transport to remain byte-exact without a UTF-8 preamble.'
                }
                if ([Console]::InputEncoding.CodePage -ne
                        $inputCodePageBefore -or
                    [Convert]::ToBase64String(
                        [Console]::InputEncoding.GetPreamble()
                    ) -ne $inputPreambleBefore) {
                    Add-Failure 'Expected raw native Git transport to restore the caller console input encoding exactly.'
                }
            }
        }
    }

    if (-not (Test-PrivateMarkerWindowsHost)) {
        # forced native POSIX gateはpayloadをUTF-8 JSON→Unicode EncodedCommand
        # で中継する。日本語・空白・引用符・backslashを含む1引数を、childが
        # 出力したUTF-8 bytesまで比較してencoding/quoting driftを検出する。
        $posixArgumentEchoPath = Join-Path $tempRoot 'PosixArgumentEcho.ps1'
        $posixArgumentEchoSource = @'
param([string]$Value)
$bytes = [Text.Encoding]::UTF8.GetBytes($Value)
$stream = [Console]::OpenStandardOutput()
$stream.Write($bytes, 0, $bytes.Length)
$stream.Flush()
'@
        [System.IO.File]::WriteAllText(
            $posixArgumentEchoPath,
            $posixArgumentEchoSource,
            [System.Text.UTF8Encoding]::new($false)
        )
        $posixArgumentValue =
            ([char]0x5883).ToString() + [char]0x754C +
            ' spaced "quote" \backslash'
        $expectedPosixArgumentBytes =
            [Text.Encoding]::UTF8.GetBytes($posixArgumentValue)
        $posixArgumentResult = Invoke-PrivateMarkerProcess `
            -FileName $currentPowerShellExecutable `
            -Arguments @(
                '-NoProfile',
                '-File',
                $posixArgumentEchoPath,
                $posixArgumentValue
            ) `
            -WorkingDirectory $tempRoot `
            -IsolationRoot (Join-Path $tempRoot 'posix-encoding-isolation') `
            -MaximumStandardOutputBytes $expectedPosixArgumentBytes.Length `
            -MaximumStandardErrorBytes 4096 `
            -TimeoutMilliseconds 10000 `
            -ForceNativePosixSessionGate
        if ($posixArgumentResult.ExitCode -ne 0 -or
            $posixArgumentResult.TimedOut -or
            $posixArgumentResult.OutputLimitExceeded -or
            $posixArgumentResult.InputWriteFailed -or
            $posixArgumentResult.PipeLeakDetected -or
            -not $posixArgumentResult.ContainmentEstablished -or
            -not $posixArgumentResult.StreamsCompleted -or
            -not $posixArgumentResult.TreeStopped -or
            $posixArgumentResult.StandardErrorBytes.Length -ne 0 -or
            -not (Test-ByteArraysEqual `
                -Expected $expectedPosixArgumentBytes `
                -Actual $posixArgumentResult.StandardOutputBytes)) {
            Add-Failure 'Expected forced native POSIX session gate to preserve one Unicode argument byte-exactly.'
        }
    }

    # Prefix・UTF-8 multibyte・実platform改行をすべて含めたraw byte数で、
    # exact limitは成功し、1 byte超過だけがbounded failureになることを確認する。
    $boundaryEmitterPath = Join-Path $tempRoot 'RawBoundaryEmitter.ps1'
    $boundaryEmitterSource = @'
param([int]$TotalBytes)
$prefixText = ([char]0x5883).ToString() + [char]0x754C + ':'
$prefixBytes = [System.Text.Encoding]::UTF8.GetBytes($prefixText)
$newlineBytes = [System.Text.Encoding]::UTF8.GetBytes(
    [Environment]::NewLine
)
if ($TotalBytes -lt ($prefixBytes.Length + $newlineBytes.Length)) {
    throw 'Requested payload is too small.'
}
$payload = New-Object byte[] $TotalBytes
[Array]::Copy($prefixBytes, 0, $payload, 0, $prefixBytes.Length)
for ($index = $prefixBytes.Length;
    $index -lt ($payload.Length - $newlineBytes.Length);
    $index++) {
    $payload[$index] = [byte][char]'x'
}
[Array]::Copy(
    $newlineBytes,
    0,
    $payload,
    $payload.Length - $newlineBytes.Length,
    $newlineBytes.Length
)
$stream = [Console]::OpenStandardOutput()
$stream.Write($payload, 0, $payload.Length)
$stream.Flush()
'@
    [System.IO.File]::WriteAllText(
        $boundaryEmitterPath,
        $boundaryEmitterSource,
        [System.Text.UTF8Encoding]::new($true)
    )
    $boundaryHostArguments = @('-NoProfile')
    if ($PSVersionTable.PSVersion.Major -le 5 -and
        (Test-PrivateMarkerWindowsHost)) {
        $boundaryHostArguments += @('-ExecutionPolicy', 'Bypass')
    }
    $boundaryLimit = 65536
    $withinBoundaryResult = Invoke-PrivateMarkerProcess `
        -FileName $currentPowerShellExecutable `
        -Arguments (
            $boundaryHostArguments +
            @('-File', $boundaryEmitterPath, $boundaryLimit)
        ) `
        -WorkingDirectory $tempRoot `
        -MaximumStandardOutputBytes $boundaryLimit `
        -MaximumStandardErrorBytes 8192 `
        -TimeoutMilliseconds 10000
    $expectedBoundaryPrefix = [System.Text.Encoding]::UTF8.GetBytes(
        ([char]0x5883).ToString() + [char]0x754C + ':'
    )
    $expectedBoundaryNewline = [System.Text.Encoding]::UTF8.GetBytes(
        [Environment]::NewLine
    )
    $boundaryPrefixMatches =
        $withinBoundaryResult.StandardOutputBytes.Length -ge
            $expectedBoundaryPrefix.Length
    if ($boundaryPrefixMatches) {
        for ($index = 0;
            $index -lt $expectedBoundaryPrefix.Length;
            $index++) {
            if ($withinBoundaryResult.StandardOutputBytes[$index] -ne
                $expectedBoundaryPrefix[$index]) {
                $boundaryPrefixMatches = $false
                break
            }
        }
    }
    $boundaryNewlineMatches =
        $withinBoundaryResult.StandardOutputBytes.Length -ge
            $expectedBoundaryNewline.Length
    if ($boundaryNewlineMatches) {
        $newlineOffset =
            $withinBoundaryResult.StandardOutputBytes.Length -
            $expectedBoundaryNewline.Length
        for ($index = 0;
            $index -lt $expectedBoundaryNewline.Length;
            $index++) {
            if ($withinBoundaryResult.StandardOutputBytes[
                    $newlineOffset + $index
                ] -ne $expectedBoundaryNewline[$index]) {
                $boundaryNewlineMatches = $false
                break
            }
        }
    }
    if ($withinBoundaryResult.ExitCode -ne 0 -or
        $withinBoundaryResult.OutputLimitExceeded -or
        -not $withinBoundaryResult.StreamsCompleted -or
        -not $withinBoundaryResult.TreeStopped -or
        $withinBoundaryResult.StandardOutputBytes.Length -ne $boundaryLimit -or
        -not $boundaryPrefixMatches -or
        -not $boundaryNewlineMatches) {
        Add-Failure 'Expected the exact raw UTF-8 output boundary, including prefix and platform newline, to pass.'
    }

    $overBoundaryResult = Invoke-PrivateMarkerProcess `
        -FileName $currentPowerShellExecutable `
        -Arguments (
            $boundaryHostArguments +
            @('-File', $boundaryEmitterPath, ($boundaryLimit + 1))
        ) `
        -WorkingDirectory $tempRoot `
        -MaximumStandardOutputBytes $boundaryLimit `
        -MaximumStandardErrorBytes 8192 `
        -TimeoutMilliseconds 10000
    if (-not $overBoundaryResult.OutputLimitExceeded -or
        -not $overBoundaryResult.TreeStopped -or
        $overBoundaryResult.StandardOutputBytes.Length -gt $boundaryLimit) {
        Add-Failure 'Expected one raw UTF-8 byte beyond the output boundary to stop fail-closed.'
    }

    # Hostile user pathはResolve-Path前後のprovider例外からもraw出力しない。
    $hostilePathPrefix =
        'hostile-nonexistent-' + [System.Guid]::NewGuid().ToString('N')
    $hostilePathCharacters = @(
        [char]0x202E,
        [char]0x2028,
        [char]0x2029
    )
    $hostileMissingPath = Join-Path $tempRoot (
        $hostilePathPrefix +
        ($hostilePathCharacters -join '-') +
        '-spoof'
    )
    $hostileArguments = @('-NoProfile')
    if ($PSVersionTable.PSVersion.Major -le 5 -and
        (Test-PrivateMarkerWindowsHost)) {
        $hostileArguments += @('-ExecutionPolicy', 'Bypass')
    }
    $hostileArguments += @(
        '-File',
        $scanner,
        '-Path',
        $hostileMissingPath
    )
    $hostilePathResult = Invoke-PrivateMarkerProcess `
        -FileName $currentPowerShellExecutable `
        -Arguments $hostileArguments `
        -WorkingDirectory $root `
        -MaximumStandardOutputBytes 256 `
        -MaximumStandardErrorBytes 512 `
        -TimeoutMilliseconds 10000
    $hostileCombinedBytes = New-Object byte[] (
        $hostilePathResult.StandardOutputBytes.Length +
        $hostilePathResult.StandardErrorBytes.Length
    )
    [Array]::Copy(
        $hostilePathResult.StandardOutputBytes,
        0,
        $hostileCombinedBytes,
        0,
        $hostilePathResult.StandardOutputBytes.Length
    )
    [Array]::Copy(
        $hostilePathResult.StandardErrorBytes,
        0,
        $hostileCombinedBytes,
        $hostilePathResult.StandardOutputBytes.Length,
        $hostilePathResult.StandardErrorBytes.Length
    )
    $hostileFixedDiagnostic =
        'Private marker scan failed closed (integrity: scan-root-missing).'
    $expectedHostileStdout = New-Object byte[] 0
    $expectedHostileStderr = [System.Text.Encoding]::UTF8.GetBytes(
        $hostileFixedDiagnostic + [Environment]::NewLine
    )
    $hostileLeakDetected = $false
    # exact bytesだけでframing混入は検出できるが、絶対pathとUnicode制御の
    # 非出力契約も個別に残し、regressionの原因を一意にする。
    foreach ($sensitiveText in @(
        $scanner,
        $hostileMissingPath,
        $hostilePathPrefix
    )) {
        foreach ($encoding in @(
            [System.Text.Encoding]::UTF8,
            [System.Text.Encoding]::Unicode,
            [System.Text.Encoding]::BigEndianUnicode
        )) {
            if (Test-ByteArrayContainsSequence `
                    -Haystack $hostileCombinedBytes `
                    -Needle $encoding.GetBytes($sensitiveText)) {
                $hostileLeakDetected = $true
            }
        }
    }
    foreach ($hostileCharacter in $hostilePathCharacters) {
        if (Test-ByteArrayContainsSequence `
                -Haystack $hostileCombinedBytes `
                -Needle (
                    [System.Text.Encoding]::UTF8.GetBytes(
                        [string]$hostileCharacter
                    )
                )) {
            $hostileLeakDetected = $true
        }
    }
    if ($hostilePathResult.ExitCode -ne 2 -or
        $hostilePathResult.OutputLimitExceeded -or
        -not $hostilePathResult.StreamsCompleted -or
        -not $hostilePathResult.TreeStopped -or
        $hostilePathResult.StandardOutputBytes.Length -gt 256 -or
        $hostilePathResult.StandardErrorBytes.Length -gt 512 -or
        -not (Test-ByteArraysEqual `
            -Expected $expectedHostileStdout `
            -Actual $hostilePathResult.StandardOutputBytes) -or
        -not (Test-ByteArraysEqual `
            -Expected $expectedHostileStderr `
            -Actual $hostilePathResult.StandardErrorBytes) -or
        $hostileLeakDetected) {
        Add-Failure 'Expected hostile nonexistent scan paths to emit exactly one fixed stderr code plus the platform newline.'
    }

    # helper欠落・dot-source例外・helper実行例外・isolation作成/削除例外を、
    # absolute repo/temp/helper pathを含まない同一の固定stderr + exit 2へ畳み込む。
    $boundaryFixtureRoot =
        Join-Path $tempRoot 'process-boundary-failures'
    New-Item `
        -ItemType Directory `
        -Path $boundaryFixtureRoot |
        Out-Null
    $scannerSourceBytes = [IO.File]::ReadAllBytes($scanner)
    $boundaryCases =
        New-Object System.Collections.Generic.List[object]

    $missingHelperRoot = Join-Path $boundaryFixtureRoot 'missing-helper'
    New-Item -ItemType Directory -Path $missingHelperRoot | Out-Null
    $missingHelperScanner =
        Join-Path $missingHelperRoot 'scan-private-markers.ps1'
    [IO.File]::WriteAllBytes(
        $missingHelperScanner,
        $scannerSourceBytes
    )
    $boundaryCases.Add([pscustomobject]@{
        Name = 'missing-helper'
        ScannerPath = $missingHelperScanner
        AdditionalArguments = @()
        EnvironmentOverrides = @{}
        SensitiveTexts = @(
            $root,
            $tempRoot,
            $missingHelperRoot,
            (Join-Path $missingHelperRoot 'private-marker-process.ps1')
        )
    }) | Out-Null

    $throwingHelperRoot = Join-Path $boundaryFixtureRoot 'throwing-helper'
    New-Item -ItemType Directory -Path $throwingHelperRoot | Out-Null
    $throwingHelperScanner =
        Join-Path $throwingHelperRoot 'scan-private-markers.ps1'
    $throwingHelperPath =
        Join-Path $throwingHelperRoot 'private-marker-process.ps1'
    [IO.File]::WriteAllBytes(
        $throwingHelperScanner,
        $scannerSourceBytes
    )
    [IO.File]::WriteAllText(
        $throwingHelperPath,
        "throw 'synthetic helper failure at $throwingHelperPath'",
        [Text.UTF8Encoding]::new($false)
    )
    $boundaryCases.Add([pscustomobject]@{
        Name = 'throwing-helper'
        ScannerPath = $throwingHelperScanner
        AdditionalArguments = @()
        EnvironmentOverrides = @{}
        SensitiveTexts = @(
            $root,
            $tempRoot,
            $throwingHelperRoot,
            $throwingHelperPath
        )
    }) | Out-Null

    $runtimeHelperRoot = Join-Path $boundaryFixtureRoot 'runtime-helper'
    New-Item -ItemType Directory -Path $runtimeHelperRoot | Out-Null
    $runtimeHelperScanner =
        Join-Path $runtimeHelperRoot 'scan-private-markers.ps1'
    $runtimeHelperPath =
        Join-Path $runtimeHelperRoot 'private-marker-process.ps1'
    [IO.File]::WriteAllBytes(
        $runtimeHelperScanner,
        $scannerSourceBytes
    )
    $escapedRuntimeHelperPath = $runtimeHelperPath.Replace("'", "''")
    $runtimeHelperSource = @"
function Test-PrivateMarkerWindowsHost {
    return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}
function Invoke-PrivateMarkerProcess {
    throw 'synthetic process helper failure at $escapedRuntimeHelperPath'
}
"@
    [IO.File]::WriteAllText(
        $runtimeHelperPath,
        $runtimeHelperSource,
        [Text.UTF8Encoding]::new($false)
    )
    $boundaryCases.Add([pscustomobject]@{
        Name = 'runtime-helper'
        ScannerPath = $runtimeHelperScanner
        AdditionalArguments = @()
        EnvironmentOverrides = @{}
        SensitiveTexts = @(
            $root,
            $tempRoot,
            $runtimeHelperRoot,
            $runtimeHelperPath
        )
    }) | Out-Null

    $boundaryTempRoot = Join-Path $tempRoot 'scanner-isolation-temp'
    New-Item -ItemType Directory -Path $boundaryTempRoot | Out-Null
    $boundaryTempEnvironment = @{
        'TEMP' = $boundaryTempRoot
        'TMP' = $boundaryTempRoot
        'TMPDIR' = $boundaryTempRoot
    }
    foreach ($isolationFailureMode in @(
        'isolation-create',
        'isolation-remove'
    )) {
        $boundaryCases.Add([pscustomobject]@{
            Name = $isolationFailureMode
            ScannerPath = $scanner
            AdditionalArguments = @(
                '-TestBoundaryFailure',
                $isolationFailureMode
            )
            EnvironmentOverrides = $boundaryTempEnvironment
            SensitiveTexts = @(
                $root,
                $tempRoot,
                $boundaryTempRoot,
                $scanner,
                $processBoundary
            )
        }) | Out-Null
    }
    # process helper failureのunwind中にcleanupも失敗しても、固定診断は
    # 二重出力せず最初の1行だけを維持する。
    $boundaryCases.Add([pscustomobject]@{
        Name = 'runtime-helper-plus-isolation-remove'
        ScannerPath = $runtimeHelperScanner
        AdditionalArguments = @(
            '-TestBoundaryFailure',
            'isolation-remove'
        )
        EnvironmentOverrides = $boundaryTempEnvironment
        SensitiveTexts = @(
            $root,
            $tempRoot,
            $runtimeHelperRoot,
            $runtimeHelperPath,
            $boundaryTempRoot
        )
    }) | Out-Null

    foreach ($boundaryCase in $boundaryCases) {
        $boundaryResult = Invoke-Scanner `
            -ScanPath $root `
            -ScannerPath $boundaryCase.ScannerPath `
            -AdditionalArguments $boundaryCase.AdditionalArguments `
            -EnvironmentOverrides $boundaryCase.EnvironmentOverrides
        if (-not (Test-FixedIntegrityFailureResult `
                -Result $boundaryResult `
                -Reason 'process-boundary' `
                -SensitiveTexts $boundaryCase.SensitiveTexts)) {
            Add-Failure "Expected $($boundaryCase.Name) to emit one redacted process-boundary diagnostic and exit 2."
        }
    }

    if (-not (Test-PrivateMarkerWindowsHost)) {
        # external setsid / native fallbackの両方で、child ready後に実PID=PGIDを
        # kernel確認してからtargetをreleaseする。direct parentが終了済みでも、
        # 同じprocess groupの孫とinherited pipeを確実に閉じる。
        $posixSurvivedSentinels =
            New-Object System.Collections.Generic.List[string]
        foreach ($forceNativeGate in @($false, $true)) {
            $gateLabel = if ($forceNativeGate) { 'native' } else { 'setsid' }
            $startedSentinel =
                Join-Path $tempRoot "posix-$gateLabel-started.txt"
            $survivedSentinel =
                Join-Path $tempRoot "posix-$gateLabel-survived.txt"
            $posixSurvivedSentinels.Add($survivedSentinel) | Out-Null
            $escapedStartedSentinel = $startedSentinel.Replace("'", "''")
            $escapedSurvivedSentinel = $survivedSentinel.Replace("'", "''")
            $posixGrandchildTemplate = @'
[System.IO.File]::WriteAllText(
    '__STARTED__',
    'started',
    [System.Text.UTF8Encoding]::new($false)
)
Start-Sleep -Milliseconds 1500
[System.IO.File]::WriteAllText(
    '__SURVIVED__',
    'survived',
    [System.Text.UTF8Encoding]::new($false)
)
[Console]::Out.Write('late-output')
'@
            $posixGrandchildScript = $posixGrandchildTemplate.Replace(
                '__STARTED__',
                $escapedStartedSentinel
            ).Replace(
                '__SURVIVED__',
                $escapedSurvivedSentinel
            )
            $posixGrandchildEncoded = [Convert]::ToBase64String(
                [System.Text.Encoding]::Unicode.GetBytes(
                    $posixGrandchildScript
                )
            )
            $escapedPowerShellExecutable =
                $currentPowerShellExecutable.Replace("'", "''")
            $posixParentTemplate = @'
$ErrorActionPreference = 'Stop'
$startInfo = New-Object System.Diagnostics.ProcessStartInfo
$startInfo.FileName = '__HOST__'
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.ArgumentList.Add('-NoProfile')
$startInfo.ArgumentList.Add('-EncodedCommand')
$startInfo.ArgumentList.Add('__PAYLOAD__')
$child = [System.Diagnostics.Process]::Start($startInfo)
try {
    $started = $false
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        if ([System.IO.File]::Exists('__STARTED__')) {
            $started = $true
            break
        }
        Start-Sleep -Milliseconds 10
    }
    if (-not $started) {
        exit 125
    }
}
finally {
    $child.Dispose()
}
'@
            $posixParentScript = $posixParentTemplate.Replace(
                '__HOST__',
                $escapedPowerShellExecutable
            ).Replace(
                '__PAYLOAD__',
                $posixGrandchildEncoded
            ).Replace(
                '__STARTED__',
                $escapedStartedSentinel
            )
            $posixParentEncoded = [Convert]::ToBase64String(
                [System.Text.Encoding]::Unicode.GetBytes($posixParentScript)
            )
            $posixPipeResult = Invoke-PrivateMarkerProcess `
                -FileName $currentPowerShellExecutable `
                -Arguments @(
                    '-NoProfile',
                    '-EncodedCommand',
                    $posixParentEncoded
                ) `
                -WorkingDirectory $tempRoot `
                -IsolationRoot (
                    Join-Path $tempRoot "posix-$gateLabel-isolation"
                ) `
                -TimeoutMilliseconds 10000 `
                -StreamCompletionWaitMilliseconds 250 `
                -StreamCleanupWaitMilliseconds 2000 `
                -ForceNativePosixSessionGate:$forceNativeGate
            if (-not $posixPipeResult.PipeLeakDetected -or
                $posixPipeResult.StreamsCompleted -or
                -not $posixPipeResult.ContainmentEstablished -or
                -not $posixPipeResult.TreeStopped -or
                $posixPipeResult.TimedOut -or
                $posixPipeResult.OutputLimitExceeded -or
                $posixPipeResult.InputWriteFailed) {
                Add-Failure "Expected POSIX $gateLabel ready handshake to establish a verified process group before stopping the child-held pipe."
            }
            if (-not (Test-Path -LiteralPath $startedSentinel -PathType Leaf)) {
                Add-Failure "Expected POSIX $gateLabel containment fixture to prove that its descendant started."
            }
        }
        Start-Sleep -Milliseconds 1750
        foreach ($survivedSentinel in $posixSurvivedSentinels) {
            if (Test-Path -LiteralPath $survivedSentinel) {
                Add-Failure 'Expected POSIX process-group cleanup to stop every delayed descendant sentinel.'
                break
            }
        }

        # kill(2)の戻り値-1は同じでも、ESRCHだけを「既に停止済み」と
        # みなし、EPERM/EACCESをTreeStopped成功へ昇格させない。
        if (-not [PrivateMarker.PosixSignal]::IsSuccessfulResult(0, 0) -or
            -not [PrivateMarker.PosixSignal]::IsSuccessfulResult(-1, 3) -or
            [PrivateMarker.PosixSignal]::IsSuccessfulResult(-1, 1) -or
            [PrivateMarker.PosixSignal]::IsSuccessfulResult(-1, 13)) {
            Add-Failure 'Expected POSIX cleanup to accept success/ESRCH and reject EPERM/EACCES.'
        }

        # ready recordはdirect launcher PIDとlaunch nonceへexactにbindする。
        # forged PID、same-length forged nonce、UTF-8 BOM、partial recordは
        # いずれもtargetをreleaseせず、bounded cleanup後に固定failureへ閉じる。
        foreach ($readyFailureMode in @(
            'forged-pid',
            'forged-nonce',
            'bom',
            'partial'
        )) {
            $invalidReadySentinel = Join-Path `
                $tempRoot `
                "posix-invalid-ready-$readyFailureMode-ran.txt"
            $escapedInvalidReadySentinel =
                $invalidReadySentinel.Replace("'", "''")
            $invalidReadyScript = @"
[IO.File]::WriteAllText('$escapedInvalidReadySentinel', 'ran')
"@
            $invalidReadyEncoded = [Convert]::ToBase64String(
                [Text.Encoding]::Unicode.GetBytes($invalidReadyScript)
            )
            $invalidReadyFailure = $null
            $invalidReadyStopwatch = [Diagnostics.Stopwatch]::StartNew()
            try {
                [void](Invoke-PrivateMarkerProcess `
                    -FileName $currentPowerShellExecutable `
                    -Arguments @(
                        '-NoProfile',
                        '-EncodedCommand',
                        $invalidReadyEncoded
                    ) `
                    -WorkingDirectory $tempRoot `
                    -IsolationRoot (
                        Join-Path `
                            $tempRoot `
                            "posix-invalid-ready-$readyFailureMode-isolation"
                    ) `
                    -TimeoutMilliseconds 1000 `
                    -ForcePosixGateFailure $readyFailureMode)
            }
            catch {
                $invalidReadyFailure = $_.Exception
            }
            $invalidReadyStopwatch.Stop()
            if ($null -eq $invalidReadyFailure -or
                $invalidReadyFailure.Message -notmatch
                    'Failed to establish the bounded POSIX session gate' -or
                $invalidReadyStopwatch.ElapsedMilliseconds -ge 2000 -or
                (Test-Path -LiteralPath $invalidReadySentinel)) {
                Add-Failure "Expected POSIX $readyFailureMode ready record to fail closed before target release."
            }
        }

        # session gateの待機もcaller timeoutを消費する。readyを遅延する
        # synthetic seamで、旧固定10秒pollへ戻らず短いdeadlineで停止する。
        $delayedReadySentinel =
            Join-Path $tempRoot 'posix-delayed-ready-ran.txt'
        $escapedDelayedReadySentinel =
            $delayedReadySentinel.Replace("'", "''")
        $delayedReadyScript = @"
[IO.File]::WriteAllText('$escapedDelayedReadySentinel', 'ran')
"@
        $delayedReadyEncoded = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes($delayedReadyScript)
        )
        $delayedReadyFailure = $null
        $delayedReadyStopwatch = [Diagnostics.Stopwatch]::StartNew()
        try {
            [void](Invoke-PrivateMarkerProcess `
                -FileName $currentPowerShellExecutable `
                -Arguments @(
                    '-NoProfile',
                    '-EncodedCommand',
                    $delayedReadyEncoded
                ) `
                -WorkingDirectory $tempRoot `
                -IsolationRoot (
                    Join-Path $tempRoot 'posix-delayed-ready-isolation'
                ) `
                -TimeoutMilliseconds 50 `
                -ForcePosixGateFailure 'delay')
        }
        catch {
            $delayedReadyFailure = $_.Exception
        }
        $delayedReadyStopwatch.Stop()
        if ($null -eq $delayedReadyFailure -or
            $delayedReadyFailure.Message -notmatch
                'Failed to establish the bounded POSIX session gate' -or
            $delayedReadyStopwatch.ElapsedMilliseconds -ge 1500 -or
            (Test-Path -LiteralPath $delayedReadySentinel)) {
            Add-Failure 'Expected POSIX session-gate startup to consume the caller monotonic timeout.'
        }

        # ready recordとPGIDが正しくても、release直前に同じcaller期限を
        # 再確認する。test-only delayで期限を跨がせ、target未実行を固定する。
        $posixExpiredReleaseSentinel =
            Join-Path $tempRoot 'posix-expired-release-ran.txt'
        $escapedPosixExpiredReleaseSentinel =
            $posixExpiredReleaseSentinel.Replace("'", "''")
        $posixExpiredReleaseScript = @"
[IO.File]::WriteAllText('$escapedPosixExpiredReleaseSentinel', 'ran')
"@
        $posixExpiredReleaseEncoded = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes(
                $posixExpiredReleaseScript
            )
        )
        $posixExpiredReleaseResult = $null
        try {
            # macOS native wrapperはcold Add-Typeを含む。sub-second起動を
            # 成功条件にせず5秒でreadyを待ち、その後のtest-only 5.5秒delayで
            # 同じcaller deadlineを確実に跨いでrelease禁止を検証する。
            $posixExpiredReleaseResult = Invoke-PrivateMarkerProcess `
                -FileName $currentPowerShellExecutable `
                -Arguments @(
                    '-NoProfile',
                    '-EncodedCommand',
                    $posixExpiredReleaseEncoded
                ) `
                -WorkingDirectory $tempRoot `
                -IsolationRoot (
                    Join-Path $tempRoot 'posix-expired-release-isolation'
                ) `
                -TimeoutMilliseconds 5000 `
                -ForcePosixGateFailure 'release-delay'
        }
        catch {
            # path・引数・inner messageを再掲せず、失敗fixtureだけを固定する。
            throw [System.InvalidOperationException]::new(
                'POSIX release-deadline fixture failed before deadline validation.'
            )
        }
        Start-Sleep -Milliseconds 100
        if (-not $posixExpiredReleaseResult.TimedOut -or
            -not $posixExpiredReleaseResult.ContainmentEstablished -or
            -not $posixExpiredReleaseResult.TreeStopped -or
            (Test-Path -LiteralPath $posixExpiredReleaseSentinel)) {
            Add-Failure 'Expected POSIX target release to remain blocked after the caller deadline.'
        }
    }

    if (Test-PrivateMarkerWindowsHost) {
        # Git が存在して timeout した場合は working-tree fallback へ降格しない。
        $syntheticGitDirectory = Join-Path $tempRoot 'synthetic-git'
        $syntheticGitPath = Join-Path $syntheticGitDirectory 'git.exe'
        $slowGitSentinel = Join-Path $tempRoot 'slow-git-survived.txt'
        New-Item -ItemType Directory -Path $syntheticGitDirectory | Out-Null
        $syntheticGitSourcePath = Join-Path $syntheticGitDirectory 'SyntheticGit.cs'
        $syntheticGitControlPath =
            Join-Path $syntheticGitDirectory 'SyntheticGit.control'
        $syntheticGitCompilerPath = Join-Path $syntheticGitDirectory 'compile-synthetic-git.ps1'
        $syntheticGitSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public static class SyntheticGitProgram
{
    private static Dictionary<string, string> ReadControlFile()
    {
        var executableDirectory = Path.GetDirectoryName(
            Assembly.GetExecutingAssembly().Location);
        var controlPath = Path.Combine(
            executableDirectory,
            "SyntheticGit.control");
        var controlInfo = new FileInfo(controlPath);
        if (!controlInfo.Exists || controlInfo.Length > 65536)
        {
            throw new InvalidDataException("Synthetic Git control file is invalid.");
        }

        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        var strictUtf8 = new UTF8Encoding(false, true);
        foreach (var line in File.ReadAllLines(controlPath, strictUtf8))
        {
            var separator = line.IndexOf('=');
            if (separator <= 0)
            {
                throw new InvalidDataException("Synthetic Git control record is invalid.");
            }
            var name = line.Substring(0, separator);
            var encodedValue = line.Substring(separator + 1);
            if (values.ContainsKey(name))
            {
                throw new InvalidDataException("Synthetic Git control key is duplicated.");
            }
            values.Add(
                name,
                strictUtf8.GetString(Convert.FromBase64String(encodedValue)));
        }
        return values;
    }

    private static string RequireControl(
        Dictionary<string, string> values,
        string name)
    {
        string value;
        if (!values.TryGetValue(name, out value) || String.IsNullOrEmpty(value))
        {
            throw new InvalidDataException("Synthetic Git control key is missing.");
        }
        return value;
    }

    private static string QuoteArgument(string argument)
    {
        if (String.IsNullOrEmpty(argument))
        {
            return "\"\"";
        }
        if (argument.IndexOfAny(new[] { ' ', '\t', '"' }) < 0)
        {
            return argument;
        }

        var output = new StringBuilder("\"");
        var backslashes = 0;
        foreach (var character in argument)
        {
            if (character == '\\')
            {
                backslashes++;
                continue;
            }
            if (character == '"')
            {
                output.Append('\\', (backslashes * 2) + 1);
                output.Append('"');
                backslashes = 0;
                continue;
            }
            output.Append('\\', backslashes);
            backslashes = 0;
            output.Append(character);
        }
        output.Append('\\', backslashes * 2);
        output.Append('"');
        return output.ToString();
    }

    private static int Run(string fileName, string[] arguments, int timeoutMilliseconds)
    {
        var forwardsInput = Array.IndexOf(arguments, "cat-file") >= 0 &&
            Array.IndexOf(arguments, "--batch") >= 0;
        var startInfo = new ProcessStartInfo {
            FileName = fileName,
            Arguments = String.Join(" ", Array.ConvertAll(arguments, QuoteArgument)),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = forwardsInput,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        using (var process = Process.Start(startInfo))
        {
            var stdoutTask = process.StandardOutput.BaseStream.CopyToAsync(
                Console.OpenStandardOutput());
            var stderrTask = process.StandardError.BaseStream.CopyToAsync(
                Console.OpenStandardError());
            if (forwardsInput)
            {
                var inputTask = Console.OpenStandardInput().CopyToAsync(
                    process.StandardInput.BaseStream);
                if (!inputTask.Wait(5000))
                {
                    process.Kill();
                    process.WaitForExit(5000);
                    return 123;
                }
                process.StandardInput.Close();
            }
            if (!process.WaitForExit(timeoutMilliseconds))
            {
                process.Kill();
                process.WaitForExit(5000);
                return 124;
            }
            if (!Task.WaitAll(new[] { stdoutTask, stderrTask }, 5000))
            {
                return 125;
            }
            Console.Out.Flush();
            Console.Error.Flush();
            return process.ExitCode;
        }
    }

    private static bool IsStageListing(string[] arguments)
    {
        return Array.IndexOf(arguments, "ls-files") >= 0 &&
            Array.IndexOf(arguments, "--stage") >= 0 &&
            Array.IndexOf(arguments, "-z") >= 0 &&
            Array.IndexOf(arguments, "--debug") < 0;
    }

    private static bool IsDebugStageListing(string[] arguments)
    {
        return Array.IndexOf(arguments, "ls-files") >= 0 &&
            Array.IndexOf(arguments, "--stage") >= 0 &&
            Array.IndexOf(arguments, "-z") >= 0 &&
            Array.IndexOf(arguments, "--debug") >= 0;
    }

    private static int NextStageListingCount(string counterPath)
    {
        using (var stream = new FileStream(
            counterPath,
            FileMode.OpenOrCreate,
            FileAccess.ReadWrite,
            FileShare.None))
        {
            if (stream.Length > 32)
            {
                throw new InvalidDataException("Synthetic Git counter is invalid.");
            }
            var bytes = new byte[(int)stream.Length];
            var offset = 0;
            while (offset < bytes.Length)
            {
                var read = stream.Read(bytes, offset, bytes.Length - offset);
                if (read == 0)
                {
                    throw new EndOfStreamException();
                }
                offset += read;
            }

            var count = 0;
            if (bytes.Length > 0 &&
                !Int32.TryParse(Encoding.ASCII.GetString(bytes), out count))
            {
                throw new InvalidDataException("Synthetic Git counter is invalid.");
            }
            count++;
            var nextBytes = Encoding.ASCII.GetBytes(count.ToString());
            stream.Position = 0;
            stream.SetLength(0);
            stream.Write(nextBytes, 0, nextBytes.Length);
            stream.Flush(true);
            return count;
        }
    }

    public static int Main(string[] args)
    {
        var control = ReadControlFile();
        var mode = RequireControl(control, "Mode");
        if (String.Equals(
            mode,
            "index-mutation",
            StringComparison.Ordinal))
        {
            var realGit = RequireControl(control, "RealGit");
            var counterPath = RequireControl(control, "IndexCounter");
            if (IsStageListing(args) && NextStageListingCount(counterPath) == 2)
            {
                var mutationExit = Run(
                    realGit,
                    new[] {
                        "-C",
                        RequireControl(control, "IndexRepository"),
                        "add",
                        "--",
                        RequireControl(control, "IndexReplacement"),
                        RequireControl(control, "IndexAddition")
                    },
                    5000);
                if (mutationExit != 0)
                {
                    return 90;
                }
                File.WriteAllText(
                    RequireControl(control, "IndexMutationSentinel"),
                    "mutated",
                    new UTF8Encoding(false));
            }
            return Run(realGit, args, 20000);
        }

        if (String.Equals(
            mode,
            "flags-mutation",
            StringComparison.Ordinal))
        {
            var realGit = RequireControl(control, "RealGit");
            var counterPath = RequireControl(control, "IndexCounter");
            if (IsDebugStageListing(args) && NextStageListingCount(counterPath) == 2)
            {
                var repository = RequireControl(control, "IndexRepository");
                var relativePath = RequireControl(control, "IndexReplacement");
                var removeExit = Run(
                    realGit,
                    new[] {
                        "-C",
                        repository,
                        "update-index",
                        "--force-remove",
                        "--",
                        relativePath
                    },
                    5000);
                var intentExit = removeExit == 0
                    ? Run(
                        realGit,
                        new[] {
                            "-C",
                            repository,
                            "add",
                            "-N",
                            "--",
                            relativePath
                        },
                        5000)
                    : removeExit;
                if (removeExit != 0 || intentExit != 0)
                {
                    return 91;
                }
                File.WriteAllText(
                    RequireControl(control, "IndexMutationSentinel"),
                    "flags-mutated",
                    new UTF8Encoding(false));
            }
            return Run(realGit, args, 20000);
        }

        if (!String.Equals(mode, "slow", StringComparison.Ordinal))
        {
            throw new InvalidDataException("Synthetic Git control mode is invalid.");
        }
        Thread.Sleep(5000);
        File.WriteAllText(
            RequireControl(control, "SlowGitSentinel"),
            "survived");
        return 0;
    }
}
'@
        $immediateSpawnerPath = Join-Path $syntheticGitDirectory 'ImmediateSpawner.exe'
        $immediateSpawnerSourcePath = Join-Path $syntheticGitDirectory 'ImmediateSpawner.cs'
        $immediateSpawnerSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;

public static class ImmediateSpawnerProgram
{
    public static int Main(string[] args)
    {
        if (args.Length == 1 &&
            String.Equals(args[0], "--child", StringComparison.Ordinal))
        {
            File.WriteAllText(
                Environment.GetEnvironmentVariable("PRIVATE_MARKER_PIPE_STARTED_SENTINEL"),
                "started",
                new UTF8Encoding(false));
            Thread.Sleep(1000);
            File.WriteAllText(
                Environment.GetEnvironmentVariable("PRIVATE_MARKER_PIPE_SURVIVED_SENTINEL"),
                "survived",
                new UTF8Encoding(false));
            return 0;
        }

        // root process は最初の処理でpipe継承childを起動する。child開始を
        // bounded sentinelで同期し、親終了時点にchildが確実に生存するfixtureにする。
        var startInfo = new ProcessStartInfo {
            FileName = Assembly.GetExecutingAssembly().Location,
            Arguments = "--child",
            UseShellExecute = false,
            CreateNoWindow = true
        };
        using (var child = Process.Start(startInfo))
        {
            if (child == null)
            {
                return 20;
            }
            var startedPath = Environment.GetEnvironmentVariable(
                "PRIVATE_MARKER_PIPE_STARTED_SENTINEL");
            var startedWait = Stopwatch.StartNew();
            while (!File.Exists(startedPath) &&
                startedWait.ElapsedMilliseconds < 500)
            {
                Thread.Sleep(5);
            }
            if (!File.Exists(startedPath))
            {
                return 21;
            }
        }
        Console.Out.WriteLine("parent-exit");
        return 0;
    }
}
'@
        $syntheticGitCompiler = @'
param(
    [string]$SourcePath,
    [string]$OutputPath
)
Add-Type `
    -Path $SourcePath `
    -OutputAssembly $OutputPath `
    -OutputType ConsoleApplication
'@
        [System.IO.File]::WriteAllText(
            $syntheticGitSourcePath,
            $syntheticGitSource,
            [System.Text.UTF8Encoding]::new($false)
        )
        [System.IO.File]::WriteAllText(
            $immediateSpawnerSourcePath,
            $immediateSpawnerSource,
            [System.Text.UTF8Encoding]::new($false)
        )
        [System.IO.File]::WriteAllText(
            $syntheticGitCompilerPath,
            $syntheticGitCompiler,
            [System.Text.UTF8Encoding]::new($true)
        )
        $windowsPowerShell = Get-Command powershell -ErrorAction Stop
        $compileResult = Invoke-PrivateMarkerProcess `
            -FileName $windowsPowerShell.Source `
            -Arguments @(
                '-NoProfile',
                '-ExecutionPolicy',
                'Bypass',
                '-File',
                $syntheticGitCompilerPath,
                '-SourcePath',
                $syntheticGitSourcePath,
                '-OutputPath',
                $syntheticGitPath
            ) `
            -WorkingDirectory $syntheticGitDirectory `
            -TimeoutMilliseconds 30000
        if ($compileResult.ExitCode -ne 0 -or
            -not $compileResult.StreamsCompleted -or
            -not $compileResult.TreeStopped -or
            -not (Test-Path -LiteralPath $syntheticGitPath -PathType Leaf)) {
            Add-Failure 'Expected bounded synthetic Git compilation to succeed.'
        }
        $spawnerCompileResult = Invoke-PrivateMarkerProcess `
            -FileName $windowsPowerShell.Source `
            -Arguments @(
                '-NoProfile',
                '-ExecutionPolicy',
                'Bypass',
                '-File',
                $syntheticGitCompilerPath,
                '-SourcePath',
                $immediateSpawnerSourcePath,
                '-OutputPath',
                $immediateSpawnerPath
            ) `
            -WorkingDirectory $syntheticGitDirectory `
            -TimeoutMilliseconds 30000
        if ($spawnerCompileResult.ExitCode -ne 0 -or
            -not $spawnerCompileResult.StreamsCompleted -or
            -not $spawnerCompileResult.TreeStopped -or
            -not (Test-Path -LiteralPath $immediateSpawnerPath -PathType Leaf)) {
            Add-Failure 'Expected bounded immediate-spawner compilation to succeed.'
        } else {
            # 目的 process が最初の処理で child を起動しても、direct target は
            # suspended 中にJob所属済みなのでkill-on-close境界から逃げられない。
            $pipeSurvivedSentinels = New-Object System.Collections.Generic.List[string]
            for ($attempt = 1; $attempt -le 10; $attempt++) {
                $pipeStartedSentinel = Join-Path `
                    $tempRoot `
                    "pipe-grandchild-started-$attempt.txt"
                $pipeSurvivedSentinel = Join-Path `
                    $tempRoot `
                    "pipe-grandchild-survived-$attempt.txt"
                $pipeSurvivedSentinels.Add($pipeSurvivedSentinel) | Out-Null
                $pipeResult = Invoke-PrivateMarkerProcess `
                    -FileName $immediateSpawnerPath `
                    -WorkingDirectory $tempRoot `
                    -EnvironmentOverrides @{
                        PRIVATE_MARKER_PIPE_STARTED_SENTINEL = $pipeStartedSentinel
                        PRIVATE_MARKER_PIPE_SURVIVED_SENTINEL = $pipeSurvivedSentinel
                    } `
                    -TimeoutMilliseconds 10000 `
                    -StreamCompletionWaitMilliseconds 500 `
                    -StreamCleanupWaitMilliseconds 1000
                if ($pipeResult.ExitCode -ne 0 -or
                    $pipeResult.TimedOut -or
                    $pipeResult.OutputLimitExceeded -or
                    $pipeResult.InputWriteFailed -or
                    $pipeResult.PipeLeakDetected -or
                    -not $pipeResult.StreamsCompleted -or
                    -not $pipeResult.TreeStopped) {
                    Add-Failure "Expected immediate-spawner attempt $attempt to close its Job before finite stream drain."
                }
                if (-not (Test-Path -LiteralPath $pipeStartedSentinel)) {
                    Add-Failure "Expected immediate-spawner attempt $attempt to prove that its child started."
                }
            }

            # 全 attempt の child が artifact を書く期限を一度だけ bounded に待つ。
            Start-Sleep -Milliseconds 1250
            foreach ($pipeSurvivedSentinel in $pipeSurvivedSentinels) {
                if (Test-Path -LiteralPath $pipeSurvivedSentinel) {
                    Add-Failure 'Expected atomic Job assignment to stop every immediate child before artifact creation.'
                    break
                }
            }
        }

        $timeoutRoot = Join-Path $tempRoot 'timeout-root'
        New-Item -ItemType Directory -Path $timeoutRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $timeoutRoot 'README.md') -Value 'synthetic clean timeout fixture' -Encoding UTF8
        Set-SyntheticGitControlFile `
            -Path $syntheticGitControlPath `
            -Values @{
                Mode = 'slow'
                SlowGitSentinel = $slowGitSentinel
            }
        $timeoutResult = Invoke-Scanner `
            -ScanPath $timeoutRoot `
            -EnvironmentOverrides @{ PATH = $syntheticGitDirectory } `
            -AdditionalArguments @('-GitCommandTimeoutMilliseconds', '750')
        if (-not (Test-FixedIntegrityFailureResult `
                -Result $timeoutResult `
                -Reason 'process-boundary' `
                -SensitiveTexts @(
                    $root,
                    $tempRoot,
                    $timeoutRoot,
                    $syntheticGitPath
                ))) {
            Add-Failure "Expected a timed-out Git probe to fail closed. Output: $($timeoutResult.Output.Trim())"
        }
        if (Test-Path -LiteralPath $slowGitSentinel) {
            Add-Failure 'Expected the timed-out synthetic Git process tree to be stopped before artifact creation.'
        }

        # Git固有timeoutよりscan-wide残時間が先に尽きた場合は、同じchild
        # timeoutでもscan-deadlineへ分類する。直前の対照ケースにより
        # production Git timeoutのprocess-boundary分類も同時に固定する。
        $scanWideGitDeadlineResult = Invoke-Scanner `
            -ScanPath $timeoutRoot `
            -EnvironmentOverrides @{ PATH = $syntheticGitDirectory } `
            -AdditionalArguments @('-ScanDeadlineMilliseconds', '250')
        if (-not (Test-FixedIntegrityFailureResult `
                -Result $scanWideGitDeadlineResult `
                -Reason 'scan-deadline' `
                -SensitiveTexts @(
                    $root,
                    $tempRoot,
                    $timeoutRoot,
                    $syntheticGitPath
                ))) {
            Add-Failure "Expected a scan-wide-bounded Git timeout to use the scan-deadline contract. Output: $($scanWideGitDeadlineResult.Output.Trim())"
        }
    }

    # success 側の規約例を 1 fixture へ集約し、各例を個別 process で再走査しない。
    $cleanRoot = Join-Path $tempRoot 'clean accepted examples'
    New-Item -ItemType Directory -Path $cleanRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $cleanRoot 'README.md') -Value @(
        '# Clean synthetic fixture'
        'A completion notice is a claim, not evidence. Verify artifacts first.'
        'Use a placeholder path such as C:\path\to\repo in examples.'
        'You can also write C:\Users\<name>\project to describe a user directory.'
        ('Own repo: ' + (('https://github' + '.com/') + 'h8nc4y/windows-github-auth-diagnosis'))
        ('Own clone URL: ' + (('https://github' + '.com/') + 'h8nc4y/windows-github-auth-diagnosis.git'))
        'The Bearer of this note is trusted.'
        'Contact: user@example.com'
        'Sender: noreply@service.example.org'
        'Trailer: octocat@users.noreply.github.com'
    ) -Encoding UTF8

    $cleanResult = Invoke-Scanner -ScanPath $cleanRoot
    if ($cleanResult.ExitCode -ne 0) {
        Add-Failure "Expected clean fixture to pass, but scanner exited $($cleanResult.ExitCode): $($cleanResult.Output.Trim())"
    }
    $noGitFallbackResult = Invoke-Scanner `
        -ScanPath $cleanRoot `
        -EnvironmentOverrides @{ PATH = $emptyCommandPath }
    if ($noGitFallbackResult.ExitCode -ne 0 -or
        $noGitFallbackResult.Output -notmatch 'working-tree') {
        Add-Failure "Expected a true non-Git directory to retain fallback when Git is unavailable. Output: $($noGitFallbackResult.Output.Trim())"
    }

    # 不正なdeadline値はparameter binder固有のraw診断へ落とさず、
    # 値や絶対pathを含まない固定1行とexit 2へ統一する。
    foreach ($invalidScanDeadline in @('0', '120001', 'not-an-integer')) {
        $invalidScanDeadlineResult = Invoke-Scanner `
            -ScanPath $cleanRoot `
            -EnvironmentOverrides @{ PATH = $emptyCommandPath } `
            -AdditionalArguments @(
                '-ScanDeadlineMilliseconds',
                $invalidScanDeadline
            )
        if (-not (Test-FixedIntegrityFailureResult `
                -Result $invalidScanDeadlineResult `
                -Reason 'scan-deadline' `
                -SensitiveTexts @(
                    $root,
                    $tempRoot,
                    $cleanRoot,
                    $invalidScanDeadline
                ))) {
            Add-Failure "Expected invalid scan deadline '$invalidScanDeadline' to use the fixed exit-2 integrity contract. Output: $($invalidScanDeadlineResult.Output.Trim())"
        }
    }

    # scan-wide 期限は実運用の120秒を延長できず、self-testだけがlower-only値で
    # runtime期限を再現する。入力不正と同じ固定1行/exit 2へ閉じ、例外の
    # source framingやローカルpathを一切出さない。
    $scanDeadlineResult = Invoke-Scanner `
        -ScanPath $cleanRoot `
        -EnvironmentOverrides @{ PATH = $emptyCommandPath } `
        -AdditionalArguments @('-ScanDeadlineMilliseconds', '1')
    if (-not (Test-FixedIntegrityFailureResult `
            -Result $scanDeadlineResult `
            -Reason 'scan-deadline' `
            -SensitiveTexts @(
                $root,
                $tempRoot,
                $cleanRoot,
                $scanner
            ))) {
        Add-Failure "Expected the elapsed scan-wide deadline to use the fixed exit-2 integrity contract. Output: $($scanDeadlineResult.Output.Trim())"
    }

    if (-not (Test-PrivateMarkerWindowsHost)) {
        # POSIX gateがscan-wide残時間でreadyになれずhelper例外になった場合も、
        # returned timeoutと同じscan-deadlineへ閉じる。fake Git targetの
        # sentinelが無いことで、期限後にreleaseされていないことも確認する。
        $gateTimeoutGitDirectory =
            Join-Path $tempRoot 'posix-gate-timeout-git'
        New-Item -ItemType Directory -Path $gateTimeoutGitDirectory |
            Out-Null
        $gateTimeoutGitPath = Join-Path $gateTimeoutGitDirectory 'git'
        $gateTimeoutGitSentinel =
            Join-Path $tempRoot 'posix-gate-timeout-git-ran.txt'
        $gateTimeoutGitScript = (
            "#!/bin/sh`n" +
            "printf '%s\n' 'ran' > '$gateTimeoutGitSentinel'`n"
        )
        [IO.File]::WriteAllText(
            $gateTimeoutGitPath,
            $gateTimeoutGitScript,
            [Text.UTF8Encoding]::new($false)
        )
        $gateTimeoutGitMode =
            [IO.UnixFileMode]::UserRead -bor
            [IO.UnixFileMode]::UserWrite -bor
            [IO.UnixFileMode]::UserExecute
        [IO.File]::SetUnixFileMode(
            $gateTimeoutGitPath,
            $gateTimeoutGitMode
        )
        $gateTimeoutExceptionResult = Invoke-Scanner `
            -ScanPath $cleanRoot `
            -EnvironmentOverrides @{ PATH = $gateTimeoutGitDirectory } `
            -AdditionalArguments @(
                '-ScanDeadlineMilliseconds',
                '100',
                '-TestGitPosixGateFailure',
                'delay'
            )
        if (-not (Test-FixedIntegrityFailureResult `
                -Result $gateTimeoutExceptionResult `
                -Reason 'scan-deadline' `
                -SensitiveTexts @(
                    $root,
                    $tempRoot,
                    $cleanRoot,
                    $gateTimeoutGitPath
                )) -or
            (Test-Path -LiteralPath $gateTimeoutGitSentinel)) {
            Add-Failure "Expected a scan-wide POSIX gate timeout exception to use scan-deadline without releasing the Git target. Output: $($gateTimeoutExceptionResult.Output.Trim())"
        }
    }

    # non-Git fallback は nested `.git` directory だけでなく leaf gitfile も読まない。
    $nestedGitLeafRoot = Join-Path $cleanRoot 'nested-git-leaf'
    New-Item -ItemType Directory -Path $nestedGitLeafRoot | Out-Null
    $nestedGitLeafPath = Join-Path $nestedGitLeafRoot '.git'
    $nestedGitLeafMarker = ('g' + 'hp_') + 'synthetic_gitfile_marker'
    Set-Content `
        -LiteralPath $nestedGitLeafPath `
        -Value $nestedGitLeafMarker `
        -Encoding UTF8
    $nestedGitDirectoryRoot = Join-Path $cleanRoot 'nested-git-directory'
    $nestedGitDirectoryPath = Join-Path $nestedGitDirectoryRoot '.git'
    New-Item -ItemType Directory -Path $nestedGitDirectoryPath -Force |
        Out-Null
    $nestedGitDirectoryMarker = ('g' + 'hp_') + 'synthetic_git_directory_marker'
    Set-Content `
        -LiteralPath (Join-Path $nestedGitDirectoryPath 'ignored.md') `
        -Value $nestedGitDirectoryMarker `
        -Encoding UTF8
    $nestedGitLeafResult = Invoke-Scanner `
        -ScanPath $cleanRoot `
        -EnvironmentOverrides @{ PATH = $emptyCommandPath }
    if ($nestedGitLeafResult.ExitCode -ne 0 -or
        $nestedGitLeafResult.Output -notmatch 'working-tree' -or
        $nestedGitLeafResult.Output.Contains($nestedGitLeafMarker) -or
        $nestedGitLeafResult.Output.Contains($nestedGitDirectoryMarker)) {
        Add-Failure "Expected nested .git leaf and directory entries to remain excluded from fallback scanning. Output: $($nestedGitLeafResult.Output.Trim())"
    }
    [System.IO.File]::Delete($nestedGitLeafPath)
    [System.IO.Directory]::Delete($nestedGitLeafRoot)
    [System.IO.Directory]::Delete($nestedGitDirectoryRoot, $true)

    if (-not (Test-PrivateMarkerWindowsHost)) {
        # POSIXでは大文字の`.GIT`をGit metadata扱いしない。case-foldの回帰で
        # 通常contentが黙って除外されないことを、実際のfindingまで固定する。
        $uppercaseGitRoot = Join-Path $cleanRoot 'uppercase-git-directory'
        $uppercaseGitDirectory = Join-Path $uppercaseGitRoot '.GIT'
        New-Item -ItemType Directory -Path $uppercaseGitDirectory -Force |
            Out-Null
        $uppercaseGitMarker =
            ('g' + 'hp_') + 'synthetic_uppercase_git_directory_marker'
        Set-Content `
            -LiteralPath (Join-Path $uppercaseGitDirectory 'visible.md') `
            -Value $uppercaseGitMarker `
            -Encoding UTF8
        $uppercaseGitResult = Invoke-Scanner `
            -ScanPath $cleanRoot `
            -EnvironmentOverrides @{ PATH = $emptyCommandPath }
        if ($uppercaseGitResult.ExitCode -ne 1 -or
            $uppercaseGitResult.Output -notmatch
                'github-classic-token-prefix' -or
            $uppercaseGitResult.Output -notmatch
                '(?i:uppercase-git-directory[\\/]\.GIT[\\/]visible\.md)') {
            Add-Failure "Expected POSIX uppercase .GIT content to remain visible to fallback scanning. Output: $($uppercaseGitResult.Output.Trim())"
        }
        [System.IO.Directory]::Delete($uppercaseGitRoot, $true)
    }

    # root/ancestor の `.git` metadata が壊れている場合は、Git/provider の
    # raw 診断を漏らさず、固定1行と exit 2 だけで fail closed にする。
    $expectedGitProbeDiagnostic =
        'Private marker scan failed closed (integrity: git-probe).'

    $metadataDirectoryRoot = Join-Path $tempRoot 'invalid git metadata directory'
    New-Item `
        -ItemType Directory `
        -Path (Join-Path $metadataDirectoryRoot '.git') `
        -Force | Out-Null
    Set-Content `
        -LiteralPath (Join-Path $metadataDirectoryRoot 'README.md') `
        -Value 'synthetic clean content' `
        -Encoding UTF8
    $metadataDirectoryResult = Invoke-Scanner -ScanPath $metadataDirectoryRoot
    if ($metadataDirectoryResult.ExitCode -ne 2 -or
        $metadataDirectoryResult.Output.Trim() -cne
            $expectedGitProbeDiagnostic) {
        Add-Failure "Expected invalid root Git directory metadata to fail closed with fixed exit 2. Output: $($metadataDirectoryResult.Output.Trim())"
    }

    $metadataFileRoot = Join-Path $tempRoot 'invalid gitfile metadata'
    New-Item -ItemType Directory -Path $metadataFileRoot | Out-Null
    Set-Content `
        -LiteralPath (Join-Path $metadataFileRoot '.git') `
        -Value 'gitdir: missing-control-directory' `
        -Encoding UTF8
    Set-Content `
        -LiteralPath (Join-Path $metadataFileRoot 'README.md') `
        -Value 'synthetic clean content' `
        -Encoding UTF8
    $metadataFileResult = Invoke-Scanner -ScanPath $metadataFileRoot
    if ($metadataFileResult.ExitCode -ne 2 -or
        $metadataFileResult.Output.Trim() -cne $expectedGitProbeDiagnostic) {
        Add-Failure "Expected invalid root Gitfile metadata to fail closed with fixed exit 2. Output: $($metadataFileResult.Output.Trim())"
    }

    $ancestorMetadataRoot = Join-Path $tempRoot 'invalid ancestor git metadata'
    $ancestorScanRoot = Join-Path $ancestorMetadataRoot 'scan-root'
    New-Item `
        -ItemType Directory `
        -Path (Join-Path $ancestorMetadataRoot '.git') `
        -Force | Out-Null
    New-Item -ItemType Directory -Path $ancestorScanRoot | Out-Null
    Set-Content `
        -LiteralPath (Join-Path $ancestorScanRoot 'README.md') `
        -Value 'synthetic clean content' `
        -Encoding UTF8
    foreach ($ancestorMetadataResult in @(
        (Invoke-Scanner -ScanPath $ancestorScanRoot),
        (Invoke-Scanner `
            -ScanPath $ancestorScanRoot `
            -EnvironmentOverrides @{ PATH = $emptyCommandPath })
    )) {
        if ($ancestorMetadataResult.ExitCode -ne 2 -or
            $ancestorMetadataResult.Output.Trim() -cne
                $expectedGitProbeDiagnostic) {
            Add-Failure "Expected invalid ancestor Git metadata to fail closed with fixed exit 2. Output: $($ancestorMetadataResult.Output.Trim())"
        }
    }

    $ancestorGitfileRoot = Join-Path $tempRoot 'invalid ancestor gitfile'
    $ancestorGitfileScanRoot = Join-Path $ancestorGitfileRoot 'scan-root'
    New-Item -ItemType Directory -Path $ancestorGitfileRoot | Out-Null
    Set-Content `
        -LiteralPath (Join-Path $ancestorGitfileRoot '.git') `
        -Value 'gitdir: missing-ancestor-control-directory' `
        -Encoding UTF8
    New-Item -ItemType Directory -Path $ancestorGitfileScanRoot | Out-Null
    Set-Content `
        -LiteralPath (Join-Path $ancestorGitfileScanRoot 'README.md') `
        -Value 'synthetic clean content' `
        -Encoding UTF8
    foreach ($ancestorGitfileResult in @(
        (Invoke-Scanner -ScanPath $ancestorGitfileScanRoot),
        (Invoke-Scanner `
            -ScanPath $ancestorGitfileScanRoot `
            -EnvironmentOverrides @{ PATH = $emptyCommandPath })
    )) {
        if ($ancestorGitfileResult.ExitCode -ne 2 -or
            $ancestorGitfileResult.Output.Trim() -cne
                $expectedGitProbeDiagnostic) {
            Add-Failure "Expected invalid ancestor Gitfile metadata to fail closed with fixed exit 2. Output: $($ancestorGitfileResult.Output.Trim())"
        }
    }

    # OS は ambient 変数ではなく runtime API で判定する。unset/empty/forgedでも挙動を固定する。
    foreach ($osCase in @(
        @{ Label = 'unset'; Value = $null },
        @{ Label = 'present-empty'; Value = '' },
        @{ Label = 'forged-posix'; Value = 'forged-posix' },
        @{ Label = 'forged-windows'; Value = 'Windows_NT' }
    )) {
        $osEnvironment = @{
            PATH = $emptyCommandPath
            OS = $osCase.Value
        }
        $osResult = Invoke-Scanner `
            -ScanPath $cleanRoot `
            -EnvironmentOverrides $osEnvironment
        if ($osResult.ExitCode -ne 0 -or
            $osResult.Output -notmatch 'working-tree') {
            Add-Failure "Expected ambient OS case '$($osCase.Label)' not to change runtime detection. Output: $($osResult.Output.Trim())"
        }
    }

    # content byte数が0でも entry数で必ず停止し、空file群を無制限に保持しない。
    $zeroByteRoot = Join-Path $tempRoot 'zero-byte-entry-limit'
    New-Item -ItemType Directory -Path $zeroByteRoot | Out-Null
    for ($zeroIndex = 0; $zeroIndex -le 10000; $zeroIndex++) {
        $zeroPath = Join-Path $zeroByteRoot (
            'zero-{0:D5}' -f $zeroIndex
        )
        $zeroStream = [System.IO.File]::Create($zeroPath)
        $zeroStream.Dispose()
    }
    $zeroByteResult = Invoke-Scanner `
        -ScanPath $zeroByteRoot `
        -EnvironmentOverrides @{ PATH = $emptyCommandPath }
    if ($zeroByteResult.ExitCode -eq 0 -or
        $zeroByteResult.Output -notmatch 'entry limit' -or
        $zeroByteResult.Output.Length -gt 16384) {
        Add-Failure "Expected zero-byte file amplification to hit the bounded entry limit. Output: $($zeroByteResult.Output.Trim())"
    }

    # Higher-recall cloud / PEM prefixes, with one redaction regression each.
    # finding 側も 1 directory へ集約するが、rule と固有 file 名を全件確認して
    # どれか 1 件だけの成功を matrix 全体の成功と誤認しない。
    $findingRoot = Join-Path $tempRoot 'combined findings'
    New-Item -ItemType Directory -Path $findingRoot | Out-Null
    $syntheticMarker = ('g' + 'hp_') + 'synthetic_placeholder_only'

    # finding件数の上限内でもserialized payloadが64KiBを超える場合、
    # partial tableを出さず固定codeだけへ縮退する。
    $findingOutputCapRoot = Join-Path $tempRoot 'finding-output-cap'
    New-Item -ItemType Directory -Path $findingOutputCapRoot | Out-Null
    for ($fileIndex = 0; $fileIndex -lt 8; $fileIndex++) {
        $longFileName = (
            'finding-output-{0}-' -f $fileIndex
        ) + ('x' * 96) + '.txt'
        Set-Content `
            -LiteralPath (Join-Path $findingOutputCapRoot $longFileName) `
            -Value @(
                for ($lineIndex = 0; $lineIndex -lt 64; $lineIndex++) {
                    $syntheticMarker
                }
            ) `
            -Encoding UTF8
    }
    $findingOutputCapResult = Invoke-Scanner `
        -ScanPath $findingOutputCapRoot `
        -EnvironmentOverrides @{ PATH = $emptyCommandPath }
    if ($findingOutputCapResult.ExitCode -eq 0 -or
        $findingOutputCapResult.Output -notmatch
            'scan-diagnostic-output-limit' -or
        $findingOutputCapResult.Output -match '<redacted>' -or
        $findingOutputCapResult.Output.Length -gt 16384) {
        Add-Failure 'Expected over-limit finding output to collapse to one bounded diagnostic without a partial table.'
    }

    $adjacentContent = 'synthetic marker after UTF-8: ' + [char]0x30C8 + $syntheticMarker
    [System.IO.File]::WriteAllText(
        (Join-Path $findingRoot 'utf8-adjacent.md'),
        $adjacentContent,
        [System.Text.UTF8Encoding]::new($false)
    )
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
        Set-Content `
            -LiteralPath (Join-Path $findingRoot ("$($case.Rule).txt")) `
            -Value "synthetic marker: $($case.Marker)" `
            -Encoding UTF8
    }

    # windows-absolute-path: private-looking paths should be findings.
    # Split the literal so this test file does not make the scanner flag itself.
    $realWinPath = 'C' + ':\Users\realperson\Secrets\config'
    Set-Content `
        -LiteralPath (Join-Path $findingRoot 'windows-path.md') `
        -Value "See $realWinPath for details." `
        -Encoding UTF8

    # non-allowlisted GitHub URL も同一 finding scan で検査する。
    # URLs are split so this test file does not make the scanner flag itself.
    $foreignUrl = ('https://github' + '.com/') + 'someone-else/private-repo'
    Set-Content `
        -LiteralPath (Join-Path $findingRoot 'github-url.md') `
        -Value "See $foreignUrl for details." `
        -Encoding UTF8

    # repo固有のfalse-positive防止契約と検出recallを同じfixtureで固定する。
    $bearerTokenMarker = ('Bear' + 'er ') + 'SyntheticHeaderValue0000'
    Set-Content `
        -LiteralPath (Join-Path $findingRoot 'bearer-header.txt') `
        -Value "synthetic marker: $bearerTokenMarker" `
        -Encoding UTF8
    $realEmail = 'someone' + '@' + 'privatecorp.co.jp'
    Set-Content `
        -LiteralPath (Join-Path $findingRoot 'real-email.txt') `
        -Value "synthetic contact: $realEmail" `
        -Encoding UTF8

    # Cf/bidi と Unicode line/paragraph separator は terminal 上で必ず escape する。
    $diagnosticControlCharacters = @(
        [char]0x202E,
        [char]0x2028,
        [char]0x2029
    )
    $diagnosticControlName =
        'diagnostic-' +
        ($diagnosticControlCharacters -join '-') +
        '-spoof.md'
    Set-Content `
        -LiteralPath (Join-Path $findingRoot $diagnosticControlName) `
        -Value "synthetic marker: $syntheticMarker" `
        -Encoding UTF8

    $findingResult = Invoke-Scanner -ScanPath $findingRoot
    if ($findingResult.ExitCode -eq 0) {
        Add-Failure 'Expected the combined synthetic finding fixture to fail.'
    }
    $expectedRules = @(
        'github-classic-token-prefix'
        $prefixCases.Rule
        'windows-absolute-path'
        'non-allowlisted-github-repo-url'
        'bearer-token-header'
        'email-address'
    )
    foreach ($rule in $expectedRules) {
        if ($findingResult.Output -notmatch [regex]::Escape($rule)) {
            Add-Failure "Expected combined finding output to name $rule. Output: $($findingResult.Output.Trim())"
        }
    }
    if ($findingResult.Output -notmatch 'utf8-adjacent\.md') {
        Add-Failure 'Expected the BOM-less UTF-8 adjacent marker file to appear in findings.'
    }
    foreach ($rawValue in @(
        $syntheticMarker
        $prefixCases.Marker
        $realWinPath
        $foreignUrl
        $bearerTokenMarker
        $realEmail
    )) {
        if ($findingResult.Output.Contains($rawValue)) {
            Add-Failure 'Expected every combined finding value to stay redacted.'
        }
    }
    if ($findingResult.Output -notmatch '<redacted>') {
        Add-Failure "Expected combined findings to report '<redacted>'. Output: $($findingResult.Output.Trim())"
    }
    foreach ($diagnosticCharacter in $diagnosticControlCharacters) {
        if ($findingResult.Output.Contains([string]$diagnosticCharacter)) {
            Add-Failure 'Expected diagnostic control characters not to appear raw in scanner output.'
        }
    }
    foreach ($escapedDiagnostic in @('\u202E', '\u2028', '\u2029')) {
        if (-not $findingResult.Output.Contains($escapedDiagnostic)) {
            Add-Failure "Expected scanner output to contain escaped diagnostic text $escapedDiagnostic."
        }
    }

    # 同一行のURL列挙は finding を1件へ畳み、出力サイズを URL 数で増幅させない。
    $urlAmplificationRoot = Join-Path $tempRoot 'url-amplification'
    New-Item -ItemType Directory -Path $urlAmplificationRoot | Out-Null
    $foreignUrls = (
        1..200 |
            ForEach-Object { "${foreignUrl}?fixture=$_" }
    ) -join ' '
    Set-Content `
        -LiteralPath (Join-Path $urlAmplificationRoot 'many-urls.md') `
        -Value $foreignUrls `
        -Encoding UTF8
    $urlAmplificationResult = Invoke-Scanner -ScanPath $urlAmplificationRoot
    $urlRuleCount = [regex]::Matches(
        $urlAmplificationResult.Output,
        'non-allowlisted-github-repo-url'
    ).Count
    if ($urlAmplificationResult.ExitCode -eq 0 -or
        $urlRuleCount -ne 1 -or
        $urlAmplificationResult.Output.Length -gt 16384) {
        Add-Failure "Expected same-line URL findings to stay deduplicated and bounded. Output length: $($urlAmplificationResult.Output.Length)"
    }

    # allowlisted URL だけでも NextMatch 回数を固定し、巨大な match 列挙を fail-closed にする。
    $allowedUrl = ('https://github' + '.com/') +
        'h8nc4y/windows-github-auth-diagnosis'
    $allowedUrlAmplificationRoot =
        Join-Path $tempRoot 'allowed-url-amplification'
    New-Item -ItemType Directory -Path $allowedUrlAmplificationRoot | Out-Null
    Set-Content `
        -LiteralPath (
            Join-Path $allowedUrlAmplificationRoot 'many-allowed-urls.md'
        ) `
        -Value ((1..300 | ForEach-Object { $allowedUrl }) -join ' ') `
        -Encoding UTF8
    $allowedUrlAmplificationResult =
        Invoke-Scanner -ScanPath $allowedUrlAmplificationRoot
    if ($allowedUrlAmplificationResult.ExitCode -eq 0 -or
        $allowedUrlAmplificationResult.Output -notmatch
            'per-line URL match limit' -or
        $allowedUrlAmplificationResult.Output.Length -gt 16384) {
        Add-Failure "Expected allowed-URL amplification to fail inside a bounded diagnostic. Output: $($allowedUrlAmplificationResult.Output.Trim())"
    }

    # 1行全体を split 配列へ複製せず、bounded substring の前に行長で拒否する。
    $overlongLineRoot = Join-Path $tempRoot 'overlong-line-limit'
    New-Item -ItemType Directory -Path $overlongLineRoot | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $overlongLineRoot 'overlong.txt'),
        [string]::new([char]'a', (1MB + 1)),
        [System.Text.UTF8Encoding]::new($false)
    )
    $overlongLineResult = Invoke-Scanner -ScanPath $overlongLineRoot
    if ($overlongLineResult.ExitCode -eq 0 -or
        $overlongLineResult.Output -notmatch 'overlong line' -or
        $overlongLineResult.Output.Length -gt 16384) {
        Add-Failure "Expected an overlong line to fail before unbounded line scanning. Output: $($overlongLineResult.Output.Trim())"
    }

    # finding は file 単位と scan 全体の双方で上限を持つ。
    $perFileFindingRoot = Join-Path $tempRoot 'per-file-finding-limit'
    New-Item -ItemType Directory -Path $perFileFindingRoot | Out-Null
    $perFileMarkerLines = (
        1..65 |
            ForEach-Object { "synthetic line $_ $syntheticMarker" }
    )
    Set-Content `
        -LiteralPath (Join-Path $perFileFindingRoot 'many-findings.md') `
        -Value $perFileMarkerLines `
        -Encoding UTF8
    $perFileFindingResult = Invoke-Scanner -ScanPath $perFileFindingRoot
    if ($perFileFindingResult.ExitCode -eq 0 -or
        $perFileFindingResult.Output -notmatch 'per-file finding limit' -or
        $perFileFindingResult.Output.Length -gt 16384 -or
        $perFileFindingResult.Output.Contains($syntheticMarker)) {
        Add-Failure "Expected per-file finding amplification to fail closed without exposing values. Output: $($perFileFindingResult.Output.Trim())"
    }

    $totalFindingRoot = Join-Path $tempRoot 'total-finding-limit'
    New-Item -ItemType Directory -Path $totalFindingRoot | Out-Null
    foreach ($fileIndex in 1..9) {
        $totalMarkerLines = (
            1..60 |
                ForEach-Object {
                    "synthetic file $fileIndex line $_ $syntheticMarker"
                }
        )
        Set-Content `
            -LiteralPath (
                Join-Path $totalFindingRoot ("findings-{0:D2}.md" -f $fileIndex)
            ) `
            -Value $totalMarkerLines `
            -Encoding UTF8
    }
    $totalFindingResult = Invoke-Scanner -ScanPath $totalFindingRoot
    if ($totalFindingResult.ExitCode -eq 0 -or
        $totalFindingResult.Output -notmatch 'total finding limit' -or
        $totalFindingResult.Output.Length -gt 16384 -or
        $totalFindingResult.Output.Contains($syntheticMarker)) {
        Add-Failure "Expected total finding amplification to fail closed without exposing values. Output: $($totalFindingResult.Output.Trim())"
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

    if (Test-PrivateMarkerWindowsHost) {
        # Explicit scan root 自体が junction の場合も、外部 target を列挙する前に拒否する。
        $rootJunctionPath = Join-Path $tempRoot 'root junction'
        $rootJunctionTarget = Join-Path $tempRoot 'root junction external target'
        New-Item -ItemType Directory -Path $rootJunctionTarget | Out-Null
        Set-Content `
            -LiteralPath (Join-Path $rootJunctionTarget 'clean.md') `
            -Value 'synthetic clean root-junction content' `
            -Encoding UTF8
        try {
            New-Item `
                -ItemType Junction `
                -Path $rootJunctionPath `
                -Target $rootJunctionTarget |
                Out-Null
            $rootJunctionResult = Invoke-Scanner -ScanPath $rootJunctionPath
            if ($rootJunctionResult.ExitCode -eq 0 -or
                $rootJunctionResult.Output -notmatch 'Explicit scan root must not be') {
                Add-Failure "Expected an explicit root junction to fail closed. Output: $($rootJunctionResult.Output.Trim())"
            }
        }
        finally {
            if (Test-Path -LiteralPath $rootJunctionPath) {
                [System.IO.Directory]::Delete($rootJunctionPath)
            }
        }

        # Dangling .git junction は target 解決で消えたように見えても Git 境界として fail-closed にする。
        $danglingGitRoot = Join-Path $tempRoot 'dangling git marker'
        $danglingGitTarget = Join-Path $tempRoot 'deleted git marker target'
        $danglingGitMarker = Join-Path $danglingGitRoot '.git'
        New-Item -ItemType Directory -Path $danglingGitRoot | Out-Null
        New-Item -ItemType Directory -Path $danglingGitTarget | Out-Null
        try {
            New-Item -ItemType Junction -Path $danglingGitMarker -Target $danglingGitTarget | Out-Null
            [System.IO.Directory]::Delete($danglingGitTarget)
            $danglingGitResult = Invoke-Scanner -ScanPath $danglingGitRoot
            if ($danglingGitResult.ExitCode -ne 2 -or
                $danglingGitResult.Output.Trim() -cne
                    $expectedGitProbeDiagnostic) {
                Add-Failure "Expected a dangling .git junction to block fallback scanning. Output: $($danglingGitResult.Output.Trim())"
            }
            $danglingNoGitResult = Invoke-Scanner `
                -ScanPath $danglingGitRoot `
                -EnvironmentOverrides @{ PATH = $emptyCommandPath }
            if ($danglingNoGitResult.ExitCode -ne 2 -or
                $danglingNoGitResult.Output.Trim() -cne
                    $expectedGitProbeDiagnostic) {
                Add-Failure "Expected a dangling .git junction to block no-Git fallback. Output: $($danglingNoGitResult.Output.Trim())"
            }
        }
        finally {
            $danglingGitEntry = Get-ChildItem `
                -LiteralPath $danglingGitRoot `
                -Force `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ceq '.git' } |
                Select-Object -First 1
            if ($null -ne $danglingGitEntry) {
                $danglingGitEntry.Delete()
            }
        }
    }

    # 敵対的な Git 環境は scanner の子だけへ渡す。親の absent / present-empty は変更しない。
    $trackedRoot = Join-Path $tempRoot 'git tracked target'
    $decoyRoot = Join-Path $tempRoot 'git decoy'
    $fixtureIsolationRoot = Join-Path $tempRoot 'fixture-git-isolation'
    $ambientRoot = Join-Path $tempRoot 'ambient-git'
    foreach ($directory in @($trackedRoot, $decoyRoot, $fixtureIsolationRoot, $ambientRoot)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }

    $targetInit = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('init', '--quiet') `
        -IsolationRoot $fixtureIsolationRoot
    if ($targetInit.ExitCode -ne 0 -or $targetInit.TimedOut -or -not $targetInit.TreeStopped) {
        Add-Failure "Expected bounded target git init to succeed. Output: $($targetInit.Output.Trim())"
    }

    if ((Test-PrivateMarkerWindowsHost) -and
        (Test-Path -LiteralPath $syntheticGitPath -PathType Leaf)) {
        # final raw stage listing の直前に、実 index へ replacement と addition を
        # 同時適用し、開始 snapshot との差分を fail-closed で検出する。
        $indexMutationRoot = Join-Path $tempRoot 'index mutation target'
        $indexMutationIsolationRoot = Join-Path `
            $tempRoot `
            'index-mutation-git-isolation'
        foreach ($directory in @(
            $indexMutationRoot,
            $indexMutationIsolationRoot
        )) {
            New-Item -ItemType Directory -Path $directory | Out-Null
        }
        $replacementRelative = 'race-replaced.env'
        $additionRelative = 'race-added.env'
        $replacementPath = Join-Path $indexMutationRoot $replacementRelative
        $additionPath = Join-Path $indexMutationRoot $additionRelative
        Set-Content `
            -LiteralPath $replacementPath `
            -Value 'synthetic baseline replacement' `
            -Encoding UTF8
        $mutationInit = Invoke-HermeticGit `
            -WorkingDirectory $indexMutationRoot `
            -Arguments @('init', '--quiet') `
            -IsolationRoot $indexMutationIsolationRoot
        $mutationBaselineAdd = Invoke-HermeticGit `
            -WorkingDirectory $indexMutationRoot `
            -Arguments @('add', '--', $replacementRelative) `
            -IsolationRoot $indexMutationIsolationRoot
        $oldReplacementOid = Invoke-HermeticGit `
            -WorkingDirectory $indexMutationRoot `
            -Arguments @('rev-parse', ":$replacementRelative") `
            -IsolationRoot $indexMutationIsolationRoot

        Set-Content `
            -LiteralPath $replacementPath `
            -Value 'synthetic changed replacement' `
            -Encoding UTF8
        Set-Content `
            -LiteralPath $additionPath `
            -Value 'synthetic added during scan' `
            -Encoding UTF8
        $expectedReplacementOid = Invoke-HermeticGit `
            -WorkingDirectory $indexMutationRoot `
            -Arguments @('hash-object', '--', $replacementRelative) `
            -IsolationRoot $indexMutationIsolationRoot

        if (@(
            $mutationInit,
            $mutationBaselineAdd,
            $oldReplacementOid,
            $expectedReplacementOid
        ) | Where-Object {
            $_.ExitCode -ne 0 -or
            -not $_.StreamsCompleted -or
            -not $_.TreeStopped
        }) {
            Add-Failure 'Expected index-mutation fixture setup to succeed.'
        } else {
            $indexMutationCounter = Join-Path $tempRoot 'index-mutation-counter.txt'
            $indexMutationSentinel = Join-Path $tempRoot 'index-mutation-complete.txt'
            $realGitPath = (Get-Command git -ErrorAction Stop).Source
            Set-SyntheticGitControlFile `
                -Path $syntheticGitControlPath `
                -Values @{
                    Mode = 'index-mutation'
                    RealGit = $realGitPath
                    IndexCounter = $indexMutationCounter
                    IndexRepository = $indexMutationRoot
                    IndexReplacement = $replacementRelative
                    IndexAddition = $additionRelative
                    IndexMutationSentinel = $indexMutationSentinel
                }
            $indexMutationResult = Invoke-Scanner `
                -ScanPath $indexMutationRoot `
                -EnvironmentOverrides @{ PATH = $syntheticGitDirectory }
            if ($indexMutationResult.ExitCode -eq 0 -or
                -not $indexMutationResult.StreamsCompleted -or
                -not $indexMutationResult.TreeStopped -or
                $indexMutationResult.TimedOut -or
                $indexMutationResult.OutputLimitExceeded -or
                $indexMutationResult.PipeLeakDetected -or
                -not $indexMutationResult.Output.Contains(
                    'Git index changed during the private marker scan.'
                )) {
                Add-Failure "Expected raw index drift to fail through a healthy boundary. Output: $($indexMutationResult.Output.Trim())"
            }
            if (-not (Test-Path -LiteralPath $indexMutationCounter) -or
                (Get-Content -LiteralPath $indexMutationCounter -Raw).Trim() -cne '2') {
                Add-Failure 'Expected exactly two raw stage listings in the index-mutation fixture.'
            }
            if (-not (Test-Path -LiteralPath $indexMutationSentinel)) {
                Add-Failure 'Expected the real staged mutation to complete before final index verification.'
            }

            $addedIndexEntry = Invoke-HermeticGit `
                -WorkingDirectory $indexMutationRoot `
                -Arguments @(
                    'ls-files',
                    '--error-unmatch',
                    '--',
                    $additionRelative
                ) `
                -IsolationRoot $indexMutationIsolationRoot
            $newReplacementOid = Invoke-HermeticGit `
                -WorkingDirectory $indexMutationRoot `
                -Arguments @('rev-parse', ":$replacementRelative") `
                -IsolationRoot $indexMutationIsolationRoot
            if ($addedIndexEntry.ExitCode -ne 0) {
                Add-Failure 'Expected the mutation proxy to add a real index entry.'
            }
            if ($newReplacementOid.ExitCode -ne 0 -or
                $newReplacementOid.Output.Trim() -ceq $oldReplacementOid.Output.Trim() -or
                $newReplacementOid.Output.Trim() -cne $expectedReplacementOid.Output.Trim()) {
                Add-Failure 'Expected the mutation proxy to replace the staged blob with the changed worktree blob.'
            }
        }

        # mode/OID/pathが同一のまま CE_INTENT_TO_ADD flagだけ変わる race も、
        # final raw debug snapshot の byte比較で検出する。
        $flagsMutationRoot = Join-Path $tempRoot 'flags mutation target'
        $flagsMutationIsolationRoot =
            Join-Path $tempRoot 'flags-mutation-git-isolation'
        New-Item -ItemType Directory -Path $flagsMutationRoot | Out-Null
        New-Item `
            -ItemType Directory `
            -Path $flagsMutationIsolationRoot |
            Out-Null
        $flagsRelative = 'flags-only-empty.md'
        $flagsPath = Join-Path $flagsMutationRoot $flagsRelative
        [System.IO.File]::WriteAllBytes($flagsPath, [byte[]]@())
        $flagsInit = Invoke-HermeticGit `
            -WorkingDirectory $flagsMutationRoot `
            -Arguments @('init', '--quiet') `
            -IsolationRoot $flagsMutationIsolationRoot
        $flagsAdd = Invoke-HermeticGit `
            -WorkingDirectory $flagsMutationRoot `
            -Arguments @('add', '--', $flagsRelative) `
            -IsolationRoot $flagsMutationIsolationRoot
        $flagsStageArguments = @(
            '-c',
            'core.quotepath=false',
            'ls-files',
            '-z',
            '--stage',
            '--',
            $flagsRelative
        )
        $flagsDebugArguments = @(
            '-c',
            'core.quotepath=false',
            'ls-files',
            '-z',
            '--stage',
            '--debug',
            '--',
            $flagsRelative
        )
        $flagsStageBefore = Invoke-HermeticGit `
            -WorkingDirectory $flagsMutationRoot `
            -Arguments $flagsStageArguments `
            -IsolationRoot $flagsMutationIsolationRoot
        $flagsDebugBefore = Invoke-HermeticGit `
            -WorkingDirectory $flagsMutationRoot `
            -Arguments $flagsDebugArguments `
            -IsolationRoot $flagsMutationIsolationRoot
        if (@(
            $flagsInit,
            $flagsAdd,
            $flagsStageBefore,
            $flagsDebugBefore
        ) | Where-Object {
            $_.ExitCode -ne 0 -or
            -not $_.StreamsCompleted -or
            -not $_.TreeStopped
        }) {
            Add-Failure 'Expected flags-only mutation fixture setup to succeed.'
        } else {
            $flagsMutationCounter =
                Join-Path $tempRoot 'flags-mutation-counter.txt'
            $flagsMutationSentinel =
                Join-Path $tempRoot 'flags-mutation-complete.txt'
            $realGitPath = (Get-Command git -ErrorAction Stop).Source
            Set-SyntheticGitControlFile `
                -Path $syntheticGitControlPath `
                -Values @{
                    Mode = 'flags-mutation'
                    RealGit = $realGitPath
                    IndexCounter = $flagsMutationCounter
                    IndexRepository = $flagsMutationRoot
                    IndexReplacement = $flagsRelative
                    IndexMutationSentinel = $flagsMutationSentinel
                }
            $flagsMutationResult = Invoke-Scanner `
                -ScanPath $flagsMutationRoot `
                -EnvironmentOverrides @{ PATH = $syntheticGitDirectory }
            if ($flagsMutationResult.ExitCode -eq 0 -or
                -not $flagsMutationResult.StreamsCompleted -or
                -not $flagsMutationResult.TreeStopped -or
                $flagsMutationResult.TimedOut -or
                $flagsMutationResult.OutputLimitExceeded -or
                $flagsMutationResult.PipeLeakDetected -or
                -not $flagsMutationResult.Output.Contains(
                    'Git index metadata changed during the private marker scan.'
                )) {
                Add-Failure "Expected flags-only index drift to fail through a healthy boundary. Output: $($flagsMutationResult.Output.Trim())"
            }
            if (-not (Test-Path -LiteralPath $flagsMutationCounter) -or
                (Get-Content -LiteralPath $flagsMutationCounter -Raw).Trim() -cne
                    '2') {
                Add-Failure 'Expected exactly two raw debug listings in the flags-only mutation fixture.'
            }
            if (-not (Test-Path -LiteralPath $flagsMutationSentinel)) {
                Add-Failure 'Expected the real flags-only mutation to complete before final metadata verification.'
            }

            $flagsStageAfter = Invoke-HermeticGit `
                -WorkingDirectory $flagsMutationRoot `
                -Arguments $flagsStageArguments `
                -IsolationRoot $flagsMutationIsolationRoot
            $flagsDebugAfter = Invoke-HermeticGit `
                -WorkingDirectory $flagsMutationRoot `
                -Arguments $flagsDebugArguments `
                -IsolationRoot $flagsMutationIsolationRoot
            if ($flagsStageAfter.ExitCode -ne 0 -or
                $flagsStageAfter.Output -cne $flagsStageBefore.Output) {
                Add-Failure 'Expected flags-only mutation to preserve exact stage listing bytes.'
            }
            if ($flagsDebugAfter.ExitCode -ne 0 -or
                $flagsDebugAfter.Output -ceq $flagsDebugBefore.Output -or
                $flagsDebugAfter.Output -notmatch 'flags: 2000[0-9a-fA-F]{4}') {
                Add-Failure 'Expected flags-only mutation to change only the raw debug metadata snapshot.'
            }
        }
    }

    $trackedMarker = ('g' + 'hp_') + 'synthetic_tracked_placeholder'
    $untrackedMarker = ('xo' + 'xb-') + 'synthetic_untracked_placeholder'
    $trackedDirectory = Join-Path $trackedRoot 'nested'
    New-Item -ItemType Directory -Path $trackedDirectory | Out-Null
    $trackedLeakPath = Join-Path $trackedDirectory 'leak.md'
    Set-Content -LiteralPath $trackedLeakPath -Value "synthetic marker: $trackedMarker" -Encoding UTF8
    $trackedMarkerBytes = [System.IO.File]::ReadAllBytes($trackedLeakPath)
    Set-Content -LiteralPath (Join-Path $trackedRoot 'untracked.md') -Value "synthetic marker: $untrackedMarker" -Encoding UTF8
    $targetAdd = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('add', 'nested/leak.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($targetAdd.ExitCode -ne 0 -or $targetAdd.TimedOut -or -not $targetAdd.TreeStopped) {
        Add-Failure "Expected bounded target git add to succeed. Output: $($targetAdd.Output.Trim())"
    }
    # index にだけ marker を残し、clean な worktree で上書きして staged blob 検査を証明する。
    Set-Content `
        -LiteralPath (Join-Path $trackedDirectory 'leak.md') `
        -Value 'synthetic clean worktree content' `
        -Encoding UTF8

    $decoyInit = Invoke-HermeticGit `
        -WorkingDirectory $decoyRoot `
        -Arguments @('init', '--quiet') `
        -IsolationRoot $fixtureIsolationRoot
    if ($decoyInit.ExitCode -ne 0 -or $decoyInit.TimedOut -or -not $decoyInit.TreeStopped) {
        Add-Failure "Expected bounded decoy git init to succeed. Output: $($decoyInit.Output.Trim())"
    }

    $ambientHooks = Join-Path $ambientRoot 'hooks'
    $ambientTemplate = Join-Path $ambientRoot 'template'
    $ambientObjects = Join-Path $decoyRoot (Join-Path '.git' 'objects')
    foreach ($directory in @($ambientHooks, $ambientTemplate)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }
    $traceSentinel = Join-Path $ambientRoot 'git-trace.log'
    $trace2Sentinel = Join-Path $ambientRoot 'git-trace2.json'
    $hookSentinel = Join-Path $ambientRoot 'hook-fired.txt'
    $filterSentinel = Join-Path $ambientRoot 'filter-fired.txt'
    $ambientAttributes = Join-Path $ambientRoot 'attributes'
    $ambientExcludes = Join-Path $ambientRoot 'excludes'
    $ambientConfig = Join-Path $ambientRoot 'hostile.gitconfig'
    [System.IO.File]::WriteAllText($ambientAttributes, "*.md filter=synthetic`n", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($ambientExcludes, "nested/leak.md`n", [System.Text.UTF8Encoding]::new($false))
    $hookScript = @"
#!/bin/sh
printf '%s\n' 'hook-fired' > '$($hookSentinel.Replace([string][char]92, '/'))'
"@
    [System.IO.File]::WriteAllText(
        (Join-Path $ambientHooks 'post-index-change'),
        $hookScript,
        [System.Text.UTF8Encoding]::new($false)
    )
    $hostileConfigContent = @"
[core]
    hooksPath = $($ambientHooks.Replace([string][char]92, '/'))
    attributesFile = $($ambientAttributes.Replace([string][char]92, '/'))
    excludesFile = $($ambientExcludes.Replace([string][char]92, '/'))
[init]
    templateDir = $($ambientTemplate.Replace([string][char]92, '/'))
[filter "synthetic"]
    clean = sh -c "printf filter-fired > '$($filterSentinel.Replace([string][char]92, '/'))'; cat"
    required = true
"@
    [System.IO.File]::WriteAllText($ambientConfig, $hostileConfigContent, [System.Text.UTF8Encoding]::new($false))

    $decoyGitDirectory = Join-Path $decoyRoot '.git'
    $decoyIndex = Join-Path $decoyGitDirectory 'index'
    $adversarialEnvironment = @{
        GIT_DIR = $decoyGitDirectory
        GIT_WORK_TREE = $decoyRoot
        GIT_INDEX_FILE = $decoyIndex
        GIT_OBJECT_DIRECTORY = $ambientObjects
        GIT_ALTERNATE_OBJECT_DIRECTORIES = $ambientObjects
        GIT_CONFIG_GLOBAL = $ambientConfig
        GIT_CONFIG_SYSTEM = $ambientConfig
        GIT_CONFIG_NOSYSTEM = '0'
        GIT_CONFIG_COUNT = '2'
        GIT_CONFIG_KEY_0 = 'core.worktree'
        GIT_CONFIG_VALUE_0 = $decoyRoot
        GIT_CONFIG_KEY_1 = 'core.hooksPath'
        GIT_CONFIG_VALUE_1 = $ambientHooks
        GIT_TRACE = $traceSentinel
        GIT_TRACE2_EVENT = $trace2Sentinel
        GIT_TERMINAL_PROMPT = '1'
        GIT_NO_LAZY_FETCH = '0'
        GIT_NO_REPLACE_OBJECTS = '0'
        GIT_HYGIENE_PRESENT_EMPTY = ''
        HOME = $ambientRoot
        USERPROFILE = $ambientRoot
        XDG_CONFIG_HOME = $ambientRoot
    }

    # exact-root判定の強化で、`.git` gitfileを使う正当なrootまで拒否しない。
    # linked worktreeとsubmoduleを実Gitで構築し、host pathの形ではなく
    # inside-work-tree=true＋empty prefixという意味境界が両方を許可することを固定する。
    $rootControlSource = Join-Path $tempRoot 'root control source'
    $linkedWorktreeRoot = Join-Path $tempRoot 'linked worktree root'
    $submoduleHostRoot = Join-Path $tempRoot 'submodule host root'
    $submoduleRelativePath = 'nested-module'
    foreach ($directory in @($rootControlSource, $submoduleHostRoot)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }
    Set-Content `
        -LiteralPath (Join-Path $rootControlSource 'clean.txt') `
        -Value 'synthetic clean root-control content' `
        -Encoding UTF8
    Set-Content `
        -LiteralPath (Join-Path $submoduleHostRoot 'clean.txt') `
        -Value 'synthetic clean submodule-host content' `
        -Encoding UTF8
    $fixtureCommitEmail = ('fixture' + '@' + 'example.invalid')
    $rootControlSetup = @(
        Invoke-HermeticGit `
            -WorkingDirectory $rootControlSource `
            -Arguments @('init', '--quiet') `
            -IsolationRoot $fixtureIsolationRoot
        Invoke-HermeticGit `
            -WorkingDirectory $rootControlSource `
            -Arguments @('add', '--', 'clean.txt') `
            -IsolationRoot $fixtureIsolationRoot
        Invoke-HermeticGit `
            -WorkingDirectory $rootControlSource `
            -Arguments @(
                '-c',
                'user.name=Synthetic Fixture',
                '-c',
                "user.email=$fixtureCommitEmail",
                'commit',
                '--quiet',
                '-m',
                'synthetic root control'
            ) `
            -IsolationRoot $fixtureIsolationRoot
        Invoke-HermeticGit `
            -WorkingDirectory $rootControlSource `
            -Arguments @(
                'worktree',
                'add',
                '--detach',
                '--quiet',
                $linkedWorktreeRoot,
                'HEAD'
            ) `
            -IsolationRoot $fixtureIsolationRoot
        Invoke-HermeticGit `
            -WorkingDirectory $submoduleHostRoot `
            -Arguments @('init', '--quiet') `
            -IsolationRoot $fixtureIsolationRoot
        Invoke-HermeticGit `
            -WorkingDirectory $submoduleHostRoot `
            -Arguments @('add', '--', 'clean.txt') `
            -IsolationRoot $fixtureIsolationRoot
        Invoke-HermeticGit `
            -WorkingDirectory $submoduleHostRoot `
            -Arguments @(
                '-c',
                'user.name=Synthetic Fixture',
                '-c',
                "user.email=$fixtureCommitEmail",
                'commit',
                '--quiet',
                '-m',
                'synthetic submodule host'
            ) `
            -IsolationRoot $fixtureIsolationRoot
        Invoke-HermeticGit `
            -WorkingDirectory $submoduleHostRoot `
            -Arguments @(
                '-c',
                'protocol.file.allow=always',
                'submodule',
                'add',
                '--quiet',
                $rootControlSource,
                $submoduleRelativePath
            ) `
            -IsolationRoot $fixtureIsolationRoot
    )
    if ($rootControlSetup | Where-Object {
        $_.ExitCode -ne 0 -or $_.TimedOut -or -not $_.TreeStopped
    }) {
        Add-Failure 'Expected linked-worktree/submodule root control setup to succeed.'
    } else {
        $linkedWorktreeResult = Invoke-Scanner `
            -ScanPath $linkedWorktreeRoot `
            -EnvironmentOverrides $adversarialEnvironment
        if ($linkedWorktreeResult.ExitCode -ne 0 -or
            $linkedWorktreeResult.Output -notmatch 'git-tracked') {
            Add-Failure "Expected a linked worktree exact root to remain accepted. Output: $($linkedWorktreeResult.Output.Trim())"
        }

        $submoduleRoot = Join-Path $submoduleHostRoot $submoduleRelativePath
        $submoduleRootResult = Invoke-Scanner `
            -ScanPath $submoduleRoot `
            -EnvironmentOverrides $adversarialEnvironment
        if ($submoduleRootResult.ExitCode -ne 0 -or
            $submoduleRootResult.Output -notmatch 'git-tracked') {
            Add-Failure "Expected a submodule exact root to remain accepted. Output: $($submoduleRootResult.Output.Trim())"
        }
    }

    # `--show-prefix` の空recordだけではGit metadata rootも一致してしまう。
    # repo-local core.worktreeはambient GIT_* sanitize後も有効なため、別worktreeを
    # 設定したmetadata directoryをfalse-cleanとして誤受理しない契約を固定する。
    $bareRoot = Join-Path $tempRoot 'bare repository root'
    $bareWorktreeRoot = Join-Path $tempRoot 'bare repository external worktree'
    foreach ($directory in @($bareRoot, $bareWorktreeRoot)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }
    $bareInit = Invoke-HermeticGit `
        -WorkingDirectory $bareRoot `
        -Arguments @('init', '--bare', '--quiet') `
        -IsolationRoot $fixtureIsolationRoot
    $bareAsWorktreeConfig = Invoke-HermeticGit `
        -WorkingDirectory $tempRoot `
        -Arguments @('--git-dir', $bareRoot, 'config', 'core.bare', 'false') `
        -IsolationRoot $fixtureIsolationRoot
    $bareExternalWorktreeConfig = Invoke-HermeticGit `
        -WorkingDirectory $tempRoot `
        -Arguments @(
            '--git-dir',
            $bareRoot,
            'config',
            'core.worktree',
            $bareWorktreeRoot
        ) `
        -IsolationRoot $fixtureIsolationRoot
    if (@(
        $bareInit,
        $bareAsWorktreeConfig,
        $bareExternalWorktreeConfig
    ) | Where-Object {
        $_.ExitCode -ne 0 -or $_.TimedOut -or -not $_.TreeStopped
    }) {
        Add-Failure 'Expected bounded bare/core.worktree fixture setup to succeed.'
    } else {
        $bareRootResult = Invoke-Scanner `
            -ScanPath $bareRoot `
            -EnvironmentOverrides $adversarialEnvironment
        if ($bareRootResult.ExitCode -eq 0 -or
            $bareRootResult.Output -notmatch 'exact Git worktree root') {
            Add-Failure "Expected a Git metadata root with an external worktree to fail closed. Output: $($bareRootResult.Output.Trim())"
        }
    }

    $repositoryWithoutGitResult = Invoke-Scanner `
        -ScanPath $trackedRoot `
        -EnvironmentOverrides @{ PATH = $emptyCommandPath }
    if ($repositoryWithoutGitResult.ExitCode -ne 2 -or
        $repositoryWithoutGitResult.Output.Trim() -cne
            $expectedGitProbeDiagnostic) {
        Add-Failure "Expected a real .git marker to block no-Git fallback. Output: $($repositoryWithoutGitResult.Output.Trim())"
    }

    $beforeAdversarialScan = Get-ProcessEnvironmentSnapshot
    $adversarialFailure = Invoke-Scanner `
        -ScanPath $trackedRoot `
        -EnvironmentOverrides $adversarialEnvironment
    Assert-ProcessEnvironmentUnchanged `
        -Expected $beforeAdversarialScan `
        -Context 'Adversarial failing scanner child'
    if (-not $adversarialEnvironment.ContainsKey('GIT_HYGIENE_PRESENT_EMPTY') -or
        $adversarialEnvironment['GIT_HYGIENE_PRESENT_EMPTY'] -cne '') {
        Add-Failure 'Expected the controlled present-empty Git variable to remain present-empty.'
    }
    if ($adversarialFailure.TimedOut -or -not $adversarialFailure.TreeStopped) {
        Add-Failure "Expected adversarial failing scanner child to finish within bounds. Output: $($adversarialFailure.Output.Trim())"
    }
    if ($adversarialFailure.ExitCode -eq 0) {
        Add-Failure 'Expected hostile Git variables not to empty or redirect the tracked-file scan.'
    }
    if ($adversarialFailure.Output -notmatch 'git-tracked') {
        Add-Failure "Expected adversarial fixture to retain git-tracked mode. Output: $($adversarialFailure.Output.Trim())"
    }
    if ($adversarialFailure.Output -notmatch 'nested/leak\.md') {
        Add-Failure "Expected adversarial fixture to report the target repository marker. Output: $($adversarialFailure.Output.Trim())"
    }
    if ($adversarialFailure.Output -notmatch '\bindex\b') {
        Add-Failure "Expected staged-only marker output to identify the index source. Output: $($adversarialFailure.Output.Trim())"
    }
    if ($adversarialFailure.Output -match 'untracked\.md') {
        Add-Failure 'Expected git-tracked mode not to scan an untracked marker.'
    }
    if ($adversarialFailure.Output.Contains($trackedMarker) -or
        $adversarialFailure.Output.Contains($untrackedMarker)) {
        Add-Failure 'Expected adversarial findings to stay redacted.'
    }

    # refs/replace が staged blob を clean blob へ差し替えても、index の実体を検査する。
    $markerOidResult = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('rev-parse', ':nested/leak.md') `
        -IsolationRoot $fixtureIsolationRoot
    $cleanOidResult = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('hash-object', '-w', '--', 'nested/leak.md') `
        -IsolationRoot $fixtureIsolationRoot
    $markerOid = $markerOidResult.Output.Trim()
    $cleanOid = $cleanOidResult.Output.Trim()
    if ($markerOidResult.ExitCode -ne 0 -or
        $cleanOidResult.ExitCode -ne 0 -or
        $markerOid -notmatch '^[0-9a-f]{40,64}$' -or
        $cleanOid -notmatch '^[0-9a-f]{40,64}$') {
        Add-Failure 'Expected replace-ref fixture object setup to succeed.'
    } else {
        $replaceAdd = Invoke-HermeticGit `
            -WorkingDirectory $trackedRoot `
            -Arguments @('replace', $markerOid, $cleanOid) `
            -IsolationRoot $fixtureIsolationRoot
        if ($replaceAdd.ExitCode -ne 0) {
            Add-Failure "Expected replace-ref fixture setup to succeed. Output: $($replaceAdd.Output.Trim())"
        } else {
            $replaceResult = Invoke-Scanner `
                -ScanPath $trackedRoot `
                -EnvironmentOverrides $adversarialEnvironment
            if ($replaceResult.ExitCode -eq 0 -or
                $replaceResult.Output -notmatch 'nested/leak\.md' -or
                $replaceResult.Output -notmatch '\bindex\b') {
                Add-Failure "Expected replace refs not to hide the staged marker. Output: $($replaceResult.Output.Trim())"
            }
            if ($replaceResult.Output.Contains($trackedMarker)) {
                Add-Failure 'Expected replace-ref finding to keep the staged marker redacted.'
            }
            $replaceDelete = Invoke-HermeticGit `
                -WorkingDirectory $trackedRoot `
                -Arguments @('replace', '-d', $markerOid) `
                -IsolationRoot $fixtureIsolationRoot
            if ($replaceDelete.ExitCode -ne 0) {
                Add-Failure "Expected replace-ref fixture cleanup to succeed. Output: $($replaceDelete.Output.Trim())"
            }
        }
    }

    # Partial clone の不足 blob は remote から補完せず、local-only 境界で即座に拒否する。
    if ($markerOid -match '^[0-9a-f]{40,64}$') {
        $promisorRemoteRoot = Join-Path $tempRoot 'promisor remote'
        $promisorRemoteDirectory = Join-Path $promisorRemoteRoot 'nested'
        New-Item -ItemType Directory -Path $promisorRemoteDirectory | Out-Null
        $promisorInit = Invoke-HermeticGit `
            -WorkingDirectory $promisorRemoteRoot `
            -Arguments @('init', '--quiet') `
            -IsolationRoot $fixtureIsolationRoot
        [System.IO.File]::WriteAllBytes(
            (Join-Path $promisorRemoteDirectory 'leak.md'),
            $trackedMarkerBytes
        )
        $promisorAdd = Invoke-HermeticGit `
            -WorkingDirectory $promisorRemoteRoot `
            -Arguments @('add', '--', 'nested/leak.md') `
            -IsolationRoot $fixtureIsolationRoot
        $fixtureEmail = 'synthetic' + '@example.invalid'
        $promisorCommit = Invoke-HermeticGit `
            -WorkingDirectory $promisorRemoteRoot `
            -Arguments @(
                '-c',
                'user.name=Synthetic Fixture',
                '-c',
                "user.email=$fixtureEmail",
                '-c',
                'commit.gpgSign=false',
                'commit',
                '--quiet',
                '-m',
                'synthetic promisor source'
            ) `
            -IsolationRoot $fixtureIsolationRoot
        $promisorOidResult = Invoke-HermeticGit `
            -WorkingDirectory $promisorRemoteRoot `
            -Arguments @('rev-parse', ':nested/leak.md') `
            -IsolationRoot $fixtureIsolationRoot
        if ($promisorInit.ExitCode -ne 0 -or
            $promisorAdd.ExitCode -ne 0 -or
            $promisorCommit.ExitCode -ne 0 -or
            $promisorOidResult.Output.Trim() -cne $markerOid) {
            Add-Failure 'Expected synthetic promisor remote setup to preserve the staged blob OID.'
        } else {
            $partialCloneConfigResults = @(
                Invoke-HermeticGit `
                    -WorkingDirectory $trackedRoot `
                    -Arguments @('config', 'extensions.partialClone', 'origin') `
                    -IsolationRoot $fixtureIsolationRoot
                Invoke-HermeticGit `
                    -WorkingDirectory $trackedRoot `
                    -Arguments @('config', 'remote.origin.promisor', 'true') `
                    -IsolationRoot $fixtureIsolationRoot
                Invoke-HermeticGit `
                    -WorkingDirectory $trackedRoot `
                    -Arguments @('config', 'remote.origin.partialclonefilter', 'blob:none') `
                    -IsolationRoot $fixtureIsolationRoot
                Invoke-HermeticGit `
                    -WorkingDirectory $trackedRoot `
                    -Arguments @('config', 'remote.origin.url', $promisorRemoteRoot) `
                    -IsolationRoot $fixtureIsolationRoot
            )
            if ($partialCloneConfigResults | Where-Object { $_.ExitCode -ne 0 }) {
                Add-Failure 'Expected synthetic partial-clone configuration to succeed.'
            } else {
                $objectRelativePath = Join-Path `
                    $markerOid.Substring(0, 2) `
                    $markerOid.Substring(2)
                $localMarkerObject = Join-Path `
                    (Join-Path (Join-Path $trackedRoot '.git') 'objects') `
                    $objectRelativePath
                if (-not [System.IO.File]::Exists($localMarkerObject)) {
                    Add-Failure 'Expected the staged marker fixture to use a removable loose object.'
                } else {
                    $localMarkerObjectBytes = [System.IO.File]::ReadAllBytes($localMarkerObject)
                    try {
                        # Git for Windows は loose object を read-only にする場合があるため、
                        # synthetic fixture の退避前だけ通常属性へ戻す。
                        [System.IO.File]::SetAttributes(
                            $localMarkerObject,
                            [System.IO.FileAttributes]::Normal
                        )
                        [System.IO.File]::Delete($localMarkerObject)
                        $partialCloneResult = Invoke-Scanner `
                            -ScanPath $trackedRoot `
                            -EnvironmentOverrides $adversarialEnvironment
                        if ($partialCloneResult.ExitCode -eq 0) {
                            Add-Failure 'Expected a missing promisor blob to fail closed without lazy fetch.'
                        }
                        if ($partialCloneResult.Output.Contains($trackedMarker)) {
                            Add-Failure 'Expected missing-promisor diagnostics not to expose marker content.'
                        }
                        $postScanMissingCheck = Invoke-HermeticGit `
                            -WorkingDirectory $trackedRoot `
                            -Arguments @('cat-file', '-e', "$markerOid`^{blob}") `
                            -IsolationRoot $fixtureIsolationRoot
                        if ($postScanMissingCheck.ExitCode -eq 0) {
                            Add-Failure 'Expected the scanner not to fetch the missing promisor blob.'
                        }
                    }
                    finally {
                        # 回帰で同一 OID が再取得済みなら上書きせず、未取得時だけ退避 bytes を戻す。
                        if (-not [System.IO.File]::Exists($localMarkerObject)) {
                            [System.IO.File]::WriteAllBytes(
                                $localMarkerObject,
                                $localMarkerObjectBytes
                            )
                        }
                    }
                }
            }
            foreach ($configKey in @(
                'extensions.partialClone',
                'remote.origin.promisor',
                'remote.origin.partialclonefilter',
                'remote.origin.url'
            )) {
                $configCleanup = Invoke-HermeticGit `
                    -WorkingDirectory $trackedRoot `
                    -Arguments @('config', '--unset-all', $configKey) `
                    -IsolationRoot $fixtureIsolationRoot
                if ($configCleanup.ExitCode -ne 0) {
                    Add-Failure "Expected partial-clone fixture cleanup to remove $configKey."
                }
            }
        }
    }

    # 同じ敵対環境で成功経路も通し、失敗時だけの cleanup 漏れを見逃さない。
    Set-Content -LiteralPath (Join-Path $trackedDirectory 'leak.md') -Value 'synthetic clean tracked content' -Encoding UTF8
    $targetRestage = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('add', 'nested/leak.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($targetRestage.ExitCode -ne 0 -or $targetRestage.TimedOut -or -not $targetRestage.TreeStopped) {
        Add-Failure "Expected bounded target git restage to succeed. Output: $($targetRestage.Output.Trim())"
    }

    $beforeAdversarialSuccess = Get-ProcessEnvironmentSnapshot
    $adversarialSuccess = Invoke-Scanner `
        -ScanPath $trackedRoot `
        -EnvironmentOverrides $adversarialEnvironment
    Assert-ProcessEnvironmentUnchanged `
        -Expected $beforeAdversarialSuccess `
        -Context 'Adversarial successful scanner child'
    if ($adversarialSuccess.ExitCode -ne 0 -or
        $adversarialSuccess.TimedOut -or
        -not $adversarialSuccess.TreeStopped -or
        $adversarialSuccess.Output -notmatch 'git-tracked') {
        Add-Failure "Expected hostile Git variables not to break a clean tracked scan. Output: $($adversarialSuccess.Output.Trim())"
    }

    # Secretを含みやすい名前と拡張子を、index-only / worktree-only の
    # 両方向でまとめて固定する。各path/sourceを確認してmatrixの取りこぼしを防ぐ。
    $textCandidateCases = @(
        @{ Path = '.env';            Marker = ('g' + 'hp_') + 'synthetic_env_root' }
        @{ Path = '.env.local';      Marker = ('g' + 'hp_') + 'synthetic_env_variant' }
        @{ Path = 'production.env';  Marker = ('g' + 'hp_') + 'synthetic_env_suffix' }
        @{ Path = 'certificate.pem'; Marker = ('g' + 'hp_') + 'synthetic_pem' }
        @{ Path = 'private.key';     Marker = ('g' + 'hp_') + 'synthetic_key' }
        @{ Path = 'LICENSE';         Marker = ('g' + 'hp_') + 'synthetic_extensionless' }
        @{ Path = '.npmrc';          Marker = ('g' + 'hp_') + 'synthetic_dotfile' }
    )
    foreach ($case in $textCandidateCases) {
        Set-Content `
            -LiteralPath (Join-Path $trackedRoot $case.Path) `
            -Value "synthetic marker: $($case.Marker)" `
            -Encoding UTF8
    }
    $candidatePaths = @($textCandidateCases.Path)
    $candidateIndexAdd = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments (@('add', '--') + $candidatePaths) `
        -IsolationRoot $fixtureIsolationRoot
    if ($candidateIndexAdd.ExitCode -ne 0) {
        Add-Failure "Expected text-candidate index fixture setup to succeed. Output: $($candidateIndexAdd.Output.Trim())"
    }
    foreach ($case in $textCandidateCases) {
        Set-Content `
            -LiteralPath (Join-Path $trackedRoot $case.Path) `
            -Value "synthetic clean worktree content: $($case.Path)" `
            -Encoding UTF8
    }
    $candidateIndexResult = Invoke-Scanner `
        -ScanPath $trackedRoot `
        -EnvironmentOverrides $adversarialEnvironment
    if ($candidateIndexResult.ExitCode -eq 0) {
        Add-Failure 'Expected index-only text-candidate markers to fail the scan.'
    }
    foreach ($case in $textCandidateCases) {
        $escapedPath = [regex]::Escape($case.Path)
        if ($candidateIndexResult.Output -notmatch "(?m)^\s*$escapedPath\s+index\s+") {
            Add-Failure "Expected index-only text candidate $($case.Path) to be reported from index. Output: $($candidateIndexResult.Output.Trim())"
        }
        if ($candidateIndexResult.Output.Contains($case.Marker)) {
            Add-Failure "Expected index-only text candidate $($case.Path) to stay redacted."
        }
    }

    $candidateCleanAdd = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments (@('add', '--') + $candidatePaths) `
        -IsolationRoot $fixtureIsolationRoot
    if ($candidateCleanAdd.ExitCode -ne 0) {
        Add-Failure "Expected clean text-candidate baseline to be staged. Output: $($candidateCleanAdd.Output.Trim())"
    }
    foreach ($case in $textCandidateCases) {
        Set-Content `
            -LiteralPath (Join-Path $trackedRoot $case.Path) `
            -Value "synthetic marker: $($case.Marker)" `
            -Encoding UTF8
    }
    $candidateWorktreeResult = Invoke-Scanner `
        -ScanPath $trackedRoot `
        -EnvironmentOverrides $adversarialEnvironment
    if ($candidateWorktreeResult.ExitCode -eq 0) {
        Add-Failure 'Expected worktree-only text-candidate markers to fail the scan.'
    }
    foreach ($case in $textCandidateCases) {
        $escapedPath = [regex]::Escape($case.Path)
        if ($candidateWorktreeResult.Output -notmatch "(?m)^\s*$escapedPath\s+working-tree\s+") {
            Add-Failure "Expected worktree-only text candidate $($case.Path) to be reported from working-tree. Output: $($candidateWorktreeResult.Output.Trim())"
        }
        if ($candidateWorktreeResult.Output.Contains($case.Marker)) {
            Add-Failure "Expected worktree-only text candidate $($case.Path) to stay redacted."
        }
        Set-Content `
            -LiteralPath (Join-Path $trackedRoot $case.Path) `
            -Value "synthetic clean worktree content: $($case.Path)" `
            -Encoding UTF8
    }
    $candidateCleanup = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments (@('add', '--') + $candidatePaths) `
        -IsolationRoot $fixtureIsolationRoot
    if ($candidateCleanup.ExitCode -ne 0) {
        Add-Failure "Expected text-candidate fixture cleanup to succeed. Output: $($candidateCleanup.Output.Trim())"
    }

    $worktreeOnlyMarker = ('xo' + 'xb-') + 'synthetic_worktree_only'
    Set-Content `
        -LiteralPath (Join-Path $trackedDirectory 'leak.md') `
        -Value "synthetic marker: $worktreeOnlyMarker" `
        -Encoding UTF8
    $worktreeOnlyResult = Invoke-Scanner `
        -ScanPath $trackedRoot `
        -EnvironmentOverrides $adversarialEnvironment
    if ($worktreeOnlyResult.ExitCode -eq 0 -or
        $worktreeOnlyResult.Output -notmatch '\bworking-tree\b' -or
        $worktreeOnlyResult.Output -notmatch 'nested/leak\.md') {
        Add-Failure "Expected worktree-only marker to be scanned beside the clean index blob. Output: $($worktreeOnlyResult.Output.Trim())"
    }
    if ($worktreeOnlyResult.Output.Contains($worktreeOnlyMarker)) {
        Add-Failure 'Expected the worktree-only marker to stay redacted.'
    }
    Set-Content `
        -LiteralPath (Join-Path $trackedDirectory 'leak.md') `
        -Value 'synthetic clean tracked content' `
        -Encoding UTF8

    $subdirectoryResult = Invoke-Scanner `
        -ScanPath $trackedDirectory `
        -EnvironmentOverrides $adversarialEnvironment
    if ($subdirectoryResult.ExitCode -eq 0 -or
        $subdirectoryResult.Output -notmatch 'exact Git worktree root') {
        Add-Failure "Expected a Git subdirectory scan to fail closed instead of falling back. Output: $($subdirectoryResult.Output.Trim())"
    }

    # worktree から消えた tracked file も index blob から検査し、silent skip を防ぐ。
    $missingMarker = ('g' + 'hp_') + 'synthetic_missing_worktree'
    $missingPath = Join-Path $trackedRoot 'missing.md'
    Set-Content -LiteralPath $missingPath -Value "synthetic marker: $missingMarker" -Encoding UTF8
    $missingAdd = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('add', '--', 'missing.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($missingAdd.ExitCode -ne 0) {
        Add-Failure "Expected missing-worktree fixture add to succeed. Output: $($missingAdd.Output.Trim())"
    }
    [System.IO.File]::Delete($missingPath)
    $missingResult = Invoke-Scanner `
        -ScanPath $trackedRoot `
        -EnvironmentOverrides $adversarialEnvironment
    if ($missingResult.ExitCode -eq 0 -or
        $missingResult.Output -notmatch 'missing\.md' -or
        $missingResult.Output -notmatch '\bindex\b') {
        Add-Failure "Expected an index-only missing-worktree marker to fail the scan. Output: $($missingResult.Output.Trim())"
    }
    if ($missingResult.Output.Contains($missingMarker)) {
        Add-Failure 'Expected the missing-worktree index marker to stay redacted.'
    }
    $missingRemove = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('update-index', '--force-remove', '--', 'missing.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($missingRemove.ExitCode -ne 0) {
        Add-Failure "Expected missing-worktree fixture cleanup to succeed. Output: $($missingRemove.Output.Trim())"
    }

    # local marker file は untracked 専用であり、index に現れた時点で内容を公開対象にしない。
    $trackedLocalMarkerPath = Join-Path $trackedRoot '.private-markers.local'
    $trackedLocalMarker = 'synthetic-tracked-local-marker'
    Set-Content `
        -LiteralPath $trackedLocalMarkerPath `
        -Value $trackedLocalMarker `
        -Encoding UTF8
    $trackedLocalAdd = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('add', '-f', '--', '.private-markers.local') `
        -IsolationRoot $fixtureIsolationRoot
    if ($trackedLocalAdd.ExitCode -ne 0) {
        Add-Failure "Expected tracked local-marker fixture setup to succeed. Output: $($trackedLocalAdd.Output.Trim())"
    } else {
        $trackedLocalResult = Invoke-Scanner `
            -ScanPath $trackedRoot `
            -EnvironmentOverrides $adversarialEnvironment
        if ($trackedLocalResult.ExitCode -eq 0 -or
            $trackedLocalResult.Output -notmatch 'must remain untracked') {
            Add-Failure "Expected a tracked .private-markers.local file to fail closed. Output: $($trackedLocalResult.Output.Trim())"
        }
        if ($trackedLocalResult.Output.Contains($trackedLocalMarker)) {
            Add-Failure 'Expected tracked local-marker diagnostics not to expose marker content.'
        }
    }
    $trackedLocalRemove = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('update-index', '--force-remove', '--', '.private-markers.local') `
        -IsolationRoot $fixtureIsolationRoot
    if ($trackedLocalRemove.ExitCode -ne 0) {
        Add-Failure "Expected tracked local-marker fixture cleanup to succeed. Output: $($trackedLocalRemove.Output.Trim())"
    }
    [System.IO.File]::Delete($trackedLocalMarkerPath)

    # `ls-files --stage` では normal empty blob と同じOIDに見えるため、
    # CE_INTENT_TO_ADD flagを直接検査して present/missing worktree の双方を拒否する。
    $intentPath = Join-Path $trackedRoot 'intent.md'
    Set-Content -LiteralPath $intentPath -Value 'synthetic intent-to-add content' -Encoding UTF8
    $intentAdd = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('add', '-N', '--', 'intent.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($intentAdd.ExitCode -ne 0) {
        Add-Failure "Expected intent-to-add fixture setup to succeed. Output: $($intentAdd.Output.Trim())"
    }
    $intentResult = Invoke-Scanner `
        -ScanPath $trackedRoot `
        -EnvironmentOverrides $adversarialEnvironment
    if ($intentResult.ExitCode -eq 0 -or
        $intentResult.Output -notmatch 'intent-to-add') {
        Add-Failure "Expected present-worktree intent-to-add state to fail closed. Output: $($intentResult.Output.Trim())"
    }
    [System.IO.File]::Delete($intentPath)
    $missingIntentResult = Invoke-Scanner `
        -ScanPath $trackedRoot `
        -EnvironmentOverrides $adversarialEnvironment
    if ($missingIntentResult.ExitCode -eq 0 -or
        $missingIntentResult.Output -notmatch 'intent-to-add') {
        Add-Failure "Expected missing-worktree intent-to-add state to fail closed. Output: $($missingIntentResult.Output.Trim())"
    }
    $intentRemove = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('update-index', '--force-remove', '--', 'intent.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($intentRemove.ExitCode -ne 0) {
        Add-Failure "Expected intent-to-add fixture cleanup to succeed. Output: $($intentRemove.Output.Trim())"
    }

    # CE_INTENT_TO_ADDを持たない通常の staged empty blob は正当なtextとして通す。
    $ordinaryEmptyRoot = Join-Path $tempRoot 'ordinary-empty-target'
    $ordinaryEmptyIsolationRoot =
        Join-Path $tempRoot 'ordinary-empty-git-isolation'
    New-Item -ItemType Directory -Path $ordinaryEmptyRoot | Out-Null
    New-Item -ItemType Directory -Path $ordinaryEmptyIsolationRoot | Out-Null
    $ordinaryEmptyRelative = 'ordinary-empty.md'
    $ordinaryEmptyPath = Join-Path $ordinaryEmptyRoot $ordinaryEmptyRelative
    [System.IO.File]::WriteAllBytes($ordinaryEmptyPath, [byte[]]@())
    $ordinaryEmptyInit = Invoke-HermeticGit `
        -WorkingDirectory $ordinaryEmptyRoot `
        -Arguments @('init', '--quiet') `
        -IsolationRoot $ordinaryEmptyIsolationRoot
    $ordinaryEmptyAdd = Invoke-HermeticGit `
        -WorkingDirectory $ordinaryEmptyRoot `
        -Arguments @('add', '--', $ordinaryEmptyRelative) `
        -IsolationRoot $ordinaryEmptyIsolationRoot
    if ($ordinaryEmptyInit.ExitCode -ne 0 -or
        $ordinaryEmptyAdd.ExitCode -ne 0) {
        Add-Failure "Expected ordinary empty-file fixture setup to succeed. Output: $($ordinaryEmptyAdd.Output.Trim())"
    } else {
        $ordinaryEmptyResult = Invoke-Scanner `
            -ScanPath $ordinaryEmptyRoot `
            -EnvironmentOverrides $adversarialEnvironment
        if ($ordinaryEmptyResult.ExitCode -ne 0 -or
            $ordinaryEmptyResult.Output -match 'intent-to-add') {
            Add-Failure "Expected an ordinary staged empty blob to pass without intent-to-add classification. Output: $($ordinaryEmptyResult.Output.Trim())"
        }
    }

    # Index mode 120000 / 160000 は外部参照や別 repository へ進まず拒否する。
    $hashResult = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('hash-object', '-w', '--', 'nested/leak.md') `
        -IsolationRoot $fixtureIsolationRoot
    $fixtureOid = $hashResult.Output.Trim()
    if ($hashResult.ExitCode -ne 0 -or $fixtureOid -notmatch '^[0-9a-f]{40,64}$') {
        Add-Failure "Expected fixture blob hashing to succeed. Output: $($hashResult.Output.Trim())"
    } else {
        foreach ($modeCase in @(
            @{ Mode = '120000'; Path = 'synthetic-link.md'; Label = 'symlink' },
            @{ Mode = '160000'; Path = 'synthetic-gitlink'; Label = 'gitlink' }
        )) {
            $modeAdd = Invoke-HermeticGit `
                -WorkingDirectory $trackedRoot `
                -Arguments @(
                    'update-index',
                    '--add',
                    '--cacheinfo',
                    "$($modeCase.Mode),$fixtureOid,$($modeCase.Path)"
                ) `
                -IsolationRoot $fixtureIsolationRoot
            if ($modeAdd.ExitCode -ne 0) {
                Add-Failure "Expected $($modeCase.Label) index fixture setup to succeed. Output: $($modeAdd.Output.Trim())"
                continue
            }
            $modeResult = Invoke-Scanner `
                -ScanPath $trackedRoot `
                -EnvironmentOverrides $adversarialEnvironment
            if ($modeResult.ExitCode -eq 0 -or
                $modeResult.Output -notmatch 'unsupported mode') {
                Add-Failure "Expected $($modeCase.Label) index mode to fail closed. Output: $($modeResult.Output.Trim())"
            }
            $modeRemove = Invoke-HermeticGit `
                -WorkingDirectory $trackedRoot `
                -Arguments @('update-index', '--force-remove', '--', $modeCase.Path) `
                -IsolationRoot $fixtureIsolationRoot
            if ($modeRemove.ExitCode -ne 0) {
                Add-Failure "Expected $($modeCase.Label) fixture cleanup to succeed. Output: $($modeRemove.Output.Trim())"
            }
        }
    }

    # Regular index entryをplatform linkへ差し替え、外部targetをfollowしないことを確認する。
    $directoryLinkItemType = if (Test-PrivateMarkerWindowsHost) {
        'Junction'
    } else {
        'SymbolicLink'
    }
    $reparsePath = Join-Path $trackedRoot 'reparse.md'
    $reparseTarget = Join-Path $tempRoot 'reparse-external-target'
    New-Item -ItemType Directory -Path $reparseTarget | Out-Null
    Set-Content -LiteralPath (Join-Path $reparseTarget 'outside.md') -Value "synthetic marker: $trackedMarker" -Encoding UTF8
    Set-Content -LiteralPath $reparsePath -Value 'synthetic regular index content' -Encoding UTF8
    $reparseAdd = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('add', '--', 'reparse.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($reparseAdd.ExitCode -ne 0) {
        Add-Failure "Expected reparse fixture add to succeed. Output: $($reparseAdd.Output.Trim())"
    }
    [System.IO.File]::Delete($reparsePath)
    try {
        New-Item `
            -ItemType $directoryLinkItemType `
            -Path $reparsePath `
            -Target $reparseTarget |
            Out-Null
        $reparseResult = Invoke-Scanner `
            -ScanPath $trackedRoot `
            -EnvironmentOverrides $adversarialEnvironment
        if ($reparseResult.ExitCode -eq 0 -or
            $reparseResult.Output -notmatch 'not a regular local file') {
            Add-Failure "Expected a tracked reparse path to fail closed without following it. Output: $($reparseResult.Output.Trim())"
        }
    }
    finally {
        if (Test-Path -LiteralPath $reparsePath) {
            (Get-Item -LiteralPath $reparsePath -Force).Delete()
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $reparseTarget 'outside.md'))) {
        Add-Failure 'Expected reparse cleanup not to alter the external synthetic target.'
    }
    $reparseRemove = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('update-index', '--force-remove', '--', 'reparse.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($reparseRemove.ExitCode -ne 0) {
        Add-Failure "Expected reparse fixture cleanup to succeed. Output: $($reparseRemove.Output.Trim())"
    }

    # leaf がregular fileでもparent platform linkなら外部directoryを辿るため拒否する。
    $parentReparseDirectory = Join-Path $trackedRoot 'parent-reparse'
    $parentReparsePath = Join-Path $parentReparseDirectory 'inside.md'
    $parentReparseTarget = Join-Path $tempRoot 'parent-reparse-external-target'
    New-Item -ItemType Directory -Path $parentReparseDirectory | Out-Null
    New-Item -ItemType Directory -Path $parentReparseTarget | Out-Null
    Set-Content `
        -LiteralPath $parentReparsePath `
        -Value 'synthetic regular parent-chain content' `
        -Encoding UTF8
    $parentReparseAdd = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('add', '--', 'parent-reparse/inside.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($parentReparseAdd.ExitCode -ne 0) {
        Add-Failure "Expected parent-reparse fixture add to succeed. Output: $($parentReparseAdd.Output.Trim())"
    }
    [System.IO.File]::Delete($parentReparsePath)
    [System.IO.Directory]::Delete($parentReparseDirectory)
    Set-Content `
        -LiteralPath (Join-Path $parentReparseTarget 'inside.md') `
        -Value 'synthetic external parent-chain content' `
        -Encoding UTF8
    try {
        New-Item `
            -ItemType $directoryLinkItemType `
            -Path $parentReparseDirectory `
            -Target $parentReparseTarget |
            Out-Null
        $parentReparseResult = Invoke-Scanner `
            -ScanPath $trackedRoot `
            -EnvironmentOverrides $adversarialEnvironment
        if ($parentReparseResult.ExitCode -eq 0 -or
            $parentReparseResult.Output -notmatch 'parent directory is a symlink or reparse point') {
            Add-Failure "Expected a tracked parent junction to fail closed without following it. Output: $($parentReparseResult.Output.Trim())"
        }
    }
    finally {
        if (Test-Path -LiteralPath $parentReparseDirectory) {
            (Get-Item -LiteralPath $parentReparseDirectory -Force).Delete()
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $parentReparseTarget 'inside.md'))) {
        Add-Failure 'Expected parent-junction cleanup not to alter the external synthetic target.'
    }
    $parentReparseRemove = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('update-index', '--force-remove', '--', 'parent-reparse/inside.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($parentReparseRemove.ExitCode -ne 0) {
        Add-Failure "Expected parent-reparse fixture cleanup to succeed. Output: $($parentReparseRemove.Output.Trim())"
    }

    # Corrupt index は working-tree fallback に降格せず、Git present のまま拒否する。
    $targetIndexPath = Join-Path (Join-Path $trackedRoot '.git') 'index'
    $targetIndexBackup = [System.IO.File]::ReadAllBytes($targetIndexPath)
    try {
        [System.IO.File]::WriteAllBytes($targetIndexPath, [byte[]](1, 2, 3, 4))
        $malformedIndexResult = Invoke-Scanner `
            -ScanPath $trackedRoot `
            -EnvironmentOverrides $adversarialEnvironment
        if (-not (Test-FixedIntegrityFailureResult `
                -Result $malformedIndexResult `
                -Reason 'process-boundary' `
                -SensitiveTexts @(
                    $root,
                    $tempRoot,
                    $trackedRoot,
                    $targetIndexPath
                ))) {
            Add-Failure "Expected a malformed index to fail closed. Output: $($malformedIndexResult.Output.Trim())"
        }
    }
    finally {
        [System.IO.File]::WriteAllBytes($targetIndexPath, $targetIndexBackup)
    }

    # 実在する add/add conflict を作り、stage 1/2/3 のどれも blob scanへ進めない。
    $baseBranchResult = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('branch', '--show-current') `
        -IsolationRoot $fixtureIsolationRoot
    $baseBranch = $baseBranchResult.Output.Trim()
    $syntheticEmail = 'synthetic' + '@example.invalid'
    $identityArguments = @(
        '-c',
        'user.name=Synthetic Fixture',
        '-c',
        "user.email=$syntheticEmail",
        '-c',
        'commit.gpgSign=false'
    )
    $baseCommit = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments ($identityArguments + @('commit', '--quiet', '-m', 'synthetic base')) `
        -IsolationRoot $fixtureIsolationRoot
    if ($baseBranchResult.ExitCode -ne 0 -or
        [string]::IsNullOrWhiteSpace($baseBranch) -or
        $baseCommit.ExitCode -ne 0) {
        Add-Failure "Expected conflict fixture base commit to succeed. Output: $($baseCommit.Output.Trim())"
    } else {
        $sideSwitch = Invoke-HermeticGit `
            -WorkingDirectory $trackedRoot `
            -Arguments @('switch', '-c', 'synthetic-conflict-side') `
            -IsolationRoot $fixtureIsolationRoot
        $conflictPath = Join-Path $trackedRoot 'conflict.md'
        Set-Content -LiteralPath $conflictPath -Value 'synthetic side content' -Encoding UTF8
        $sideAdd = Invoke-HermeticGit `
            -WorkingDirectory $trackedRoot `
            -Arguments @('add', '--', 'conflict.md') `
            -IsolationRoot $fixtureIsolationRoot
        $sideCommit = Invoke-HermeticGit `
            -WorkingDirectory $trackedRoot `
            -Arguments ($identityArguments + @('commit', '--quiet', '-m', 'synthetic side')) `
            -IsolationRoot $fixtureIsolationRoot
        $baseSwitch = Invoke-HermeticGit `
            -WorkingDirectory $trackedRoot `
            -Arguments @('switch', $baseBranch) `
            -IsolationRoot $fixtureIsolationRoot
        Set-Content -LiteralPath $conflictPath -Value 'synthetic base content' -Encoding UTF8
        $baseAdd = Invoke-HermeticGit `
            -WorkingDirectory $trackedRoot `
            -Arguments @('add', '--', 'conflict.md') `
            -IsolationRoot $fixtureIsolationRoot
        $mainCommit = Invoke-HermeticGit `
            -WorkingDirectory $trackedRoot `
            -Arguments ($identityArguments + @('commit', '--quiet', '-m', 'synthetic main')) `
            -IsolationRoot $fixtureIsolationRoot
        if (@(
            $sideSwitch,
            $sideAdd,
            $sideCommit,
            $baseSwitch,
            $baseAdd,
            $mainCommit
        ) | Where-Object { $_.ExitCode -ne 0 }) {
            Add-Failure 'Expected conflict fixture branch setup to succeed.'
        } else {
            $mergeResult = Invoke-HermeticGit `
                -WorkingDirectory $trackedRoot `
                -Arguments ($identityArguments + @(
                    'merge',
                    '--no-edit',
                    'synthetic-conflict-side'
                )) `
                -IsolationRoot $fixtureIsolationRoot
            if ($mergeResult.ExitCode -eq 0 -or
                -not $mergeResult.StreamsCompleted -or
                -not $mergeResult.TreeStopped -or
                $mergeResult.Output -notmatch 'CONFLICT') {
                Add-Failure "Expected synthetic merge to produce a bounded conflict. Output: $($mergeResult.Output.Trim())"
            } else {
                $conflictResult = Invoke-Scanner `
                    -ScanPath $trackedRoot `
                    -EnvironmentOverrides $adversarialEnvironment
                if ($conflictResult.ExitCode -eq 0 -or
                    $conflictResult.Output -notmatch 'unresolved conflict') {
                    Add-Failure "Expected unresolved index stages to fail closed. Output: $($conflictResult.Output.Trim())"
                }
            }
            if (Test-Path -LiteralPath (Join-Path (Join-Path $trackedRoot '.git') 'MERGE_HEAD')) {
                $mergeAbort = Invoke-HermeticGit `
                    -WorkingDirectory $trackedRoot `
                    -Arguments @('merge', '--abort') `
                    -IsolationRoot $fixtureIsolationRoot
                if ($mergeAbort.ExitCode -ne 0) {
                    Add-Failure "Expected conflict fixture cleanup to succeed. Output: $($mergeAbort.Output.Trim())"
                }
            }
        }
    }

    foreach ($sentinel in @($traceSentinel, $trace2Sentinel, $hookSentinel, $filterSentinel)) {
        if (Test-Path -LiteralPath $sentinel) {
            Add-Failure "Expected scanner Git children not to create ambient artifact: $(Split-Path -Leaf $sentinel)"
        }
    }

    # scanner が fixture 外の system temp に残す isolation root も差分で検出する。
    $remainingScannerIsolationRoots = @(
        Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) `
            -Directory `
            -Filter 'windows-github-auth-diagnosis-git-*' `
            -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Name }
    )
    $newScannerIsolationRoots = @(
        Compare-Object `
            -ReferenceObject $preexistingScannerIsolationRoots `
            -DifferenceObject $remainingScannerIsolationRoots |
            Where-Object { $_.SideIndicator -eq '=>' } |
            ForEach-Object { "$($_.InputObject)" }
    )
    if ($newScannerIsolationRoots.Count -gt 0) {
        Add-Failure "Expected scanner isolation roots to be cleaned: $($newScannerIsolationRoots -join ', ')."
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

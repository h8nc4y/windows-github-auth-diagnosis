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
$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message) | Out-Null
}

function Get-RepoFilePath {
    param([string]$RelativePath)
    return Join-Path $root $RelativePath
}

function Assert-FileExists {
    param([string]$RelativePath)

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Missing required file: $RelativePath"
    }
}

function Assert-FileContains {
    param(
        [string]$RelativePath,
        [string]$Pattern,
        [string]$Description
    )

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath ($Description)"
        return
    }

    $content = Get-Content -LiteralPath $filePath -Raw
    if ($content -notmatch $Pattern) {
        Add-Failure "$RelativePath is missing: $Description"
    }
}

function Assert-FileHasUtf8Bom {
    param([string]$RelativePath)

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath (UTF-8 BOM contract)"
        return
    }

    $bytes = [System.IO.File]::ReadAllBytes($filePath)
    if ($bytes.Length -lt 3 -or
        $bytes[0] -ne 0xEF -or
        $bytes[1] -ne 0xBB -or
        $bytes[2] -ne 0xBF) {
        Add-Failure "$RelativePath must keep a UTF-8 BOM because Windows PowerShell 5.1 executes its Japanese comments."
    }
}

function Test-PrivateMarkerAstNodeIsDeferredDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Node
    )

    $ancestor = $Node.Parent
    while ($null -ne $ancestor) {
        if ($ancestor -is
                [System.Management.Automation.Language.FunctionDefinitionAst] -or
            $ancestor -is
                [System.Management.Automation.Language.FunctionMemberAst] -or
            $ancestor -is
                [System.Management.Automation.Language.TypeDefinitionAst]) {
            return $true
        }
        if ($ancestor -is
            [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
            # 保存だけされたscriptblockは未実行だが、command argumentや
            # `.Invoke*()`のreceiverなら即時実行され得る。外側ASTまで確認する。
            $container = $ancestor.Parent
            $expressionCanExecuteScriptBlock = $false
            while ($null -ne $container) {
                if ($container -is
                        [System.Management.Automation.Language.FunctionDefinitionAst] -or
                    $container -is
                        [System.Management.Automation.Language.FunctionMemberAst] -or
                    $container -is
                        [System.Management.Automation.Language.TypeDefinitionAst]) {
                    return $true
                }
                if ($container -is
                        [System.Management.Automation.Language.CommandAst] -or
                    $container -is
                        [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
                    $expressionCanExecuteScriptBlock = $true
                    break
                }
                $container = $container.Parent
            }
            if (-not $expressionCanExecuteScriptBlock) {
                return $true
            }
        }
        $ancestor = $ancestor.Parent
    }
    return $false
}

function Test-PrivateMarkerProcessCommandIsDeferredDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.CommandAst]$Command
    )

    return Test-PrivateMarkerAstNodeIsDeferredDefinition -Node $Command
}

function ConvertTo-PrivateMarkerNormalizedCommandName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ''
    }
    $normalized = $Name
    while ($normalized -match
        '^(?i:(?:global|script|local|private|function):)(?<rest>.+)$') {
        $normalized = $Matches['rest']
    }
    # module-qualified commandも末尾の実commandへ正規化する。特に
    # Microsoft.PowerShell.Core\Get-Commandを別commandとして見逃さない。
    if ($normalized -match '^[^\\]+\\(?<command>[^\\]+)$') {
        $normalized = $Matches['command']
    }
    # PowerShell既定alias経由でも、commandの意味は同じものとして判定する。
    # alias自体が後から差し替えられる場合は、下流のshadow検査がfail closedにする。
    switch -Regex ($normalized) {
        '^(?i:gcm)$' { return 'Get-Command' }
        '^(?i:sal)$' { return 'Set-Alias' }
        '^(?i:nal)$' { return 'New-Alias' }
        '^(?i:iex)$' { return 'Invoke-Expression' }
        '^(?i:icm)$' { return 'Invoke-Command' }
        '^(?i:sv)$' { return 'Set-Variable' }
        '^(?i:si)$' { return 'Set-Item' }
        '^(?i:sc)$' { return 'Set-Content' }
        '^(?i:ni)$' { return 'New-Item' }
        '^(?i:copy|cp|cpi)$' { return 'Copy-Item' }
        '^(?i:move|mv|mi)$' { return 'Move-Item' }
        '^(?i:ren|rni)$' { return 'Rename-Item' }
        '^(?i:%|foreach)$' { return 'ForEach-Object' }
        '^(?i:\?|where)$' { return 'Where-Object' }
    }
    return $normalized
}

function ConvertTo-PrivateMarkerNormalizedVariableName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ''
    }
    $normalized = $Name
    if ($normalized -match '^(?i:variable:)(?<name>.+)$') {
        $normalized = [string]$Matches['name']
    }
    while ($normalized -match
        '^(?i:(?:global|script|local|private):)(?<name>.+)$') {
        $normalized = [string]$Matches['name']
    }
    return $normalized
}

function Test-PrivateMarkerAssignmentMutatesCommandProvider {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.AssignmentStatementAst]$Assignment
    )

    # `${alias:name}` / `${function:name}` は通常変数に見えるASTだが、
    # 実際にはcommand resolutionを直接書換えるprovider assignmentである。
    return $Assignment.Left -is
            [System.Management.Automation.Language.VariableExpressionAst] -and
        [string]$Assignment.Left.VariablePath.UserPath -match
            '^(?i:(?:(?:global|script|local|private):)*(?:alias|function):)'
}

function Get-PrivateMarkerStaticCommandArguments {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.CommandAst]$Command
    )

    $values = New-Object System.Collections.Generic.List[string]
    foreach ($element in @($Command.CommandElements | Select-Object -Skip 1)) {
        if ($element -isnot
            [System.Management.Automation.Language.StringConstantExpressionAst]) {
            return [pscustomobject]@{
                IsStatic = $false
                Values = @()
            }
        }
        $values.Add([string]$element.Value) | Out-Null
    }
    return [pscustomobject]@{
        IsStatic = $true
        Values = @($values)
    }
}

function Get-PrivateMarkerStaticMemberName {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.InvokeMemberExpressionAst]$Expression
    )

    if ($Expression.Member -is
        [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return [string]$Expression.Member.Value
    }
    return ''
}

function Test-PrivateMarkerInvokeMemberIsScriptBlockCreate {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.InvokeMemberExpressionAst]$Expression
    )

    $memberName = Get-PrivateMarkerStaticMemberName `
        -Expression $Expression
    return $memberName -ieq 'Create' -and
        $Expression.Static -and
        $Expression.Expression -is
            [System.Management.Automation.Language.TypeExpressionAst] -and
        [string]$Expression.Expression.TypeName.FullName -iin @(
            'scriptblock',
            'System.Management.Automation.ScriptBlock'
        )
}

function Get-PrivateMarkerDirectValueAst {
    param(
        [AllowNull()]
        [System.Management.Automation.Language.Ast]$Node
    )

    # assignment右辺や丸括弧は複数のwrapper ASTを持つ。単一の値式だけを
    # 再帰的に剥がし、command/pipeline合成は静的に同じ値だと推測しない。
    $current = $Node
    while ($null -ne $current) {
        if ($current -is
            [System.Management.Automation.Language.ParenExpressionAst]) {
            $current = $current.Pipeline
            continue
        }
        if ($current -is
            [System.Management.Automation.Language.PipelineAst]) {
            if ($current.PipelineElements.Count -ne 1) {
                return $null
            }
            $current = $current.PipelineElements[0]
            continue
        }
        if ($current -is
            [System.Management.Automation.Language.CommandExpressionAst]) {
            $current = $current.Expression
            continue
        }
        return $current
    }
    return $null
}

function Get-PrivateMarkerScriptBlockValueState {
    param(
        [AllowNull()]
        [System.Management.Automation.Language.Ast]$Node,

        [Parameter(Mandatory = $true)]
        [hashtable]$VariableStates,

        [Parameter(Mandatory = $true)]
        [string[]]$TaintedNames
    )

    $directValue = Get-PrivateMarkerDirectValueAst -Node $Node
    if ($directValue -is
        [System.Management.Automation.Language.VariableExpressionAst]) {
        $variableName = ConvertTo-PrivateMarkerNormalizedVariableName `
            -Name ([string]$directValue.VariablePath.UserPath)
        if ($VariableStates.ContainsKey($variableName)) {
            return [string]$VariableStates[$variableName]
        }
        return 'Unknown'
    }
    if ($directValue -is
        [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
        if (Test-PrivateMarkerScriptBlockExpressionIsTainted `
                -Expression $directValue `
                -TaintedNames $TaintedNames) {
            return 'Tainted'
        }
        return 'Safe'
    }
    if ($directValue -is
            [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        (Test-PrivateMarkerInvokeMemberIsScriptBlockCreate `
            -Expression $directValue)) {
        return 'Tainted'
    }
    if ($null -eq $Node) {
        return 'Unknown'
    }

    # composite式はSafeな部分式を含んでも全体の由来を証明できない。
    # ただし既知tainted/Createが混ざる場合は後続copyへTaintedを伝播する。
    $createCalls = @(
        $Node.FindAll(
            {
                param($candidate)
                return $candidate -is
                        [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                    (Test-PrivateMarkerInvokeMemberIsScriptBlockCreate `
                        -Expression $candidate)
            },
            $true
        )
    )
    if ($createCalls.Count -ne 0) {
        return 'Tainted'
    }
    $nestedScriptBlocks = @(
        $Node.FindAll(
            {
                param($candidate)
                return $candidate -is
                    [System.Management.Automation.Language.ScriptBlockExpressionAst]
            },
            $true
        )
    )
    foreach ($nestedScriptBlock in $nestedScriptBlocks) {
        if (Test-PrivateMarkerScriptBlockExpressionIsTainted `
                -Expression $nestedScriptBlock `
                -TaintedNames $TaintedNames) {
            return 'Tainted'
        }
    }
    $nestedVariables = @(
        $Node.FindAll(
            {
                param($candidate)
                return $candidate -is
                    [System.Management.Automation.Language.VariableExpressionAst]
            },
            $true
        )
    )
    foreach ($nestedVariable in $nestedVariables) {
        $nestedName = ConvertTo-PrivateMarkerNormalizedVariableName `
            -Name ([string]$nestedVariable.VariablePath.UserPath)
        if ($VariableStates.ContainsKey($nestedName) -and
            $VariableStates[$nestedName] -eq 'Tainted') {
            return 'Tainted'
        }
    }
    return 'Unknown'
}

function Get-PrivateMarkerCommandArgumentNode {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.CommandAst]$Command,

        [Parameter(Mandatory = $true)]
        [string[]]$ParameterNames,

        [Parameter(Mandatory = $true)]
        [int]$Position
    )

    $elements = @($Command.CommandElements)
    for ($index = 1; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]
        if ($element -isnot
            [System.Management.Automation.Language.CommandParameterAst]) {
            continue
        }
        if ($ParameterNames -inotcontains [string]$element.ParameterName) {
            continue
        }
        if ($null -ne $element.Argument) {
            return $element.Argument
        }
        if ($index + 1 -lt $elements.Count -and
            $elements[$index + 1] -isnot
                [System.Management.Automation.Language.CommandParameterAst]) {
            return $elements[$index + 1]
        }
        return $null
    }

    # named parameter値もnon-parameter elementとして現れるため、同じcommandの
    # positional表現とnamed表現を1つの保守的なfallbackで扱う。
    $valueElements = @(
        $elements |
            Select-Object -Skip 1 |
            Where-Object {
                $_ -isnot
                    [System.Management.Automation.Language.CommandParameterAst]
            }
    )
    if ($Position -lt 0 -or $Position -ge $valueElements.Count) {
        return $null
    }
    return $valueElements[$Position]
}

function Get-PrivateMarkerScriptBlockArgumentNodes {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.CommandAst]$Command,

        [Parameter(Mandatory = $true)]
        [string]$CommandName
    )

    $scriptBlockParameters = switch ($CommandName) {
        'ForEach-Object' {
            @('Begin', 'Process', 'End', 'RemainingScripts')
            break
        }
        'Where-Object' {
            @('FilterScript', 'ScriptBlock')
            break
        }
        'Invoke-Command' {
            @('ScriptBlock')
            break
        }
        'Measure-Command' {
            @('Expression')
            break
        }
        default {
            return @()
        }
    }

    $candidates = New-Object `
        'System.Collections.Generic.List[System.Management.Automation.Language.Ast]'
    $elements = @($Command.CommandElements)
    $hasNamedScriptBlock = $false
    for ($index = 1; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]
        if ($element -isnot
                [System.Management.Automation.Language.CommandParameterAst] -or
            $scriptBlockParameters -inotcontains
                [string]$element.ParameterName) {
            continue
        }
        $hasNamedScriptBlock = $true
        if ($null -ne $element.Argument) {
            $candidates.Add($element.Argument) | Out-Null
        } elseif ($index + 1 -lt $elements.Count -and
            $elements[$index + 1] -isnot
                [System.Management.Automation.Language.CommandParameterAst]) {
            $candidates.Add($elements[$index + 1]) | Out-Null
        } else {
            # ScriptBlock parameter自体が欠落した形も安全と証明できない。
            $candidates.Add($Command) | Out-Null
            return @($candidates)
        }
    }

    if (-not $hasNamedScriptBlock) {
        $positionals = @(
            $elements |
                Select-Object -Skip 1 |
                Where-Object {
                    $_ -isnot
                        [System.Management.Automation.Language.CommandParameterAst]
                }
        )
        if ($CommandName -iin @(
                'Invoke-Command',
                'Where-Object',
                'Measure-Command'
            )) {
            if ($positionals.Count -ne 0) {
                $candidates.Add($positionals[0]) | Out-Null
            }
        } else {
            foreach ($positional in $positionals) {
                # ForEach-ObjectはBegin/Process/Endをpositionalにも取る。
                # 静的文字列だけはMemberName形式として除き、式は状態表へ渡す。
                if ($positional -isnot
                    [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $candidates.Add($positional) | Out-Null
                }
            }
        }
    }
    return @($candidates)
}

function Resolve-PrivateMarkerStaticStringValue {
    param(
        [AllowNull()]
        [System.Management.Automation.Language.Ast]$Node,

        [Parameter(Mandatory = $true)]
        [hashtable]$VariableValues
    )

    $directValue = Get-PrivateMarkerDirectValueAst -Node $Node
    if ($directValue -is
        [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return [pscustomobject]@{
            IsStatic = $true
            Value = [string]$directValue.Value
        }
    }
    if ($directValue -is
        [System.Management.Automation.Language.VariableExpressionAst]) {
        $variableName = ConvertTo-PrivateMarkerNormalizedVariableName `
            -Name ([string]$directValue.VariablePath.UserPath)
        if ($VariableValues.ContainsKey($variableName)) {
            return [pscustomobject]@{
                IsStatic = $true
                Value = [string]$VariableValues[$variableName]
            }
        }
    }
    return [pscustomobject]@{
        IsStatic = $false
        Value = ''
    }
}

function Resolve-PrivateMarkerStaticStringValueBeforeOffset {
    param(
        [AllowNull()]
        [System.Management.Automation.Language.Ast]$Node,

        [Parameter(Mandatory = $true)]
        [hashtable]$VariableHistory,

        [Parameter(Mandatory = $true)]
        [int]$MaximumOffset
    )

    $directValue = Get-PrivateMarkerDirectValueAst -Node $Node
    if ($directValue -is
        [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return [pscustomobject]@{
            IsStatic = $true
            Value = [string]$directValue.Value
        }
    }
    if ($directValue -is
        [System.Management.Automation.Language.VariableExpressionAst]) {
        $variableName = ConvertTo-PrivateMarkerNormalizedVariableName `
            -Name ([string]$directValue.VariablePath.UserPath)
        if ($VariableHistory.ContainsKey($variableName)) {
            $eligibleEntries = @(
                $VariableHistory[$variableName] |
                    Where-Object { $_.Offset -lt $MaximumOffset } |
                    Sort-Object Offset
            )
            if ($eligibleEntries.Count -ne 0) {
                $latestEntry = $eligibleEntries[-1]
                if ($latestEntry.IsStatic) {
                    return [pscustomobject]@{
                        IsStatic = $true
                        Value = [string]$latestEntry.Value
                    }
                }
            }
        }
    }
    return [pscustomobject]@{
        IsStatic = $false
        Value = ''
    }
}

function Test-PrivateMarkerFileSystemPathValueBeforeOffset {
    param(
        [AllowNull()]
        [System.Management.Automation.Language.Ast]$Node,

        [Parameter(Mandatory = $true)]
        [hashtable]$VariableHistory,

        [Parameter(Mandatory = $true)]
        [int]$MaximumOffset
    )

    $directValue = Get-PrivateMarkerDirectValueAst -Node $Node
    if ($directValue -is
        [System.Management.Automation.Language.StringConstantExpressionAst]) {
        # Alias/Function/Variable providerだけがこのgateのcommand解決や
        # bootstrapを変更できる。通常の相対pathやfilesystem driveは許可する。
        return [string]$directValue.Value -notmatch
            '^(?i:(?:Alias|Function|Variable):)'
    }
    if ($directValue -is
        [System.Management.Automation.Language.VariableExpressionAst]) {
        $variableName = ConvertTo-PrivateMarkerNormalizedVariableName `
            -Name ([string]$directValue.VariablePath.UserPath)
        if ($variableName -iin @('PSScriptRoot', 'PSHOME')) {
            return $true
        }
        if (-not $VariableHistory.ContainsKey($variableName)) {
            return $false
        }
        $eligibleEntries = @(
            $VariableHistory[$variableName] |
                Where-Object { $_.Offset -lt $MaximumOffset } |
                Sort-Object Offset
        )
        return $eligibleEntries.Count -ne 0 -and
            [bool]$eligibleEntries[-1].IsFileSystemPath
    }
    if ($directValue -is
            [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $directValue.Static -and
        (Get-PrivateMarkerStaticMemberName -Expression $directValue) -ieq
            'GetTempPath' -and
        $directValue.Expression -is
            [System.Management.Automation.Language.TypeExpressionAst] -and
        [string]$directValue.Expression.TypeName.FullName -iin @(
            'IO.Path',
            'System.IO.Path'
        )) {
        return $true
    }
    if ($directValue -is
        [System.Management.Automation.Language.CommandAst]) {
        $commandName = ConvertTo-PrivateMarkerNormalizedCommandName `
            -Name $directValue.GetCommandName()
        if ($commandName -ieq 'Join-Path') {
            # child側に `Alias:` 風の文字列があっても、filesystemと証明済みの
            # baseへJoinする限りprovider自体は切り替わらない。
            $basePathNode = Get-PrivateMarkerCommandArgumentNode `
                -Command $directValue `
                -ParameterNames @('Path') `
                -Position 0
            return Test-PrivateMarkerFileSystemPathValueBeforeOffset `
                -Node $basePathNode `
                -VariableHistory $VariableHistory `
                -MaximumOffset $MaximumOffset
        }
    }
    return $false
}

function Test-PrivateMarkerScriptBlockExpressionIsTainted {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.ScriptBlockExpressionAst]$Expression,

        [Parameter(Mandatory = $true)]
        [string[]]$TaintedNames
    )

    # 保存時点ではdeferredでも、後続Invokeで実行されるbody内のhelper到達を
    # 独立に判定する。dynamic commandやalias mutationも安全と推測しない。
    $commands = @(
        $Expression.FindAll(
            {
                param($node)
                return $node -is
                    [System.Management.Automation.Language.CommandAst]
            },
            $true
        )
    )
    foreach ($command in $commands) {
        $commandName =
            ConvertTo-PrivateMarkerNormalizedCommandName `
                -Name $command.GetCommandName()
        if ([string]::IsNullOrWhiteSpace($commandName) -or
            $TaintedNames -icontains $commandName -or
            $commandName -iin @(
                'Invoke-Expression',
                'Set-Alias',
                'New-Alias',
                'Set-Variable',
                'Set-Item',
                'Set-Content',
                'New-Item',
                'Copy-Item',
                'Move-Item',
                'Rename-Item'
            )) {
            return $true
        }
        if ($commandName -ieq 'Get-Command') {
            $arguments =
                Get-PrivateMarkerStaticCommandArguments `
                    -Command $command
            if (-not $arguments.IsStatic -or
                $arguments.Values.Count -ne 1 -or
                $TaintedNames -icontains (
                    ConvertTo-PrivateMarkerNormalizedCommandName `
                        -Name $arguments.Values[0]
                )) {
                return $true
            }
        }
    }

    $providerAssignments = @(
        $Expression.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.AssignmentStatementAst] -and
                    (Test-PrivateMarkerAssignmentMutatesCommandProvider `
                        -Assignment $node)
            },
            $true
        )
    )
    if ($providerAssignments.Count -ne 0) {
        return $true
    }

    $functionProviderReferences = @(
        $Expression.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.VariableExpressionAst] -and
                    $node.VariablePath.UserPath -match
                        '^(?i:function:)(?<name>.+)$'
            },
            $true
        )
    )
    foreach ($reference in $functionProviderReferences) {
        $name = ConvertTo-PrivateMarkerNormalizedCommandName `
            -Name $reference.VariablePath.UserPath
        if ($TaintedNames -icontains $name) {
            return $true
        }
    }

    # ScriptBlock.Createの入力文字列・式は生成時に任意codeへなり得る。
    # literal bodyを再解釈して安全と推測せず、後続Invoke用にはtaintedとする。
    $scriptBlockCreateCalls = @(
        $Expression.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                    (Test-PrivateMarkerInvokeMemberIsScriptBlockCreate `
                        -Expression $node)
            },
            $true
        )
    )
    return $scriptBlockCreateCalls.Count -ne 0
}

function Test-PrivateMarkerAliasTargetsTaintedCommand {
    param(
        [string]$Name,
        [hashtable]$Aliases,
        [string[]]$TaintedNames
    )

    $current = ConvertTo-PrivateMarkerNormalizedCommandName -Name $Name
    $visited = @{}
    while ($Aliases.ContainsKey($current)) {
        # alias cycleや壊れたtargetを「安全」と推測しない。
        if ($visited.ContainsKey($current)) {
            return $true
        }
        $visited[$current] = $true
        $current = ConvertTo-PrivateMarkerNormalizedCommandName `
            -Name ([string]$Aliases[$current])
        if ([string]::IsNullOrWhiteSpace($current) -or
            $TaintedNames -icontains $current) {
            return $true
        }
    }
    return $false
}

function Get-PrivateMarkerTaintedFunctionNames {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.ScriptBlockAst]$SourceAst
    )

    # helperを直接または別wrapper経由で呼ぶfunctionを固定点まで伝播する。
    # 呼出先を静的に確定できないfunctionも、早期実行時は安全と証明できない。
    $taintedNames = @('Invoke-PrivateMarkerProcess')
    $definitions = @(
        $SourceAst.FindAll(
            {
                param($node)
                return $node -is
                    [System.Management.Automation.Language.FunctionDefinitionAst]
            },
            $true
        )
    )
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($definition in $definitions) {
            $definitionName =
                ConvertTo-PrivateMarkerNormalizedCommandName `
                    -Name $definition.Name
            if ($taintedNames -icontains $definitionName) {
                continue
            }

            $ownedCalls = @(
                $definition.Body.FindAll(
                    {
                        param($node)
                        if ($node -isnot
                            [System.Management.Automation.Language.CommandAst]) {
                            return $false
                        }
                        $owner = $node.Parent
                        while ($null -ne $owner -and
                            $owner -isnot
                                [System.Management.Automation.Language.FunctionDefinitionAst]) {
                            $owner = $owner.Parent
                        }
                        return [object]::ReferenceEquals(
                            $owner,
                            $definition
                        )
                    },
                    $true
                )
            )
            $definitionIsTainted = $false
            foreach ($call in $ownedCalls) {
                $callName = ConvertTo-PrivateMarkerNormalizedCommandName `
                    -Name $call.GetCommandName()
                if ([string]::IsNullOrWhiteSpace($callName) -or
                    $taintedNames -icontains $callName -or
                    $callName -iin @(
                        'Invoke-Expression',
                        'Set-Alias',
                        'New-Alias',
                        'Set-Variable',
                        'Set-Item',
                        'Set-Content',
                        'New-Item',
                        'Copy-Item',
                        'Move-Item',
                        'Rename-Item'
                    )) {
                    $definitionIsTainted = $true
                    break
                }
                if ($callName -ieq 'Get-Command') {
                    $commandArguments =
                        Get-PrivateMarkerStaticCommandArguments -Command $call
                    if (-not $commandArguments.IsStatic -or
                        $commandArguments.Values.Count -ne 1 -or
                        $taintedNames -icontains (
                            ConvertTo-PrivateMarkerNormalizedCommandName `
                                -Name $commandArguments.Values[0]
                        )) {
                        $definitionIsTainted = $true
                        break
                    }
                }
            }
            $ownedProviderAssignments = @(
                $definition.Body.FindAll(
                    {
                        param($node)
                        if ($node -isnot
                                [System.Management.Automation.Language.AssignmentStatementAst] -or
                            -not (
                                Test-PrivateMarkerAssignmentMutatesCommandProvider `
                                    -Assignment $node
                            )) {
                            return $false
                        }
                        $owner = $node.Parent
                        while ($null -ne $owner -and
                            $owner -isnot
                                [System.Management.Automation.Language.FunctionDefinitionAst]) {
                            $owner = $owner.Parent
                        }
                        return [object]::ReferenceEquals(
                            $owner,
                            $definition
                        )
                    },
                    $true
                )
            )
            if ($ownedProviderAssignments.Count -ne 0) {
                $definitionIsTainted = $true
            }
            if ($definitionIsTainted) {
                $taintedNames += $definitionName
                $changed = $true
            }
        }
    }
    return @($taintedNames)
}

function Get-PrivateMarkerTaintedTypeNames {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.ScriptBlockAst]$SourceAst,

        [Parameter(Mandatory = $true)]
        [string[]]$TaintedFunctionNames
    )

    # class constructor/method内のhelper callは定義時にはdeferredでも、
    # raw assignment前の型生成やmember callで即時実行できる。type単位で
    # 到達可能性を保持し、外側のTypeExpression検査へ渡す。
    $taintedTypeNames =
        New-Object System.Collections.Generic.List[string]
    $typeDefinitions = @(
        $SourceAst.FindAll(
            {
                param($node)
                return $node -is
                    [System.Management.Automation.Language.TypeDefinitionAst]
            },
            $true
        )
    )
    foreach ($typeDefinition in $typeDefinitions) {
        $typeIsTainted = $false
        $ownedCommands = @(
            $typeDefinition.FindAll(
                {
                    param($node)
                    if ($node -isnot
                        [System.Management.Automation.Language.CommandAst]) {
                        return $false
                    }
                    $owner = $node.Parent
                    while ($null -ne $owner -and
                        $owner -isnot
                            [System.Management.Automation.Language.TypeDefinitionAst]) {
                        $owner = $owner.Parent
                    }
                    return [object]::ReferenceEquals(
                        $owner,
                        $typeDefinition
                    )
                },
                $true
            )
        )
        foreach ($command in $ownedCommands) {
            $commandName =
                ConvertTo-PrivateMarkerNormalizedCommandName `
                    -Name $command.GetCommandName()
            if ([string]::IsNullOrWhiteSpace($commandName) -or
                $TaintedFunctionNames -icontains $commandName -or
                $commandName -iin @(
                    'Invoke-Expression',
                    'Set-Alias',
                    'New-Alias',
                    'Set-Variable',
                    'Set-Item',
                    'Set-Content',
                    'New-Item',
                    'Copy-Item',
                    'Move-Item',
                    'Rename-Item'
                )) {
                $typeIsTainted = $true
                break
            }
            if ($commandName -ieq 'Get-Command') {
                $arguments =
                    Get-PrivateMarkerStaticCommandArguments `
                        -Command $command
                if (-not $arguments.IsStatic -or
                    $arguments.Values.Count -ne 1 -or
                    $TaintedFunctionNames -icontains (
                        ConvertTo-PrivateMarkerNormalizedCommandName `
                            -Name $arguments.Values[0]
                    )) {
                    $typeIsTainted = $true
                    break
                }
            }
        }
        $ownedProviderAssignments = @(
            $typeDefinition.FindAll(
                {
                    param($node)
                    if ($node -isnot
                            [System.Management.Automation.Language.AssignmentStatementAst] -or
                        -not (
                            Test-PrivateMarkerAssignmentMutatesCommandProvider `
                                -Assignment $node
                        )) {
                        return $false
                    }
                    $owner = $node.Parent
                    while ($null -ne $owner -and
                        $owner -isnot
                            [System.Management.Automation.Language.TypeDefinitionAst]) {
                        $owner = $owner.Parent
                    }
                    return [object]::ReferenceEquals(
                        $owner,
                        $typeDefinition
                    )
                },
                $true
            )
        )
        if ($ownedProviderAssignments.Count -ne 0) {
            $typeIsTainted = $true
        }
        if ($typeIsTainted) {
            $taintedTypeNames.Add(
                [string]$typeDefinition.Name
            ) | Out-Null
        }
    }

    # derived classはbodyが空でもbaseのconstructor/memberを実行できる。
    # 宣言順に依存しないよう、tainted baseを固定点まで派生型へ伝播する。
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($typeDefinition in $typeDefinitions) {
            if ($taintedTypeNames -icontains
                [string]$typeDefinition.Name) {
                continue
            }
            foreach ($baseType in @($typeDefinition.BaseTypes)) {
                if ($taintedTypeNames -icontains
                    [string]$baseType.TypeName.FullName) {
                    $taintedTypeNames.Add(
                        [string]$typeDefinition.Name
                    ) | Out-Null
                    $changed = $true
                    break
                }
            }
        }
    }
    return @($taintedTypeNames)
}

function Test-FirstTopLevelProcessInvocationIsBinarySource {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    # 行番号やregex順序ではなく、binary fixture assignmentが直接1個の
    # helper commandを所有し、それ以前にeager callがないことをASTで判定する。
    $tokens = $null
    $parseErrors = $null
    $sourceAst = [System.Management.Automation.Language.Parser]::ParseInput(
        $Source,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        return $false
    }

    $binaryAssignments = @(
        $sourceAst.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left -is
                        [System.Management.Automation.Language.VariableExpressionAst] -and
                    $node.Left.VariablePath.UserPath -eq 'binaryPipeResult'
            },
            $true
        )
    )
    if ($binaryAssignments.Count -ne 1 -or
        $binaryAssignments[0].Right -isnot
            [System.Management.Automation.Language.PipelineAst]) {
        return $false
    }

    $binaryPipelineElements = @(
        $binaryAssignments[0].Right.PipelineElements
    )
    if ($binaryPipelineElements.Count -ne 1 -or
        $binaryPipelineElements[0] -isnot
            [System.Management.Automation.Language.CommandAst] -or
        $binaryPipelineElements[0].GetCommandName() -ne
            'Invoke-PrivateMarkerProcess' -or
        $binaryPipelineElements[0].Extent.Text -notmatch
            '(?s)-StandardInputBytes\s+\$binaryProbeBytes\b') {
        return $false
    }
    $binaryOuterCommand = $binaryPipelineElements[0]
    $binaryNestedCalls = @(
        $binaryAssignments[0].Right.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq
                        'Invoke-PrivateMarkerProcess'
            },
            $true
        )
    )
    if ($binaryNestedCalls.Count -ne 1 -or
        (Test-PrivateMarkerProcessCommandIsDeferredDefinition `
            -Command $binaryOuterCommand)) {
        return $false
    }

    $taintedNames = @(
        Get-PrivateMarkerTaintedFunctionNames -SourceAst $sourceAst
    )
    $taintedTypeNames = @(
        Get-PrivateMarkerTaintedTypeNames `
            -SourceAst $sourceAst `
            -TaintedFunctionNames $taintedNames
    )

    $commandProviderAssignmentsBeforeBinary = @(
        $sourceAst.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Extent.StartOffset -lt
                        $binaryOuterCommand.Extent.StartOffset -and
                    (Test-PrivateMarkerAssignmentMutatesCommandProvider `
                        -Assignment $node)
            },
            $true
        ) |
            Where-Object {
                -not (Test-PrivateMarkerAstNodeIsDeferredDefinition `
                    -Node $_)
            }
    )
    if ($commandProviderAssignmentsBeforeBinary.Count -ne 0) {
        return $false
    }

    # top-levelで保存されたScriptBlockと静的文字列の由来をsource orderで
    # 追う。assignmentだけでなくSet-Variableも同じ状態表へ入れ、command
    # argument、provider path、`.Invoke*()`で別々の抜け道を作らない。
    $scriptBlockVariableStates = @{}
    $staticStringVariableValues = @{}
    $staticStringVariableHistory = @{}
    $processBoundaryAssignmentCount = 0
    $stateEventsBeforeBinary = @(
        $sourceAst.FindAll(
            {
                param($node)
                if ($node.Extent.StartOffset -ge
                    $binaryOuterCommand.Extent.StartOffset) {
                    return $false
                }
                if ($node -is
                    [System.Management.Automation.Language.AssignmentStatementAst]) {
                    return $true
                }
                if ($node -isnot
                    [System.Management.Automation.Language.CommandAst]) {
                    return $false
                }
                return (
                    ConvertTo-PrivateMarkerNormalizedCommandName `
                        -Name $node.GetCommandName()
                ) -ieq 'Set-Variable'
            },
            $true
        ) |
            Where-Object {
                -not (Test-PrivateMarkerAstNodeIsDeferredDefinition `
                    -Node $_)
            } |
            Sort-Object { $_.Extent.StartOffset }
    )
    foreach ($stateEvent in $stateEventsBeforeBinary) {
        $variableName = ''
        $valueNode = $null
        if ($stateEvent -is
            [System.Management.Automation.Language.AssignmentStatementAst]) {
            if ($stateEvent.Left -isnot
                [System.Management.Automation.Language.VariableExpressionAst]) {
                continue
            }
            $variableName =
                ConvertTo-PrivateMarkerNormalizedVariableName `
                    -Name ([string]$stateEvent.Left.VariablePath.UserPath)
            $valueNode = $stateEvent.Right

            # production bootstrapは既知のrepo-local helper解決を1回だけ許す。
            # 直接代入であっても別pathや再代入ならdot-source先を証明できない。
            if ($variableName -ieq 'processBoundary') {
                $processBoundaryAssignmentCount++
                if ($processBoundaryAssignmentCount -ne 1 -or
                    $stateEvent.Right.Extent.Text.Trim() -notmatch
                        "^(?s)Join-Path\s+\`$root\s+['""]scripts/private-marker-process\.ps1['""]$") {
                    return $false
                }
            }
        } else {
            $nameNode = Get-PrivateMarkerCommandArgumentNode `
                -Command $stateEvent `
                -ParameterNames @('Name') `
                -Position 0
            $resolvedName = Resolve-PrivateMarkerStaticStringValue `
                -Node $nameNode `
                -VariableValues $staticStringVariableValues
            if (-not $resolvedName.IsStatic) {
                # 動的nameは既知Safe変数を上書きし得るためfail closedにする。
                return $false
            }
            $variableName =
                ConvertTo-PrivateMarkerNormalizedVariableName `
                    -Name ([string]$resolvedName.Value)
            if ($variableName -ieq 'processBoundary') {
                # Set-Variableは-Scope 1を含めbootstrapのowner scopeを
                # 書換えられる。既知の直接初期化以外は一律拒否する。
                return $false
            }
            $valueNode = Get-PrivateMarkerCommandArgumentNode `
                -Command $stateEvent `
                -ParameterNames @('Value') `
                -Position 1
        }
        if ([string]::IsNullOrWhiteSpace($variableName)) {
            return $false
        }

        $newState = Get-PrivateMarkerScriptBlockValueState `
            -Node $valueNode `
            -VariableStates $scriptBlockVariableStates `
            -TaintedNames $taintedNames
        if (-not $scriptBlockVariableStates.ContainsKey($variableName)) {
            $scriptBlockVariableStates[$variableName] = $newState
        } else {
            $existingState =
                [string]$scriptBlockVariableStates[$variableName]
            if ($existingState -eq 'Tainted' -or
                $newState -eq 'Tainted') {
                $scriptBlockVariableStates[$variableName] = 'Tainted'
            } elseif ($existingState -eq 'Unknown' -or
                $newState -eq 'Unknown') {
                $scriptBlockVariableStates[$variableName] = 'Unknown'
            } else {
                $scriptBlockVariableStates[$variableName] = 'Safe'
            }
        }

        $staticStringValue = Resolve-PrivateMarkerStaticStringValue `
            -Node $valueNode `
            -VariableValues $staticStringVariableValues
        $isFileSystemPath =
            Test-PrivateMarkerFileSystemPathValueBeforeOffset `
                -Node $valueNode `
                -VariableHistory $staticStringVariableHistory `
                -MaximumOffset $stateEvent.Extent.StartOffset
        if ($staticStringValue.IsStatic) {
            $staticStringVariableValues[$variableName] =
                [string]$staticStringValue.Value
        } elseif ($staticStringVariableValues.ContainsKey($variableName)) {
            $staticStringVariableValues.Remove($variableName)
        }
        if (-not $staticStringVariableHistory.ContainsKey($variableName)) {
            $staticStringVariableHistory[$variableName] = @()
        }
        $staticStringVariableHistory[$variableName] = @(
            $staticStringVariableHistory[$variableName]
        ) + @(
            [pscustomobject]@{
                Offset = [int]$stateEvent.Extent.StartOffset
                IsStatic = [bool]$staticStringValue.IsStatic
                Value = if ($staticStringValue.IsStatic) {
                    [string]$staticStringValue.Value
                } else {
                    ''
                }
                IsFileSystemPath = [bool]$isFileSystemPath
            }
        )
    }

    # Invoke/InvokeReturnAsIsはCommandAstではない。receiverがtainted/unknown
    # variable、ScriptBlock.Create、tainted literalならbinary fixture前に拒否する。
    $memberInvocationsBeforeBinary = @(
        $sourceAst.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                    $node.Extent.StartOffset -lt
                        $binaryOuterCommand.Extent.StartOffset
            },
            $true
        ) |
            Where-Object {
                -not (Test-PrivateMarkerAstNodeIsDeferredDefinition `
                    -Node $_)
            } |
            Sort-Object { $_.Extent.StartOffset }
    )
    foreach ($memberInvocation in $memberInvocationsBeforeBinary) {
        $memberName = Get-PrivateMarkerStaticMemberName `
            -Expression $memberInvocation
        if ($memberName -in @(
                'Invoke',
                'InvokeReturnAsIs',
                'InvokeWithContext'
            )) {
            # receiver全体が直接Safeと証明できる場合だけ許可する。composite式に
            # Safe変数が一部あるだけでは、Get-Variable等の別経路を免除しない。
            $receiverState = Get-PrivateMarkerScriptBlockValueState `
                -Node $memberInvocation.Expression `
                -VariableStates $scriptBlockVariableStates `
                -TaintedNames $taintedNames
            if ($receiverState -ne 'Safe') {
                return $false
            }
        }
    }

    # raw assignmentより前にtarget名のfunctionを定義すると、同じ見た目の
    # commandがdot-source済みhelperではなくshadowへ解決されるため拒否する。
    $targetFunctionShadows = @(
        $sourceAst.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Extent.StartOffset -lt
                        $binaryOuterCommand.Extent.StartOffset -and
                    (ConvertTo-PrivateMarkerNormalizedCommandName `
                        -Name $node.Name) -ieq
                        'Invoke-PrivateMarkerProcess'
            },
            $true
        )
    )
    if ($targetFunctionShadows.Count -ne 0) {
        return $false
    }

    # `${function:Name}`はCommandAstを生成せずにfunctionのScriptBlockを
    # 取り出せる。raw assignmentより前のtainted参照はInvoke()/Invoke-Command
    # などの実行形へ流せるため、静的に無害と証明せず拒否する。
    $functionProviderReferences = @(
        $sourceAst.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.VariableExpressionAst] -and
                    $node.Extent.StartOffset -lt
                        $binaryOuterCommand.Extent.StartOffset -and
                    $node.VariablePath.UserPath -match
                        '^(?i:function:)(?<name>.+)$'
            },
            $true
        )
    )
    foreach ($reference in $functionProviderReferences) {
        $referencedFunctionName =
            ConvertTo-PrivateMarkerNormalizedCommandName `
                -Name $reference.VariablePath.UserPath
        if ($taintedNames -icontains $referencedFunctionName) {
            return $false
        }
    }

    # tainted classをraw assignment前に型として参照する場合、constructor
    # またはmemberからhelperへ到達し得る。class定義自身の型注釈は除外する。
    $typeReferencesBeforeBinary = @(
        $sourceAst.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.TypeExpressionAst] -and
                    $node.Extent.StartOffset -lt
                        $binaryOuterCommand.Extent.StartOffset
            },
            $true
        )
    )
    foreach ($typeReference in $typeReferencesBeforeBinary) {
        $insideTypeDefinition = $false
        $ancestor = $typeReference.Parent
        while ($null -ne $ancestor) {
            if ($ancestor -is
                [System.Management.Automation.Language.TypeDefinitionAst]) {
                $insideTypeDefinition = $true
                break
            }
            $ancestor = $ancestor.Parent
        }
        if (-not $insideTypeDefinition -and
            $taintedTypeNames -icontains
                [string]$typeReference.TypeName.FullName) {
            return $false
        }
    }

    $aliases = @{}
    $commandsBeforeBinary = @(
        $sourceAst.FindAll(
            {
                param($node)
                return $node -is
                        [System.Management.Automation.Language.CommandAst] -and
                    $node.Extent.StartOffset -lt
                        $binaryOuterCommand.Extent.StartOffset
            },
            $true
        ) |
            Where-Object {
                -not (Test-PrivateMarkerProcessCommandIsDeferredDefinition `
                    -Command $_)
            } |
            Sort-Object { $_.Extent.StartOffset }
    )
    foreach ($command in $commandsBeforeBinary) {
        $rawCommandName = $command.GetCommandName()
        if ([string]::IsNullOrWhiteSpace($rawCommandName)) {
            # production helperを定義する既知のdot-sourceだけを例外とし、
            # call operatorや式で組み立てたcommandは静的証明不能として拒否する。
            if ($command.InvocationOperator.ToString() -eq 'Dot' -and
                $command.Extent.Text.Trim() -ceq '. $processBoundary') {
                continue
            }
            return $false
        }

        $commandName = ConvertTo-PrivateMarkerNormalizedCommandName `
            -Name $rawCommandName
        if ($taintedNames -icontains $commandName -or
            (Test-PrivateMarkerAliasTargetsTaintedCommand `
                -Name $commandName `
                -Aliases $aliases `
                -TaintedNames $taintedNames)) {
            return $false
        }
        if ($commandName -iin @(
                'Copy-Item',
                'Move-Item',
                'Rename-Item'
            )) {
            # provider内のcopy/move/renameは既存Alias/Functionをtarget名へ
            # 複製・改名できる。filesystemだけと証明するより前は一律拒否する。
            return $false
        }

        if ($commandName -ieq 'ForEach-Object') {
            # MemberName parameterはscriptblock引数ではないが、Invoke系memberなら
            # pipeline input上のScriptBlockを即時実行する。dynamic member名は
            # 安全なmemberと証明できないためfail closedにする。
            $memberNameParameterIndex = -1
            $commandElements = @($command.CommandElements)
            for ($elementIndex = 1;
                $elementIndex -lt $commandElements.Count;
                $elementIndex++) {
                $element = $commandElements[$elementIndex]
                if ($element -is
                        [System.Management.Automation.Language.CommandParameterAst] -and
                    [string]$element.ParameterName -ieq 'MemberName') {
                    if ($memberNameParameterIndex -ne -1) {
                        return $false
                    }
                    $memberNameParameterIndex = $elementIndex
                }
            }
            if ($memberNameParameterIndex -ne -1) {
                $memberNameNode =
                    $commandElements[$memberNameParameterIndex].Argument
                if ($null -eq $memberNameNode -and
                    $memberNameParameterIndex + 1 -lt
                        $commandElements.Count -and
                    $commandElements[$memberNameParameterIndex + 1] -isnot
                        [System.Management.Automation.Language.CommandParameterAst]) {
                    $memberNameNode =
                        $commandElements[$memberNameParameterIndex + 1]
                }
                $resolvedMemberName =
                    Resolve-PrivateMarkerStaticStringValueBeforeOffset `
                        -Node $memberNameNode `
                        -VariableHistory $staticStringVariableHistory `
                        -MaximumOffset $command.Extent.StartOffset
                if (-not $resolvedMemberName.IsStatic) {
                    return $false
                }
                if ([string]$resolvedMemberName.Value -iin @(
                        'Invoke',
                        'InvokeReturnAsIs',
                        'InvokeWithContext'
                    )) {
                    $pipeline = $command.Parent
                    if ($pipeline -isnot
                        [System.Management.Automation.Language.PipelineAst]) {
                        return $false
                    }
                    $pipelineElements = @($pipeline.PipelineElements)
                    $commandIndex = -1
                    for ($pipelineIndex = 0;
                        $pipelineIndex -lt $pipelineElements.Count;
                        $pipelineIndex++) {
                        if ([object]::ReferenceEquals(
                                $pipelineElements[$pipelineIndex],
                                $command
                            )) {
                            $commandIndex = $pipelineIndex
                            break
                        }
                    }
                    if ($commandIndex -le 0) {
                        return $false
                    }
                    $inputState =
                        Get-PrivateMarkerScriptBlockValueState `
                            -Node $pipelineElements[$commandIndex - 1] `
                            -VariableStates $scriptBlockVariableStates `
                            -TaintedNames $taintedNames
                    if ($inputState -ne 'Safe') {
                        return $false
                    }
                }
            }
        }

        if ($commandName -iin @(
                'ForEach-Object',
                'Where-Object',
                'Invoke-Command',
                'Measure-Command'
            )) {
            $scriptBlockArguments = @(
                Get-PrivateMarkerScriptBlockArgumentNodes `
                    -Command $command `
                    -CommandName $commandName
            )
            foreach ($scriptBlockArgument in $scriptBlockArguments) {
                $argumentState =
                    Get-PrivateMarkerScriptBlockValueState `
                        -Node $scriptBlockArgument `
                        -VariableStates $scriptBlockVariableStates `
                        -TaintedNames $taintedNames
                if ($argumentState -ne 'Safe') {
                    return $false
                }
            }
        }

        if ($commandName -iin @(
                'Set-Item',
                'Set-Content',
                'New-Item'
            )) {
            $providerPathNode =
                Get-PrivateMarkerCommandArgumentNode `
                    -Command $command `
                    -ParameterNames @('Path', 'LiteralPath') `
                    -Position 0
            $providerPath =
                Resolve-PrivateMarkerStaticStringValueBeforeOffset `
                -Node $providerPathNode `
                    -VariableHistory $staticStringVariableHistory `
                    -MaximumOffset $command.Extent.StartOffset
            if (-not $providerPath.IsStatic) {
                # providerを静的に解決できないmutationは、filesystem由来を
                # source-orderで証明できる場合だけ許可する。
                if (-not (
                    Test-PrivateMarkerFileSystemPathValueBeforeOffset `
                        -Node $providerPathNode `
                        -VariableHistory $staticStringVariableHistory `
                        -MaximumOffset $command.Extent.StartOffset
                    )) {
                    return $false
                }
                continue
            }
            if ($providerPath.Value -match
                '^(?i:(?<provider>Alias|Function|Variable):)(?:(?:global|script|local|private):)?(?<name>.+)$') {
                $providerName = [string]$Matches['provider']
                $itemName = ConvertTo-PrivateMarkerNormalizedCommandName `
                    -Name ([string]$Matches['name'])

                # Function providerは任意bodyを注入でき、scope指定も含めて
                # static function定義解析の外へ出るため、raw前は一律拒否する。
                # Variable providerもstate tableの外からprocessBoundaryや
                # ScriptBlock由来を書換えられるため、同じく一律拒否する。
                if ($providerName -iin @('Function', 'Variable')) {
                    return $false
                }
                if ([string]::IsNullOrWhiteSpace($itemName) -or
                    $itemName -ieq 'Invoke-PrivateMarkerProcess') {
                    return $false
                }

                $providerValueNode =
                    Get-PrivateMarkerCommandArgumentNode `
                        -Command $command `
                        -ParameterNames @('Value') `
                        -Position 1
                $providerValue =
                    Resolve-PrivateMarkerStaticStringValueBeforeOffset `
                        -Node $providerValueNode `
                        -VariableHistory $staticStringVariableHistory `
                        -MaximumOffset $command.Extent.StartOffset
                if (-not $providerValue.IsStatic) {
                    # Alias targetを静的に確定できなければ、後続command解決を
                    # production helperと区別できない。
                    return $false
                }
                $aliasTarget =
                    ConvertTo-PrivateMarkerNormalizedCommandName `
                        -Name ([string]$providerValue.Value)
                if ([string]::IsNullOrWhiteSpace($aliasTarget)) {
                    return $false
                }
                $aliases[$itemName] = $aliasTarget
                continue
            }
        }

        if ($commandName -iin @('Set-Alias', 'New-Alias')) {
            $aliasArguments =
                Get-PrivateMarkerStaticCommandArguments -Command $command
            if (-not $aliasArguments.IsStatic -or
                $aliasArguments.Values.Count -ne 2) {
                return $false
            }
            $aliasName = ConvertTo-PrivateMarkerNormalizedCommandName `
                -Name $aliasArguments.Values[0]
            $aliasTarget = ConvertTo-PrivateMarkerNormalizedCommandName `
                -Name $aliasArguments.Values[1]
            if ([string]::IsNullOrWhiteSpace($aliasName) -or
                [string]::IsNullOrWhiteSpace($aliasTarget)) {
                return $false
            }
            # target名そのものをaliasで上書きすると、後続raw assignmentの
            # command textが正しくてもproduction helperへ到達しない。
            if ($aliasName -ieq 'Invoke-PrivateMarkerProcess') {
                return $false
            }
            $aliases[$aliasName] = $aliasTarget
            continue
        }

        if ($commandName -ieq 'Get-Command') {
            $getCommandArguments =
                Get-PrivateMarkerStaticCommandArguments -Command $command
            if (-not $getCommandArguments.IsStatic -or
                $getCommandArguments.Values.Count -ne 1) {
                return $false
            }
            $referencedName =
                ConvertTo-PrivateMarkerNormalizedCommandName `
                    -Name $getCommandArguments.Values[0]
            if ($taintedNames -icontains $referencedName -or
                (Test-PrivateMarkerAliasTargetsTaintedCommand `
                    -Name $referencedName `
                    -Aliases $aliases `
                    -TaintedNames $taintedNames)) {
                return $false
            }
        }
        if ($commandName -ieq 'Invoke-Expression') {
            return $false
        }
    }
    return $true
}

function Assert-FirstTopLevelProcessInvocationValidatorRegressions {
    $binaryAssignment = @'
$binaryPipeResult = Invoke-PrivateMarkerProcess -StandardInputBytes $binaryProbeBytes
'@
    $earlyFunction = @'
function Invoke-Early { Invoke-PrivateMarkerProcess }
'@
    $cases = @(
        [pscustomobject]@{
            Name = 'direct-before'
            Expected = $false
            Source = "Invoke-PrivateMarkerProcess`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'function-before'
            Expected = $true
            Source = "function Invoke-Deferred { Invoke-PrivateMarkerProcess }`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'uninvoked-scriptblock'
            Expected = $true
            Source = "`$unused = { Invoke-PrivateMarkerProcess }`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'nested-inner'
            Expected = $false
            Source = '$binaryPipeResult = Invoke-PrivateMarkerProcess -StandardInputBytes $binaryProbeBytes -Value $(Invoke-PrivateMarkerProcess)'
        },
        [pscustomobject]@{
            Name = 'invoked-scriptblock-member'
            Expected = $false
            Source = "({ Invoke-PrivateMarkerProcess }).Invoke()`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'invoked-scriptblock-return-as-is'
            Expected = $false
            Source = "({ Invoke-PrivateMarkerProcess }).InvokeReturnAsIs()`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'saved-scriptblock-invoke-before'
            Expected = $false
            Source = "`$saved = { Invoke-PrivateMarkerProcess }`n`$saved.Invoke()`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'saved-scriptblock-return-as-is-before'
            Expected = $false
            Source = "`$saved = { Invoke-PrivateMarkerProcess }`n`$saved.InvokeReturnAsIs()`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'saved-scriptblock-invoke-with-context-before'
            Expected = $false
            Source = "`$saved = { Invoke-PrivateMarkerProcess }`n`$saved.InvokeWithContext(`$null, `$null, @())`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'saved-scriptblock-measure-command-sink-before'
            Expected = $false
            Source = "`$saved = { Invoke-PrivateMarkerProcess }`nMeasure-Command -Expression `$saved`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'saved-scriptblock-foreach-member-invoke-before'
            Expected = $false
            Source = "`$saved = { Invoke-PrivateMarkerProcess }`n`$saved | ForEach-Object -MemberName Invoke`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'saved-scriptblock-foreach-sink-before'
            Expected = $false
            Source = "`$saved = { Invoke-PrivateMarkerProcess }`n1 | ForEach-Object `$saved`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'saved-scriptblock-where-sink-before'
            Expected = $false
            Source = "`$saved = { Invoke-PrivateMarkerProcess }`n1 | Where-Object `$saved`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'saved-scriptblock-invoke-command-sink-before'
            Expected = $false
            Source = "`$saved = { Invoke-PrivateMarkerProcess }`nInvoke-Command -ScriptBlock `$saved`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'saved-scriptblock-foreach-alias-sink-before'
            Expected = $false
            Source = "`$saved = { Invoke-PrivateMarkerProcess }`n1 | % `$saved`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'saved-scriptblock-where-alias-sink-before'
            Expected = $false
            Source = "`$saved = { Invoke-PrivateMarkerProcess }`n1 | ? `$saved`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'saved-scriptblock-invoke-command-alias-sink-before'
            Expected = $false
            Source = "`$saved = { Invoke-PrivateMarkerProcess }`nicm -ScriptBlock `$saved`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'copied-scriptblock-invoke-before'
            Expected = $false
            Source = "`$saved = { Invoke-PrivateMarkerProcess }`n`$copied = `$saved`n`$copied.Invoke()`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'created-scriptblock-invoke-before'
            Expected = $false
            Source = "[scriptblock]::Create('Invoke-PrivateMarkerProcess').Invoke()`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'assigned-created-scriptblock-invoke-before'
            Expected = $false
            Source = "`$created = [scriptblock]::Create('Invoke-PrivateMarkerProcess')`n`$created.Invoke()`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'unknown-scriptblock-origin-before'
            Expected = $false
            Source = "`$saved.Invoke()`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'safe-saved-scriptblock-invoke-before'
            Expected = $true
            Source = "`$saved = { Get-Date }`n`$saved.Invoke()`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'safe-saved-scriptblock-invoke-with-context-before'
            Expected = $true
            Source = "`$saved = { Get-Date }`n`$saved.InvokeWithContext(`$null, `$null, @())`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'safe-saved-scriptblock-measure-command-before'
            Expected = $true
            Source = "`$saved = { Get-Date }`nMeasure-Command -Expression `$saved`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'safe-saved-scriptblock-foreach-member-invoke-before'
            Expected = $true
            Source = "`$saved = { Get-Date }`n`$saved | ForEach-Object -MemberName Invoke`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'safe-saved-scriptblock-foreach-sink-before'
            Expected = $true
            Source = "`$saved = { Get-Date }`n1 | ForEach-Object `$saved`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'set-variable-tainted-invoke-before'
            Expected = $false
            Source = "`$tainted = { Invoke-PrivateMarkerProcess }`nSet-Variable -Name x -Value `$tainted`n`$x.Invoke()`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'set-variable-composite-receiver-before'
            Expected = $false
            Source = "`$tainted = { Invoke-PrivateMarkerProcess }`n`$safe = { Get-Date }`nSet-Variable -Name x -Value `$tainted`n(Write-Output (Get-Variable x -ValueOnly) -Verbose:`$safe).Invoke()`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'uninvoked-created-scriptblock'
            Expected = $true
            Source = "`$saved = [scriptblock]::Create('Invoke-PrivateMarkerProcess')`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'alias-wrapper-before'
            Expected = $false
            Source = "$earlyFunction`nSet-Alias EarlyAlias Invoke-Early`nEarlyAlias`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'scope-qualified-wrapper-before'
            Expected = $false
            Source = "$earlyFunction`nglobal:Invoke-Early`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'get-command-scriptblock-invoke-before'
            Expected = $false
            Source = "$earlyFunction`n(Get-Command Invoke-Early).ScriptBlock.Invoke()`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'dynamic-alias-target-before'
            Expected = $false
            Source = "`$earlyTarget = 'Invoke-Early'`nSet-Alias EarlyAlias `$earlyTarget`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'dynamic-get-command-before'
            Expected = $false
            Source = "`$earlyTarget = 'Invoke-Early'`n(Get-Command `$earlyTarget).ScriptBlock.Invoke()`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'dynamic-call-operator-before'
            Expected = $false
            Source = "`$earlyTarget = 'Invoke-Early'`n& `$earlyTarget`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'target-function-shadow-before'
            Expected = $false
            Source = "function Invoke-PrivateMarkerProcess { 'shadow' }`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'target-alias-shadow-before'
            Expected = $false
            Source = "$earlyFunction`nSet-Alias Invoke-PrivateMarkerProcess Invoke-Early`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'target-alias-provider-shadow-before'
            Expected = $false
            Source = "Set-Item Alias:Invoke-PrivateMarkerProcess Get-Date`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'dynamic-target-alias-provider-shadow-before'
            Expected = $false
            Source = "Set-Item -Path ('Alias:' + 'Invoke-PrivateMarkerProcess') -Value Get-Date`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'target-alias-provider-assignment-before'
            Expected = $false
            Source = "`${alias:Invoke-PrivateMarkerProcess} = 'Get-Date'`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'target-alias-provider-assignment-wrapper-before'
            Expected = $false
            Source = @"
function Set-TargetAliasShadow {
    `${alias:Invoke-PrivateMarkerProcess} = 'Get-Date'
}
Set-TargetAliasShadow
$binaryAssignment
"@
        },
        [pscustomobject]@{
            Name = 'target-function-provider-shadow-before'
            Expected = $false
            Source = "Set-Item Function:Invoke-PrivateMarkerProcess { Get-Date }`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'rename-target-alias-provider-before'
            Expected = $false
            Source = "Set-Alias EarlyAlias Get-Date`nRename-Item Alias:EarlyAlias Invoke-PrivateMarkerProcess`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'copy-target-function-provider-before'
            Expected = $false
            Source = "function EarlyFunction { Get-Date }`nCopy-Item Function:EarlyFunction Function:Invoke-PrivateMarkerProcess`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'move-target-alias-provider-before'
            Expected = $false
            Source = "Set-Alias EarlyAlias Get-Date`nMove-Item Alias:EarlyAlias Alias:Invoke-PrivateMarkerProcess`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'set-content-alias-wrapper-before'
            Expected = $false
            Source = "$earlyFunction`nSet-Content Alias:EarlyAlias Invoke-Early`nEarlyAlias`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'dynamic-new-item-function-shadow-before'
            Expected = $false
            Source = "`$providerPath = 'Function:Invoke-PrivateMarkerProcess'`nNew-Item -Path `$providerPath -ItemType Directory -Value { 'shadow' }`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'dynamic-provider-path-later-overwrite-before'
            Expected = $false
            Source = "`$providerPath = 'Function:Invoke-PrivateMarkerProcess'`nNew-Item -Path `$providerPath -ItemType Directory -Value { 'shadow' }`n`$providerPath = './ordinary-directory'`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'ordinary-path-before-later-provider-string'
            Expected = $true
            Source = "`$providerPath = './ordinary-directory'`nNew-Item -Path `$providerPath -ItemType Directory`n`$providerPath = 'Function:Invoke-PrivateMarkerProcess'`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'ordinary-new-item-path-before'
            Expected = $true
            Source = "`$ordinaryPath = './synthetic-directory'`nNew-Item -Path `$ordinaryPath -ItemType Directory`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'set-variable-process-boundary-shadow-before'
            Expected = $false
            Source = "Set-Variable processBoundary ./synthetic.ps1`n. `$processBoundary`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'variable-provider-process-boundary-shadow-before'
            Expected = $false
            Source = @"
`$processBoundary = Join-Path `$root 'scripts/private-marker-process.ps1'
Set-Item -Path Variable:processBoundary -Value './synthetic.ps1'
. `$processBoundary
$binaryAssignment
"@
        },
        [pscustomobject]@{
            Name = 'scoped-process-boundary-assignment-shadow-before'
            Expected = $false
            Source = "`$script:processBoundary = './synthetic.ps1'`n. `$processBoundary`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'scope-wrapper-process-boundary-shadow-before'
            Expected = $false
            Source = @"
function Set-ProcessBoundaryShadow {
    Set-Variable processBoundary ./synthetic.ps1 -Scope 1
}
Set-ProcessBoundaryShadow
. `$processBoundary
$binaryAssignment
"@
        },
        [pscustomobject]@{
            Name = 'builtin-get-command-alias-before'
            Expected = $false
            Source = "$earlyFunction`n(gcm Invoke-Early).ScriptBlock.Invoke()`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'module-qualified-get-command-before'
            Expected = $false
            Source = "$earlyFunction`n(Microsoft.PowerShell.Core\Get-Command Invoke-Early).ScriptBlock.Invoke()`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'function-provider-invoke-before'
            Expected = $false
            Source = "$earlyFunction`n`${function:Invoke-Early}.Invoke()`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'invoke-command-function-provider-before'
            Expected = $false
            Source = "$earlyFunction`nInvoke-Command -ScriptBlock `${function:Invoke-Early}`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'class-constructor-before'
            Expected = $false
            Source = @"
class EarlyClass {
    EarlyClass() { Invoke-PrivateMarkerProcess }
}
[EarlyClass]::new()
$binaryAssignment
"@
        },
        [pscustomobject]@{
            Name = 'class-member-before'
            Expected = $false
            Source = @"
class EarlyClass {
    [void] Invoke() { Invoke-PrivateMarkerProcess }
}
[EarlyClass]::new().Invoke()
$binaryAssignment
"@
        },
        [pscustomobject]@{
            Name = 'inherited-class-member-before'
            Expected = $false
            Source = @"
class EarlyBaseClass {
    [void] Run() { Invoke-PrivateMarkerProcess }
}
class EarlyDerivedClass : EarlyBaseClass {}
[EarlyDerivedClass]::new().Run()
$binaryAssignment
"@
        },
        [pscustomobject]@{
            Name = 'class-conversion-constructor-before'
            Expected = $false
            Source = @"
class EarlyClass {
    EarlyClass() { Invoke-PrivateMarkerProcess }
}
`$instance = @{} -as [EarlyClass]
$binaryAssignment
"@
        },
        [pscustomobject]@{
            Name = 'class-static-instance-member-before'
            Expected = $false
            Source = @"
class EarlyClass {
    static [EarlyClass] `$Instance = [EarlyClass]::new()
    EarlyClass() { Invoke-PrivateMarkerProcess }
    [void] Run() { Get-Date }
}
`$instance = [EarlyClass]::Instance
`$instance.Run()
$binaryAssignment
"@
        },
        [pscustomobject]@{
            Name = 'class-static-instance-wrapper-argument-before'
            Expected = $false
            Source = @"
class EarlyClass {
    static [EarlyClass] `$Instance = [EarlyClass]::new()
    EarlyClass() { Invoke-PrivateMarkerProcess }
    [void] Run() { Get-Date }
}
function Invoke-InstanceWrapper {
    param(`$Value)
    `$Value.Run()
}
`$instance = [EarlyClass]::Instance
Invoke-InstanceWrapper `$instance
$binaryAssignment
"@
        },
        [pscustomobject]@{
            Name = 'invoke-expression-before'
            Expected = $false
            Source = "Invoke-Expression 'Invoke-PrivateMarkerProcess'`n$binaryAssignment"
        },
        [pscustomobject]@{
            Name = 'foreach-function-provider-before'
            Expected = $false
            Source = "$earlyFunction`n1 | ForEach-Object `${function:Invoke-Early}`n$binaryAssignment"
        }
    )
    foreach ($case in $cases) {
        $actual = Test-FirstTopLevelProcessInvocationIsBinarySource `
            -Source $case.Source
        if ($actual -ne $case.Expected) {
            Add-Failure "First process invocation validator regression failed: $($case.Name)."
        }
    }
}

function Assert-FirstTopLevelProcessInvocationIsBinary {
    param([string]$RelativePath)

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath (first process invocation contract)"
        return
    }
    $source = [System.IO.File]::ReadAllText($filePath)
    if (-not (Test-FirstTopLevelProcessInvocationIsBinarySource `
        -Source $source)) {
        Add-Failure "$RelativePath must use the exact binary fixture for its first executable bounded-process invocation."
    }
}

function Assert-FinalScanDeadlineContract {
    param(
        [string]$RelativePath
    )

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath (final scan deadline contract)"
        return
    }

    # finding payload と clean result のどちらも、emit直前に同じscan-wide時計を
    # 再確認する。途中のdeadline callが存在するだけでは最終窓を閉じられない。
    $source = Get-Content -LiteralPath $filePath -Raw
    $findingWritePattern = (
        '(?m)^[ \t]*\$standardOutput\.Write\(')
    $guardedFindingWritePattern = (
        '(?m)^[ \t]*Assert-PrivateMarkerScanDeadline[ \t]*\r?\n' +
        '[ \t]*\$standardOutput\.Write\(')
    $outputLimitWritePattern = (
        '(?m)^[ \t]*Write-Host[ \t]+' +
        '''Private marker scan aborted: scan-diagnostic-output-limit''' +
        '[ \t]*$')
    $guardedOutputLimitWritePattern = (
        '(?m)^[ \t]*Assert-PrivateMarkerScanDeadline[ \t]*\r?\n' +
        '[ \t]*Write-Host[ \t]+' +
        '''Private marker scan aborted: scan-diagnostic-output-limit''' +
        '[ \t]*$')
    $successEmitPattern = (
        '(?m)^[ \t]*Assert-PrivateMarkerScanDeadline[ \t]*\r?\n' +
        '[ \t]*Write-Host[ \t]+' +
        '"Private marker scan passed \(scan target: \$scanMode\)\."[ \t]*$')
    $findingWriteCount = [regex]::Matches(
        $source,
        $findingWritePattern
    ).Count
    $guardedFindingWriteCount = [regex]::Matches(
        $source,
        $guardedFindingWritePattern
    ).Count
    $openStandardOutputCount = [regex]::Matches(
        $source,
        '\[Console\]::OpenStandardOutput\(\)'
    ).Count
    if ($findingWriteCount -ne 1 -or
        $guardedFindingWriteCount -ne $findingWriteCount -or
        $openStandardOutputCount -ne 1) {
        Add-Failure "$RelativePath must recheck the scan-wide deadline immediately before writing finding stdout."
    }
    $outputLimitWriteCount = [regex]::Matches(
        $source,
        $outputLimitWritePattern
    ).Count
    $guardedOutputLimitWriteCount = [regex]::Matches(
        $source,
        $guardedOutputLimitWritePattern
    ).Count
    $writeHostCount = [regex]::Matches(
        $source,
        '(?m)^[ \t]*Write-Host\b'
    ).Count
    if ($outputLimitWriteCount -ne 2 -or
        $guardedOutputLimitWriteCount -ne $outputLimitWriteCount -or
        $writeHostCount -ne 3) {
        Add-Failure "$RelativePath must guard every bounded diagnostic output with an immediate scan-wide deadline check."
    }
    if ($source -notmatch $successEmitPattern) {
        Add-Failure "$RelativePath must recheck the scan-wide deadline immediately before success output."
    }
}

function Test-WorkflowEnvelopeSource {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string[]]$ExpectedJobNames
    )

    # workflow全体の権限境界をjob sliceより先に固定する。trigger追加、
    # top-level key追加、job増殖、job-level permissions overrideを拒否する。
    $lines = @($Source -split '\r?\n')
    $topLevelEntries = @(
        $lines | ForEach-Object {
            $entryMatch = [regex]::Match(
                $_,
                '^(?<name>[A-Za-z0-9_-]+):(?:[ \t].*)?$'
            )
            if ($entryMatch.Success) {
                $entryMatch.Groups['name'].Value
            }
        }
    )
    $expectedTopLevelEntries = @('jobs', 'name', 'on', 'permissions')
    if ($topLevelEntries.Count -ne $expectedTopLevelEntries.Count -or
        (@($topLevelEntries | Sort-Object) -join "`n") -cne
            ($expectedTopLevelEntries -join "`n") -or
        @($lines | Where-Object {
            $_ -ceq 'name: Validate'
        }).Count -ne 1) {
        return $false
    }
    $expectedTopLevelLines = @(
        'name: Validate',
        'on:',
        'permissions:',
        'jobs:'
    )
    $unconsumedTopLevelLines = @(
        $lines | Where-Object {
            $_ -notmatch '^\s*(?:#.*)?$' -and
            $_ -match '^\S' -and
            $expectedTopLevelLines -cnotcontains $_.TrimEnd()
        }
    )
    if ($unconsumedTopLevelLines.Count -ne 0) {
        return $false
    }

    $onStart = [Array]::IndexOf($lines, 'on:')
    $permissionsStart = [Array]::IndexOf($lines, 'permissions:')
    $jobsStart = [Array]::IndexOf($lines, 'jobs:')
    if ($onStart -lt 0 -or
        $permissionsStart -le $onStart -or
        $jobsStart -le $permissionsStart) {
        return $false
    }

    $onActiveLines = @(
        $lines[$onStart..($permissionsStart - 1)] |
            Where-Object { $_ -notmatch '^\s*(?:#.*)?$' } |
            ForEach-Object { $_.TrimEnd() }
    )
    $expectedOnLines = @(
        'on:',
        '  pull_request:',
        '  push:',
        '    branches:',
        '      - main'
    )
    if ($onActiveLines.Count -ne $expectedOnLines.Count -or
        ($onActiveLines -join "`n") -cne ($expectedOnLines -join "`n")) {
        return $false
    }

    $permissionActiveLines = @(
        $lines[$permissionsStart..($jobsStart - 1)] |
            Where-Object { $_ -notmatch '^\s*(?:#.*)?$' } |
            ForEach-Object { $_.TrimEnd() }
    )
    $expectedPermissionLines = @(
        'permissions:',
        '  contents: read'
    )
    if ($permissionActiveLines.Count -ne $expectedPermissionLines.Count -or
        ($permissionActiveLines -join "`n") -cne
            ($expectedPermissionLines -join "`n")) {
        return $false
    }

    $jobLines = @($lines[($jobsStart + 1)..($lines.Count - 1)])
    $canonicalJobActiveLinePattern =
        '^(?:' +
        '  [A-Za-z0-9_-]+:[ \t]*|' +
        '    [A-Za-z0-9_-]+:(?:[ \t].*)?|' +
        '      -[ \t]+[A-Za-z0-9_-]+:(?:[ \t].*)?|' +
        '        [A-Za-z0-9_-]+:(?:[ \t].*)?' +
        ')$'
    $unconsumedJobLines = @(
        $jobLines | Where-Object {
            $_ -notmatch '^\s*(?:#.*)?$' -and
            $_ -notmatch $canonicalJobActiveLinePattern
        }
    )
    if ($unconsumedJobLines.Count -ne 0) {
        return $false
    }
    if (@($jobLines | Where-Object {
        $_ -match '^    permissions:[ \t]*$'
    }).Count -ne 0) {
        return $false
    }
    $jobIds = @(
        $jobLines | ForEach-Object {
            $jobMatch = [regex]::Match(
                $_,
                '^  (?<name>[A-Za-z0-9_-]+):[ \t]*$'
            )
            if ($jobMatch.Success) {
                $jobMatch.Groups['name'].Value
            }
        }
    )
    return $jobIds.Count -eq $ExpectedJobNames.Count -and
        (@($jobIds | Sort-Object) -join "`n") -ceq
            (@($ExpectedJobNames | Sort-Object) -join "`n")
}

function Assert-WorkflowEnvelopeMutationRegressions {
    $baseWorkflow = @'
name: Validate

on:
  pull_request:
  push:
    branches:
      - main

permissions:
  contents: read

jobs:
  validate:
    name: Windows
  validate-ubuntu:
    name: Ubuntu
'@
    $expectedJobs = @('validate', 'validate-ubuntu')
    if (-not (Test-WorkflowEnvelopeSource `
        -Source $baseWorkflow `
        -ExpectedJobNames $expectedJobs)) {
        Add-Failure 'Workflow envelope validator rejected its clean synthetic control.'
        return
    }

    $mutations = @(
        [pscustomobject]@{
            Name = 'pull-request-target'
            Source = $baseWorkflow.Replace(
                '  pull_request:',
                '  pull_request_target:'
            )
        },
        [pscustomobject]@{
            Name = 'extra-job'
            Source = $baseWorkflow + "`n  unexpected:`n    name: Extra"
        },
        [pscustomobject]@{
            Name = 'duplicate-job'
            Source = $baseWorkflow + "`n  validate:`n    name: Duplicate"
        },
        [pscustomobject]@{
            Name = 'job-permission-override'
            Source = $baseWorkflow.Replace(
                '    name: Windows',
                "    permissions:`n      contents: write`n    name: Windows"
            )
        },
        [pscustomobject]@{
            Name = 'extra-top-level-key'
            Source = "concurrency: validation`n$baseWorkflow"
        },
        [pscustomobject]@{
            Name = 'quoted-extra-job'
            Source = $baseWorkflow +
                "`n  `"unexpected`":`n    name: Extra"
        },
        [pscustomobject]@{
            Name = 'flow-extra-job'
            Source = $baseWorkflow +
                "`n  unexpected: { name: Extra }"
        },
        [pscustomobject]@{
            Name = 'quoted-top-level-key'
            Source = "`"concurrency`": validation`n$baseWorkflow"
        },
        [pscustomobject]@{
            Name = 'unconsumed-active-indent'
            Source = $baseWorkflow +
                "`n   unexpected: value"
        }
    )
    foreach ($mutation in $mutations) {
        if (Test-WorkflowEnvelopeSource `
            -Source $mutation.Source `
            -ExpectedJobNames $expectedJobs) {
            Add-Failure "Workflow envelope mutation escaped validation: $($mutation.Name)."
        }
    }
}

function Assert-WorkflowEnvelope {
    param(
        [string]$RelativePath,
        [string[]]$ExpectedJobNames
    )

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing workflow file: $RelativePath"
        return
    }
    try {
        $source = [System.IO.File]::ReadAllText(
            $filePath,
            (New-Object System.Text.UTF8Encoding($false, $true))
        )
    }
    catch {
        Add-Failure "Workflow file '$RelativePath' must be valid UTF-8."
        return
    }
    if (-not (Test-WorkflowEnvelopeSource `
        -Source $source `
        -ExpectedJobNames $ExpectedJobNames)) {
        Add-Failure "Workflow '$RelativePath' must contain only exact Validate triggers, contents: read permission, and expected job IDs."
    }
}

function Get-WorkflowJobLines {
    param(
        [string]$RelativePath,
        [string]$JobName
    )

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing workflow file: $RelativePath"
        return @()
    }

    # workflowはUTF-8/LFでBOMを持たない。Windows PowerShell 5.1 の
    # locale既定decodeでは日本語comment末尾と次行が結合し得るため明示decodeする。
    try {
        $workflowSource = [System.IO.File]::ReadAllText(
            $filePath,
            (New-Object System.Text.UTF8Encoding($false, $true))
        )
    }
    catch {
        Add-Failure "Workflow file '$RelativePath' must be valid UTF-8."
        return @()
    }
    $lines = @($workflowSource -split '\r?\n')
    $jobStart = -1
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $jobMatch = [regex]::Match(
            $lines[$index],
            '^  (?<name>[A-Za-z0-9_-]+):[ \t]*$'
        )
        if ($jobMatch.Success -and
            $jobMatch.Groups['name'].Value -ceq $JobName) {
            $jobStart = $index
            break
        }
    }
    if ($jobStart -lt 0) {
        Add-Failure "Workflow job '$JobName' is missing."
        return @()
    }

    $jobEnd = $lines.Count
    for ($index = $jobStart + 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^  [A-Za-z0-9_-]+:[ \t]*$') {
            $jobEnd = $index
            break
        }
    }
    return @($lines[$jobStart..($jobEnd - 1)])
}

function Get-WorkflowSteps {
    param(
        [string[]]$Lines,
        [string]$JobName
    )

    $stepStartCount = @(
        $Lines | Where-Object { $_ -match '^      -[ \t]+' }
    ).Count
    $namedStepCount = @(
        $Lines | Where-Object { $_ -match '^      -[ \t]+name:[ \t]+' }
    ).Count
    if ($stepStartCount -ne $namedStepCount) {
        Add-Failure "Workflow job '$JobName' must give every active step an explicit name."
    }

    $steps = New-Object System.Collections.Generic.List[object]
    $currentStep = $null

    foreach ($line in $Lines) {
        $nameMatch = [regex]::Match($line, '^      -[ \t]+name:[ \t]*(?<value>[^#\r\n]+?)[ \t]*$')
        if ($nameMatch.Success) {
            if ($null -ne $currentStep) {
                $steps.Add($currentStep) | Out-Null
            }
            $currentStep = [pscustomobject]@{
                Name = $nameMatch.Groups['value'].Value.Trim("'`"")
                Shell = ''
                Run = ''
                Uses = ''
                ShellCount = 0
                RunCount = 0
                UsesCount = 0
            }
            continue
        }

        if ($null -eq $currentStep) {
            continue
        }

        $shellMatch = [regex]::Match($line, '^        shell:[ \t]*(?<value>[^#\r\n]+?)[ \t]*$')
        if ($shellMatch.Success) {
            $currentStep.Shell = $shellMatch.Groups['value'].Value.Trim("'`"")
            $currentStep.ShellCount++
            continue
        }

        $runMatch = [regex]::Match($line, '^        run:[ \t]*(?<value>[^#\r\n]+?)[ \t]*$')
        if ($runMatch.Success) {
            $currentStep.Run = $runMatch.Groups['value'].Value.Trim("'`"")
            $currentStep.RunCount++
            continue
        }

        $usesMatch = [regex]::Match($line, '^        uses:[ \t]*(?<value>[^#\r\n]+?)[ \t]*(?:#.*)?$')
        if ($usesMatch.Success) {
            $currentStep.Uses = $usesMatch.Groups['value'].Value.Trim("'`"")
            $currentStep.UsesCount++
        }
    }

    if ($null -ne $currentStep) {
        $steps.Add($currentStep) | Out-Null
    }

    return $steps.ToArray()
}

function Assert-WorkflowJobValue {
    param(
        [string[]]$Lines,
        [string]$JobName,
        [string]$Key,
        [string]$ExpectedValue
    )

    $pattern = (
        '^    ' +
        [regex]::Escape($Key) +
        ':[ \t]*' +
        [regex]::Escape($ExpectedValue) +
        '[ \t]*(?:#.*)?$')
    # `$Matches` は -match が更新するautomatic変数なので、結果collectionへ
    # 同名（PowerShellはcase-insensitive）を使わずPS5.1/PS7差を避ける。
    $keyPattern = '^    ' + [regex]::Escape($Key) + ':[ \t]*'
    $keyLines = @($Lines | Where-Object { $_ -match $keyPattern })
    $matchingLines = @($keyLines | Where-Object { $_ -match $pattern })
    if ($keyLines.Count -ne 1 -or $matchingLines.Count -ne 1) {
        Add-Failure "Workflow job '$JobName' must declare exactly one '${Key}: $ExpectedValue' value (total keys $($keyLines.Count), expected values $($matchingLines.Count))."
    }
}

function Assert-WorkflowStepCount {
    param(
        [object[]]$Steps,
        [string]$JobName,
        [int]$ExpectedCount
    )

    if ($Steps.Count -ne $ExpectedCount) {
        Add-Failure "Workflow job '$JobName' must contain exactly $ExpectedCount named steps (found $($Steps.Count))."
    }
}

function Assert-WorkflowJobShape {
    param(
        [string[]]$Lines,
        [string]$JobName,
        [int]$ExpectedStepCount,
        [int]$ExpectedShellCount,
        [int]$ExpectedRunCount
    )

    # expected keyを残したまま `if: false`、continue-on-error、別action等を
    # 足してvalidationを無効化できないよう、indent別の全active entryも数える。
    $jobEntryCount = @(
        $Lines | Where-Object { $_ -match '^    (?![ #\r\n]).+$' }
    ).Count
    $nameKeyCount = @(
        $Lines | Where-Object { $_ -match '^    name:[ \t]*' }
    ).Count
    $stepsKeyCount = @(
        $Lines | Where-Object { $_ -match '^    steps:[ \t]*' }
    ).Count
    $stepItemCount = @(
        $Lines | Where-Object { $_ -match '^      -[ \t]+' }
    ).Count
    $stepPropertyCount = @(
        $Lines | Where-Object { $_ -match '^        (?![ #\r\n]).+$' }
    ).Count
    $shellKeyCount = @(
        $Lines | Where-Object { $_ -match '^        shell:[ \t]*' }
    ).Count
    $runKeyCount = @(
        $Lines | Where-Object { $_ -match '^        run:[ \t]*' }
    ).Count
    $usesKeyCount = @(
        $Lines | Where-Object { $_ -match '^        uses:[ \t]*' }
    ).Count
    $expectedStepPropertyCount =
        1 + $ExpectedShellCount + $ExpectedRunCount

    if ($jobEntryCount -ne 4 -or
        $nameKeyCount -ne 1 -or
        $stepsKeyCount -ne 1) {
        Add-Failure "Workflow job '$JobName' must contain only one name/runs-on/timeout-minutes/steps mapping."
    }
    if ($stepItemCount -ne $ExpectedStepCount) {
        Add-Failure "Workflow job '$JobName' must contain exactly $ExpectedStepCount step items (found $stepItemCount)."
    }
    if ($stepPropertyCount -ne $expectedStepPropertyCount -or
        $shellKeyCount -ne $ExpectedShellCount -or
        $runKeyCount -ne $ExpectedRunCount -or
        $usesKeyCount -ne 1) {
        Add-Failure "Workflow job '$JobName' contains an unexpected, missing, or duplicate step-level key."
    }
}

function Assert-WorkflowStep {
    param(
        [object[]]$Steps,
        [string]$JobName,
        [string]$Name,
        [string]$Shell,
        [string]$Run
    )

    $matches = @($Steps | Where-Object { $_.Name -ceq $Name })
    if ($matches.Count -ne 1) {
        Add-Failure "Workflow job '$JobName' must contain exactly one active step named '$Name' (found $($matches.Count))."
        return
    }

    $step = $matches[0]
    if ($step.ShellCount -ne 1 -or
        $step.RunCount -ne 1 -or
        $step.UsesCount -ne 0) {
        Add-Failure "Workflow job '$JobName' step '$Name' must contain exactly one shell/run and no uses key."
    }
    if (-not $step.Shell.Equals($Shell, [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-Failure "Workflow job '$JobName' step '$Name' must use shell '$Shell' (found '$($step.Shell)')."
    }
    if ($step.Run -cne $Run) {
        Add-Failure "Workflow job '$JobName' step '$Name' must run '$Run' (found '$($step.Run)')."
    }
}

function Assert-WorkflowUsesStep {
    param(
        [object[]]$Steps,
        [string]$JobName,
        [string]$Name,
        [string]$Uses
    )

    $matches = @($Steps | Where-Object { $_.Name -ceq $Name })
    if ($matches.Count -ne 1) {
        Add-Failure "Workflow job '$JobName' must contain exactly one active step named '$Name' (found $($matches.Count))."
        return
    }

    $step = $matches[0]
    if ($step.UsesCount -ne 1 -or
        $step.ShellCount -ne 0 -or
        $step.RunCount -ne 0) {
        Add-Failure "Workflow job '$JobName' step '$Name' must contain exactly one uses key and no shell/run key."
    }
    if ($step.Uses -cne $Uses) {
        Add-Failure "Workflow job '$JobName' step '$Name' must use '$Uses' (found '$($step.Uses)')."
    }
}

function Test-SkillFrontmatter {
    $skillPath = Get-RepoFilePath -RelativePath 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf)) {
        return
    }

    $lines = Get-Content -LiteralPath $skillPath
    if ($lines.Count -lt 4 -or $lines[0] -ne '---') {
        Add-Failure 'SKILL.md must start with YAML frontmatter.'
        return
    }

    $closingIndex = -1
    for ($index = 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -eq '---') {
            $closingIndex = $index
            break
        }
    }

    if ($closingIndex -lt 0) {
        Add-Failure 'SKILL.md frontmatter must be closed with --- before content.'
        return
    }

    $frontmatter = $lines[1..($closingIndex - 1)] -join "`n"
    if ($frontmatter -notmatch '(?m)^name:\s*windows-github-auth-diagnosis\s*$') {
        Add-Failure 'SKILL.md frontmatter must declare name: windows-github-auth-diagnosis.'
    }
    if ($frontmatter -notmatch '(?m)^description:\s*\S') {
        Add-Failure 'SKILL.md frontmatter must include a non-empty description.'
    }
    if ($frontmatter.Length -gt 1024) {
        Add-Failure 'SKILL.md frontmatter must stay under 1024 characters.'
    }
}

$requiredFiles = @(
    '.editorconfig',
    '.gitattributes',
    '.gitignore',
    '.github/ISSUE_TEMPLATE/bug_report.yml',
    '.github/ISSUE_TEMPLATE/config.yml',
    '.github/pull_request_template.md',
    '.github/workflows/validate.yml',
    'CHANGELOG.md',
    'CODE_OF_CONDUCT.md',
    'CONTRIBUTING.md',
    'LICENSE',
    'README.md',
    'SECURITY.md',
    'SKILL.md',
    'examples/diagnosis-checklist.md',
    'examples/final-report-template.md',
    'examples/issue-safe-summary.md',
    'scripts/check-whitespace.ps1',
    'scripts/private-marker-process.ps1',
    'scripts/scan-private-markers.ps1',
    'scripts/test-scan-private-markers.ps1',
    'scripts/validate-oss-readiness.ps1'
)

foreach ($requiredFile in $requiredFiles) {
    Assert-FileExists -RelativePath $requiredFile
}

foreach ($japaneseCommentedScript in @(
    'scripts/private-marker-process.ps1',
    'scripts/scan-private-markers.ps1',
    'scripts/test-scan-private-markers.ps1',
    'scripts/validate-oss-readiness.ps1'
)) {
    Assert-FileHasUtf8Bom -RelativePath $japaneseCommentedScript
}

Assert-FileContains -RelativePath 'README.md' -Pattern '(?im)^##\s+Install' -Description 'installation instructions'
Assert-FileContains -RelativePath 'README.md' -Pattern '(?im)^##\s+Validation' -Description 'validation instructions'
Assert-FileContains -RelativePath 'README.md' -Pattern '(?im)^##\s+Contributing' -Description 'contribution guidance'
Assert-FileContains -RelativePath 'README.md' -Pattern '(?im)^##\s+Security' -Description 'security reporting guidance'
Assert-FileContains -RelativePath 'README.md' -Pattern 'CONTRIBUTING\.md' -Description 'link to CONTRIBUTING.md'
Assert-FileContains -RelativePath 'README.md' -Pattern 'SECURITY\.md' -Description 'link to SECURITY.md'
Assert-FileContains -RelativePath '.gitignore' -Pattern '\.private-markers\.local' -Description 'ignore local private marker files'
Assert-FileContains -RelativePath 'CONTRIBUTING.md' -Pattern '(?im)no token|never.*token|secret' -Description 'secret-safe contribution guidance'
Assert-FileContains -RelativePath 'SECURITY.md' -Pattern '(?im)do not.*public|private|security' -Description 'private vulnerability reporting guidance'
Assert-FileContains -RelativePath 'SECURITY.md' -Pattern '(?i)fail(?:s|ed)? closed' -Description 'fail-closed scanner boundary'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern 'private-marker-process\.ps1' -Description 'shared bounded process boundary in scanner'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern 'WINDOWS_GITHUB_AUTH_DIAGNOSIS_PRIVATE_MARKERS' -Description 'existing local marker environment contract'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern 'h8nc4y/windows-github-auth-diagnosis' -Description 'repository-only GitHub URL allowlist'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern 'bearer-token-header' -Description 'token-shaped bearer header rule'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern 'emailPlaceholderAllowlist' -Description 'documentation-safe email allowlist'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern "Stop-PrivateMarkerIntegrityFailure\s+-Reason\s+'git-probe'" -Description 'fixed exit-2 Git metadata boundary'
Assert-FileContains -RelativePath 'scripts/check-whitespace.ps1' -Pattern '4b825dc642cb6eb9a060e54bf8d69288fbee4904' -Description 'empty-tree whitespace contract'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern 'Assert-PrivateMarkerScanDeadline' -Description 'scan-wide deadline enforcement'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern '(?s)\[object\]\$ScanDeadlineMilliseconds\s*=\s*120000' -Description 'fixed-diagnostic scan-wide deadline input seam'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern "Stop-PrivateMarkerIntegrityFailure\s+-Reason\s+'scan-deadline'" -Description 'fixed exit-2 invalid scan deadline boundary'
Assert-FinalScanDeadlineContract -RelativePath 'scripts/scan-private-markers.ps1'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern 'maximumFindingOutputBytes' -Description 'actual UTF-8 finding output cap'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'private-marker-process\.ps1' -Description 'shared bounded process boundary in scanner self-test'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'PosixSignal.*IsSuccessfulResult' -Description 'POSIX errno cleanup regression coverage'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern '\[byte\[\]\]\$binaryProbeBytes\s*=\s*@\(0x00,\s*0x80,\s*0xFF\)' -Description 'exact binary standard-stream fixture'
Assert-FirstTopLevelProcessInvocationValidatorRegressions
Assert-FirstTopLevelProcessInvocationIsBinary `
    -RelativePath 'scripts/test-scan-private-markers.ps1'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern '\[ValidateSet\('''',\s*''assign'',\s*''resume'',\s*''resume-close'',\s*''close''\)\]\s*\[string\]\$ForceWindowsLaunchFailure' -Description 'Windows suspended-launch and Job-close failure seam'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern 'LastSyntheticFailureProcessId' -Description 'synthetic launch PID evidence'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern 'Contained child launch cleanup failed' -Description 'launch and cleanup failure aggregation'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'Expected \$launchFailureMode launch failure to remove its PID without resuming the suspended target' -Description 'assign/resume cleanup regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'close its Job before finite stream drain' -Description 'parent-first Job close regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'raw native Git transport fixture' -Description 'BOM-less native Git byte transport regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'forced native POSIX session gate to preserve one Unicode argument byte-exactly' -Description 'POSIX gate argument encoding regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'external POSIX setsid arguments to use the BusyBox-compatible operand form' -Description 'portable external setsid argument regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'sanitized Git child to receive only the fixed hermetic environment allowlist' -Description 'non-Git ambient environment isolation regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'ready handshake to establish a verified process group before stopping the child-held pipe' -Description 'POSIX pre-session race regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'scan-diagnostic-output-limit' -Description 'finding output amplification regression coverage'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'Expected invalid ancestor Git metadata to fail closed with fixed exit 2' -Description 'ancestor Git metadata fail-closed regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'Expected invalid ancestor Gitfile metadata to fail closed with fixed exit 2' -Description 'ancestor Gitfile fail-closed regression'

# job blockを先に切り出し、timeout/runs-on/checkout/stepを所有job内だけで
# 検証する。後続jobへ跨ぐregexによる誤合格を許さない。
$workflowPath = '.github/workflows/validate.yml'
$checkoutRevision = 'actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09'
$expectedWorkflowJobNames = @('validate', 'validate-ubuntu')
Assert-WorkflowEnvelopeMutationRegressions
Assert-WorkflowEnvelope `
    -RelativePath $workflowPath `
    -ExpectedJobNames $expectedWorkflowJobNames
$windowsJobName = 'validate'
$windowsJobLines = @(Get-WorkflowJobLines `
    -RelativePath $workflowPath `
    -JobName $windowsJobName)
$windowsSteps = @(Get-WorkflowSteps `
    -Lines $windowsJobLines `
    -JobName $windowsJobName)
Assert-WorkflowJobValue -Lines $windowsJobLines -JobName $windowsJobName `
    -Key 'runs-on' -ExpectedValue 'windows-latest'
Assert-WorkflowJobValue -Lines $windowsJobLines -JobName $windowsJobName `
    -Key 'timeout-minutes' -ExpectedValue '25'
Assert-WorkflowStepCount -Steps $windowsSteps -JobName $windowsJobName `
    -ExpectedCount 6
Assert-WorkflowJobShape -Lines $windowsJobLines -JobName $windowsJobName `
    -ExpectedStepCount 6 -ExpectedShellCount 5 -ExpectedRunCount 5
Assert-WorkflowUsesStep -Steps $windowsSteps -JobName $windowsJobName `
    -Name 'Check out repository' -Uses $checkoutRevision
Assert-WorkflowStep -Steps $windowsSteps -JobName $windowsJobName `
    -Name 'Validate OSS readiness' -Shell 'pwsh' `
    -Run './scripts/validate-oss-readiness.ps1'
Assert-WorkflowStep -Steps $windowsSteps -JobName $windowsJobName `
    -Name 'Test private marker scan (PowerShell 7)' -Shell 'pwsh' `
    -Run './scripts/test-scan-private-markers.ps1'
Assert-WorkflowStep -Steps $windowsSteps -JobName $windowsJobName `
    -Name 'Test private marker scan (Windows PowerShell 5.1)' `
    -Shell 'powershell' -Run '.\scripts\test-scan-private-markers.ps1'
Assert-WorkflowStep -Steps $windowsSteps -JobName $windowsJobName `
    -Name 'Scan for private markers' -Shell 'pwsh' `
    -Run './scripts/scan-private-markers.ps1'
Assert-WorkflowStep -Steps $windowsSteps -JobName $windowsJobName `
    -Name 'Check whitespace' -Shell 'pwsh' `
    -Run './scripts/check-whitespace.ps1'

$ubuntuJobName = 'validate-ubuntu'
$ubuntuJobLines = @(Get-WorkflowJobLines `
    -RelativePath $workflowPath `
    -JobName $ubuntuJobName)
$ubuntuSteps = @(Get-WorkflowSteps `
    -Lines $ubuntuJobLines `
    -JobName $ubuntuJobName)
Assert-WorkflowJobValue -Lines $ubuntuJobLines -JobName $ubuntuJobName `
    -Key 'runs-on' -ExpectedValue 'ubuntu-24.04'
Assert-WorkflowJobValue -Lines $ubuntuJobLines -JobName $ubuntuJobName `
    -Key 'timeout-minutes' -ExpectedValue '10'
Assert-WorkflowStepCount -Steps $ubuntuSteps -JobName $ubuntuJobName `
    -ExpectedCount 5
Assert-WorkflowJobShape -Lines $ubuntuJobLines -JobName $ubuntuJobName `
    -ExpectedStepCount 5 -ExpectedShellCount 4 -ExpectedRunCount 4
Assert-WorkflowUsesStep -Steps $ubuntuSteps -JobName $ubuntuJobName `
    -Name 'Check out repository' -Uses $checkoutRevision
Assert-WorkflowStep -Steps $ubuntuSteps -JobName $ubuntuJobName `
    -Name 'Validate OSS readiness on Ubuntu' -Shell 'pwsh' `
    -Run './scripts/validate-oss-readiness.ps1'
Assert-WorkflowStep -Steps $ubuntuSteps -JobName $ubuntuJobName `
    -Name 'Test private marker scan (PowerShell 7 on Ubuntu)' -Shell 'pwsh' `
    -Run './scripts/test-scan-private-markers.ps1'
Assert-WorkflowStep -Steps $ubuntuSteps -JobName $ubuntuJobName `
    -Name 'Scan for private markers on Ubuntu' -Shell 'pwsh' `
    -Run './scripts/scan-private-markers.ps1'
Assert-WorkflowStep -Steps $ubuntuSteps -JobName $ubuntuJobName `
    -Name 'Check whitespace on Ubuntu' -Shell 'pwsh' `
    -Run './scripts/check-whitespace.ps1'

Test-SkillFrontmatter

if ($failures.Count -gt 0) {
    Write-Host 'OSS readiness validation failed:'
    foreach ($failure in $failures) {
        Write-Host "- $failure"
    }
    exit 1
}

Write-Host "OSS readiness validation passed for $root"
exit 0

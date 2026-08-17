#Requires -Version 5.1
<#
    Static checks on the repository itself, run by the same Pester command as the unit tests.

    Every check exists because something once broke in the way it detects, so a check that finds
    nothing to inspect is written to fail rather than to pass quietly.
#>

BeforeDiscovery {
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $scriptFiles = @(
        @{ Name = 'Relabel-Files.ps1'; Isolation = 'EmbeddedWorker' }
        @{ Name = 'New-LabelTestSite.ps1'; Isolation = 'ChildProcessGate' }
    ) | ForEach-Object { $_.Path = Join-Path $repositoryRoot $_.Name; $_ }

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $hasWindowsPowerShell = Test-Path -LiteralPath $windowsPowerShell
    $hasAnalyzer = [bool](Get-Module -ListAvailable -Name PSScriptAnalyzer)
}

Describe 'Repository' {
    BeforeAll {
        $repositoryRoot = Split-Path -Parent $PSScriptRoot
        $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $scriptNames = @('Relabel-Files.ps1', 'New-LabelTestSite.ps1')
    }

    It 'parses both scripts under Windows PowerShell 5.1' -Skip:(-not $hasWindowsPowerShell) {
        # Windows PowerShell parses differently from PowerShell 7, and this utility must load in both.
        $command = @'
$total = 0
foreach ($name in @('{0}')) {{
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path '{1}' $name), [ref]$null, [ref]$errors)
    $total += @($errors).Count
}}
$total
'@ -f ($scriptNames -join "','"), $repositoryRoot
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $count = & $windowsPowerShell -NoProfile -NonInteractive -EncodedCommand $encoded
        "$count".Trim() | Should -BeExactly '0'
    }

    It 'has balanced code fences in the README' {
        $fences = @(Select-String -LiteralPath (Join-Path $repositoryRoot 'README.md') -Pattern '^```').Count
        $fences | Should -BeGreaterThan 0
        ($fences % 2) | Should -Be 0 -Because 'an unclosed fence swallows the rest of the document'
    }

    It 'passes PSScriptAnalyzer' -Skip:(-not $hasAnalyzer) {
        Import-Module PSScriptAnalyzer -ErrorAction Stop
        # Only the delivered scripts: the analyser does not model Pester's scoping and reports every
        # variable set in a BeforeAll block as unused.
        # Write-Host is the interface of an interactive tool, so its rule is not meaningful here.
        $findings = @($scriptNames | ForEach-Object {
                Invoke-ScriptAnalyzer -Path (Join-Path $repositoryRoot $_) -Severity Error, Warning `
                    -ExcludeRule PSAvoidUsingWriteHost, PSUseShouldProcessForStateChangingFunctions, PSAvoidUsingPositionalParameters
            })
        $report = ($findings | ForEach-Object { '{0} {1}:{2} {3}' -f $_.RuleName, $_.ScriptName, $_.Line, $_.Message }) -join "`n"
        $findings.Count | Should -Be 0 -Because "the analyser reported:`n$report"
    }
}

Describe 'Script <Name>' -ForEach $scriptFiles {
    BeforeAll {
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
        $parseErrors = @($errors)

        $functions = @($ast.FindAll({
                    param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
                }, $true))
        $commands = @($ast.FindAll({
                    param($node) $node -is [System.Management.Automation.Language.CommandAst]
                }, $true))
        $commandNames = @($commands | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
    }

    It 'parses without error' {
        $detail = ($parseErrors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join "`n"
        $parseErrors.Count | Should -Be 0 -Because "the parser reported:`n$detail"
    }

    It 'has embedded worker scripts that parse on their own' {
        # These run in child processes, so a syntax error in one stays invisible until that feature is used.
        # Found by content rather than by variable name, so renaming the variable cannot hide one.
        $workers = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                    $node.StringConstantType -like '*HereString' -and
                    $node.Value -match 'RESULT:' -and $node.Value -match '(?m)^\s*param\('
                }, $true))
        foreach ($worker in $workers) {
            $workerErrors = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($worker.Value, [ref]$null, [ref]$workerErrors)
            @($workerErrors).Count |
                Should -Be 0 -Because "the worker starting on line $($worker.Extent.StartLineNumber) must parse"
        }
    }

    It 'keeps Az and Microsoft Graph out of any session that uses PnP' {
        # Az and PnP ship incompatible Microsoft.Extensions assemblies and whichever loads first wins
        # for the life of the process, so mixing them breaks PnP sign-in with a missing get_Services.
        # Case-sensitive, or 'Azure' in this repository's own function names would look like the Az module.
        $offenders = @($commands | Where-Object {
                $name = $_.GetCommandName()
                $name -and ($name -cmatch '^\w+-(Az|Mg)[A-Z]' -or
                    ($name -eq 'Import-Module' -and "$($_.CommandElements)" -match '\b(Az\.\w+|Microsoft\.Graph\.\w+)\b'))
            })

        if ($Isolation -eq 'EmbeddedWorker') {
            $where = ($offenders | ForEach-Object { "$($_.GetCommandName()) on line $($_.Extent.StartLineNumber)" }) -join ', '
            $offenders.Count | Should -Be 0 -Because "every such call belongs inside a worker here-string, but found: $where"
            return
        }

        # Graph calls are allowed here only because a dedicated switch re-runs the script as a child process.
        $gate = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq 'Remove-EntraApplicationInSeparateProcess'
                }, $true))
        $gateParameter = @($ast.ParamBlock.Parameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq 'RemoveApplicationClientId' })
        $gate.Count | Should -Be 1 -Because 'the child process that owns the Graph session is launched from this function'
        $gateParameter.Count | Should -Be 1 -Because 'the child process is entered through this parameter'
    }

    It 'names every function with an approved verb' {
        $unapproved = @($functions |
                Where-Object { $_.Name -like '*-*' -and @(Get-Verb | ForEach-Object Verb) -notcontains ($_.Name -split '-')[0] } |
                ForEach-Object Name)
        $unapproved -join ', ' | Should -BeExactly ''
    }

    It 'calls every function it defines' {
        $names = @($functions | ForEach-Object Name)
        $names.Count | Should -BeGreaterThan 0 -Because 'finding no functions would mean this check inspects nothing'
        $orphaned = @($names | Where-Object { $commandNames -notcontains $_ })
        $orphaned -join ', ' | Should -BeExactly ''
    }

    It 'resolves every command it calls' {
        # A rename that misses a call site leaves a command nothing defines, and that only fails when
        # the path calling it happens to run. Modules loaded at run time are listed by pattern, so the
        # answer is the same on a build agent as on a workstation.
        $corePattern = '^(Microsoft\.PowerShell\.|CimCmdlets$|Microsoft\.WSMan\.Management$|ThreadJob$|PSReadLine$|PowerShellGet$|PackageManagement$)'
        $externalPattern = '(?i)^(\w+-(PnP|Mg|Az|IPPS)\w*|Connect-ExchangeOnline|Disconnect-ExchangeOnline|Get-Label|Get-FileStatus|Set-FileLabel|Set-Authentication|az)$'
        $defined = @($functions | ForEach-Object Name)

        $unresolved = @($commandNames | Sort-Object -Unique | Where-Object {
                if ($defined -contains $_) { return $false }
                if ($_ -match $externalPattern) { return $false }
                $command = Get-Command $_ -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $command) { return $true }
                # Resolvable here, but only trusted when it ships with PowerShell itself.
                return -not ("$($command.ModuleName)" -match $corePattern -or $command.CommandType -in 'Application', 'Alias')
            })
        $unresolved -join ', ' | Should -BeExactly ''
    }

    It 'assigns every script-scope variable it reads' {
        # Strict mode turns a read of an unassigned script variable into a terminating error, which
        # normally surfaces only on the rare path that reads it.
        # IsScript, not DriveName: the parser leaves DriveName empty and puts the prefix in UserPath.
        $used = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $node.VariablePath.IsScript
                }, $true))
        $used.Count | Should -BeGreaterThan 0 -Because 'finding none would mean this check inspects nothing'

        $assigned = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $node.Left.VariablePath.IsScript
                }, $true) | ForEach-Object { $_.Left.VariablePath.UserPath })

        $unassigned = @($used | ForEach-Object { $_.VariablePath.UserPath } | Sort-Object -Unique |
                Where-Object { $assigned -notcontains $_ })
        $unassigned -join ', ' | Should -BeExactly ''
    }
}

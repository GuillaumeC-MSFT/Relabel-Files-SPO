#Requires -Version 5.1
<#
    Unit tests for the functions that decide things without touching the network, the certificate
    store, or the file system. They are loaded out of the script by name, because dot-sourcing the
    script would start the utility.
#>

BeforeAll {
    $sourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Relabel-Files.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$null, [ref]$null)
    foreach ($name in 'Get-ErrorText', 'Test-TransientFailure', 'Test-AzureServiceFailure', 'Get-FailureSignature', 'Get-GraphErrorText', 'Get-DependencyReport') {
        $definition = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true) | Select-Object -First 1
        if (-not $definition) { throw "Relabel-Files.ps1 no longer defines $name." }
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    function New-TestErrorRecord {
        param([string]$Message, [string]$Details = '', [string]$InnerMessage = '')

        $exception = if ($InnerMessage) {
            [System.Exception]::new($Message, [System.Exception]::new($InnerMessage))
        }
        else { [System.Exception]::new($Message) }
        $record = [System.Management.Automation.ErrorRecord]::new($exception, 'TestError', 'NotSpecified', $null)
        if ($Details) { $record.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($Details) }
        return $record
    }
}

Describe 'Get-FailureSignature' {
    It 'gives one fault the same signature however its correlation IDs differ' {
        $first = "InternalServerError : Derived method 'TryCreateLogger' cannot reduce access. CorrelationId: 21cee789-fafb-42a9-8094-16bb03bda85f"
        $second = "InternalServerError : Derived method 'TryCreateLogger' cannot reduce access. CorrelationId: 57228e42-2dc8-47c1-90da-aa86128d4f6f"
        Get-FailureSignature -Message $first | Should -Be (Get-FailureSignature -Message $second)
    }

    It 'keeps a genuinely different fault distinct' {
        $service = Get-FailureSignature -Message 'InternalServerError : the provider failed'
        $config = Get-FailureSignature -Message 'AuthorizationFailed : the client does not have permission'
        $service | Should -Not -Be $config
    }

    It 'decodes escaped characters so the same text escaped differently still matches' {
        Get-FailureSignature -Message 'error \u0053ervice busy' | Should -Be (Get-FailureSignature -Message 'error Service busy')
    }

    It 'returns an empty signature for an empty message' {
        Get-FailureSignature -Message '' | Should -BeExactly ''
    }
}

Describe 'Test-AzureServiceFailure' {
    It 'recognises <_> as Azure''s own fault' -ForEach @(
        'InternalServerError : something broke',
        'The remote server returned 503',
        'ServiceBusy, please retry',
        'Gatewaytimeout reached'
    ) { Test-AzureServiceFailure -Message $_ | Should -BeTrue }

    It 'does not blame Azure for <_>' -ForEach @(
        'AuthorizationFailed : the client does not have permission',
        'BadRequest : the subscription id is malformed',
        'The resource group could not be found'
    ) { Test-AzureServiceFailure -Message $_ | Should -BeFalse }
}

Describe 'Test-TransientFailure' {
    It 'retries throttling and transport faults' {
        Test-TransientFailure -Message 'Response status code 429 Too Many Requests' | Should -BeTrue
        Test-TransientFailure -Message 'The operation timed out' | Should -BeTrue
    }

    It 'does not retry a permission failure' {
        Test-TransientFailure -Message 'Access denied. You do not have permission.' | Should -BeFalse
    }
}

Describe 'Get-ErrorText' {
    It 'includes the response body that ErrorDetails carries' {
        $record = New-TestErrorRecord -Message 'Response status code does not indicate success: 400 (Bad Request).' -Details 'The tenant has no billing account.'
        Get-ErrorText -ErrorRecord $record | Should -BeLike '*no billing account*'
    }

    It 'reaches into inner exceptions' {
        $record = New-TestErrorRecord -Message 'One or more errors occurred.' -InnerMessage 'The certificate was not found.'
        Get-ErrorText -ErrorRecord $record | Should -BeLike '*certificate was not found*'
    }

    It 'does not repeat a message that appears twice' {
        $record = New-TestErrorRecord -Message 'Same text' -Details 'Same text'
        Get-ErrorText -ErrorRecord $record | Should -BeExactly 'Same text'
    }
}

Describe 'Get-GraphErrorText' {
    It 'reduces a Graph response to its code and message' {
        $body = '{"error":{"code":"Authorization_RequestDenied","message":"Insufficient privileges to complete the operation.","innerError":{"request-id":"1234"}}}'
        $record = New-TestErrorRecord -Message 'Response status code does not indicate success: 403 (Forbidden).' -Details $body
        Get-GraphErrorText -ErrorRecord $record |
            Should -BeExactly 'Authorization_RequestDenied: Insufficient privileges to complete the operation.'
    }

    It 'truncates an unparseable response instead of printing all of it' {
        $record = New-TestErrorRecord -Message ('x' * 900)
        $text = Get-GraphErrorText -ErrorRecord $record
        $text.Length | Should -BeLessOrEqual 403
        $text | Should -BeLike '*...'
    }
}

Describe 'Get-DependencyReport' {
    BeforeAll {
        # A fixture rather than the real table, so the test asserts the logic and not this machine's modules.
        $script:ModuleExpectation = @(
            [pscustomobject]@{ Name = 'Microsoft.PowerShell.Management'; Minimum = [version]'1.0.0'; Purpose = 'a module that is always present' }
            [pscustomobject]@{ Name = 'Microsoft.PowerShell.Management'; Minimum = [version]'999.0.0'; Purpose = 'a floor nothing can meet' }
            [pscustomobject]@{ Name = 'A.Module.That.Does.Not.Exist'; Minimum = [version]'1.0.0'; Purpose = 'a module that is never present' }
        )
    }

    It 'classifies each dependency as ready, too old, or missing' {
        $report = @(Get-DependencyReport)
        $report.Count | Should -Be 3
        $report[0].State | Should -BeExactly 'Ready'
        $report[1].State | Should -BeExactly 'TooOld'
        $report[2].State | Should -BeExactly 'Missing'
        $report[2].Installed | Should -BeNullOrEmpty
    }
}

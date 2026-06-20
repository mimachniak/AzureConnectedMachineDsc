# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

Describe 'azure_arc_agent resource tests' -Skip:(!$IsWindows) {
    BeforeAll {
        $resourceType = 'Microsoft.Azure.Arc/AgentConfiguration'
        $originalPath = $env:PATH
        $stubRoot = Join-Path $TestDrive 'stub'
        $statePath = Join-Path $TestDrive 'state.json'
        $logPath = Join-Path $TestDrive 'commands.log'

        New-Item -Path $stubRoot -ItemType Directory -Force | Out-Null

        $stubScript = @'
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$statePath = $env:ARC_AGENT_TEST_STATE_PATH
$logPath = $env:ARC_AGENT_TEST_LOG_PATH

Add-Content -Path $logPath -Value ($Arguments -join ' ')

$state = Get-Content -Path $statePath -Raw | ConvertFrom-Json -AsHashtable

function Save-State {
    $state | ConvertTo-Json -Depth 10 | Set-Content -Path $statePath
}

function Write-StateValue {
    param([object]$Value)

    if ($Value -is [bool]) {
        $Value.ToString().ToLowerInvariant()
        return
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        ($Value | ForEach-Object { [string]$_ }) -join ','
        return
    }

    [string]$Value
}

if ($Arguments.Count -lt 2 -or $Arguments[0] -ne 'config') {
    Write-Error 'Unsupported fake azcmagent invocation.'
    exit 1
}

switch ($Arguments[1]) {
    'get' {
        $propertyName = $Arguments[2]
        Write-StateValue -Value $state[$propertyName]
        exit 0
    }
    'set' {
        $propertyName = $Arguments[2]
        $propertyValue = $Arguments[3]

        switch ($propertyName) {
            'incomingconnections.enabled' { $state[$propertyName] = [System.Convert]::ToBoolean($propertyValue) }
            'guestconfiguration.enabled' { $state[$propertyName] = [System.Convert]::ToBoolean($propertyValue) }
            'extensions.enabled' { $state[$propertyName] = [System.Convert]::ToBoolean($propertyValue) }
            'extensions.allowlist' { $state[$propertyName] = @($propertyValue -split ',' | Where-Object { $_ }) }
            'extensions.blocklist' { $state[$propertyName] = @($propertyValue -split ',' | Where-Object { $_ }) }
            'config.mode' { $state[$propertyName] = $propertyValue }
            default {
                Write-Error "Unsupported property '$propertyName'."
                exit 1
            }
        }

        Save-State
        exit 0
    }
    default {
        Write-Error "Unsupported fake azcmagent command '$($Arguments[1])'."
        exit 1
    }
}
'@

        Set-Content -Path (Join-Path $stubRoot 'azcmagent.ps1') -Value $stubScript
        $env:ARC_AGENT_TEST_STATE_PATH = $statePath
        $env:ARC_AGENT_TEST_LOG_PATH = $logPath

        function Set-TestState {
            param([hashtable]$State)

            $State | ConvertTo-Json -Depth 10 | Set-Content -Path $statePath
        }

        function Get-TestLog {
            if (-not (Test-Path -Path $logPath)) {
                return @()
            }

            return Get-Content -Path $logPath
        }
    }

    BeforeEach {
        Set-TestState -State @{
            'incomingconnections.enabled' = $true
            'guestconfiguration.enabled' = $true
            'extensions.enabled' = $true
            'extensions.allowlist' = @('Contoso.Extension/Example')
            'extensions.blocklist' = @('Contoso.Blocked/Example')
            'config.mode' = 'monitor'
        }

        Set-Content -Path $logPath -Value ''
        $env:PATH = "$stubRoot$([IO.Path]::PathSeparator)$originalPath"
    }

    AfterAll {
        $env:PATH = $originalPath
        Remove-Item Env:ARC_AGENT_TEST_STATE_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:ARC_AGENT_TEST_LOG_PATH -ErrorAction SilentlyContinue
    }

    It 'Get returns the current azcmagent configuration' {
        $out = '{}' | dsc resource get -r $resourceType -f - 2>$TestDrive/error.txt | ConvertFrom-Json
        $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Path $TestDrive/error.txt -Raw)
        $out.actualState.agentInstalled | Should -BeTrue
        $out.actualState.incomingConnectionsEnabled | Should -BeTrue
        $out.actualState.guestConfigurationEnabled | Should -BeTrue
        $out.actualState.extensionsEnabled | Should -BeTrue
        $out.actualState.extensionAllowlist | Should -Be @('Contoso.Extension/Example')
        $out.actualState.extensionBlocklist | Should -Be @('Contoso.Blocked/Example')
        $out.actualState.configMode | Should -Be 'monitor'
    }

    It 'Test returns false when the current state differs from the desired defaults' {
        $out = '{}' | dsc resource test -r $resourceType -f - 2>$TestDrive/error.txt | ConvertFrom-Json
        $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Path $TestDrive/error.txt -Raw)
        $out.inDesiredState | Should -BeFalse
    }

    It 'Set applies the required Azure Arc commands in order' {
        $out = '{}' | dsc resource set -r $resourceType -f - 2>$TestDrive/error.txt | ConvertFrom-Json
        $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Path $TestDrive/error.txt -Raw)
        $out.afterState.agentInstalled | Should -BeTrue
        $out.afterState.incomingConnectionsEnabled | Should -BeFalse
        $out.afterState.guestConfigurationEnabled | Should -BeFalse
        $out.afterState.extensionsEnabled | Should -BeFalse
        $out.afterState.extensionAllowlist | Should -Be @(
            'Microsoft.Azure.AzureDefenderForServers/MDE.Windows'
            'Microsoft.Azure.Monitor/AzureMonitorWindowsAgent'
        )
        $out.afterState.extensionBlocklist | Should -Contain 'Microsoft.Cplat.Core/RunCommandHandlerWindows'
        $out.afterState.configMode | Should -Be 'full'

        $log = @(Get-TestLog | Where-Object { $_ })
        $log | Should -Contain 'config set incomingconnections.enabled false'
        $log | Should -Contain 'config set guestconfiguration.enabled false'
        $log | Should -Contain 'config set extensions.enabled false'
        $log | Should -Contain 'config set extensions.allowlist Microsoft.Azure.AzureDefenderForServers/MDE.Windows,Microsoft.Azure.Monitor/AzureMonitorWindowsAgent'
        $log | Should -Contain 'config set extensions.blocklist Microsoft.Azure.Automation.HybridWorker/HybridWorkerForWindows,Microsoft.Azure.Automation/HybridWorkerForLinux,Microsoft.Azure.Extensions/CustomScript,Microsoft.Cplat.Core/RunCommandHandlerLinux,Microsoft.Cplat.Core/RunCommandHandlerWindows,Microsoft.Compute/CustomScriptExtension,Microsoft.EnterpriseCloud.Monitoring/MicrosoftMonitoringAgent,Microsoft.EnterpriseCloud.Monitoring/OMSAgentForLinux'
        $modeLog = @($log | Where-Object { $_ -like 'config set config.mode *' })
        $modeLog | Should -Be @(
            'config set config.mode monitor'
            'config set config.mode full'
        )
    }
}
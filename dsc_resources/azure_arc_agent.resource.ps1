# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('Get', 'Set', 'Test', 'Export')]
    [string]$Operation,

    [Parameter(Position = 1, ValueFromPipeline = $true)]
    [AllowEmptyString()]
    [string]$JsonInput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PropertyMap = @{
    incomingConnectionsEnabled = 'incomingconnections.enabled'
    guestConfigurationEnabled  = 'guestconfiguration.enabled'
    extensionsEnabled          = 'extensions.enabled'
    extensionAllowlist         = 'extensions.allowlist'
    extensionBlocklist         = 'extensions.blocklist'
    configMode                 = 'config.mode'
    proxyUrl                   = 'proxy.url'
}

function Find-AzcmAgentCommand {
    $command = Get-Command -Name 'azcmagent' -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return $null
    }

    return $command.Source
}

function ConvertFrom-ResourceInput {
    param(
        [AllowEmptyString()]
        [string]$InputObject
    )

    if ([string]::IsNullOrWhiteSpace($InputObject)) {
        return @{}
    }

    return $InputObject | ConvertFrom-Json -AsHashtable
}

function ConvertTo-NormalizedStringList {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return @()
    }

    $items = @()

    if ($Value -is [string]) {
        $stringValue = $Value.Trim()

        # azcmagent can return lists in bracket notation, for example:
        # [Microsoft.Azure.Monitor/AzureMonitorWindowsAgent] or []
        if ($stringValue -match '^\[(.*)\]$') {
            $stringValue = $Matches[1]
        }

        if (-not [string]::IsNullOrWhiteSpace($stringValue)) {
            $items = $stringValue -split ','
        }
    } elseif ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($item in $Value) {
            if ($item -is [string]) {
                $itemString = $item.Trim()
                if ($itemString -match '^\[(.*)\]$') {
                    $itemString = $Matches[1]
                }

                if (-not [string]::IsNullOrWhiteSpace($itemString)) {
                    $items += ($itemString -split ',')
                }
            } elseif ($null -ne $item) {
                $items += [string]$item
            }
        }
    } else {
        $items = @([string]$Value)
    }

    $normalizedItems = @(
        $items |
            ForEach-Object { $_.Trim().Trim("'").Trim('"') } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )

    return ,$normalizedItems
}

function ConvertTo-NormalizedBoolean {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [bool]) {
        return $Value
    }

    $candidate = [string]$Value
    $parsed = $false
    if ([bool]::TryParse($candidate, [ref]$parsed)) {
        return $parsed
    }

    throw "Invalid boolean value '$candidate'."
}

function ConvertTo-NormalizedConfigMode {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    $mode = ([string]$Value).Trim().ToLowerInvariant()
    if ($mode -notin @('monitor', 'full')) {
        throw "Invalid configMode value '$Value'. Supported values are 'monitor' and 'full'."
    }

    return $mode
}

function Join-ConfigValue {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($Value -is [bool]) {
        return $Value.ToString().ToLowerInvariant()
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return (($Value | ForEach-Object { [string]$_ }) -join ',')
    }

    return [string]$Value
}

function Invoke-AzcmAgent {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [switch]$IgnoreExitCode
    )

    if ([string]::IsNullOrWhiteSpace($script:AzcmAgentPath)) {
        throw 'The azcmagent executable was not found. Install the Azure Connected Machine agent first.'
    }

    $output = & $script:AzcmAgentPath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine

    if (-not $IgnoreExitCode -and $exitCode -ne 0) {
        throw "azcmagent $($Arguments -join ' ') failed with exit code $exitCode. $text".Trim()
    }

    return $text.Trim()
}

function Get-DesiredState {
    param(
        [hashtable]$InputObject
    )

    $desiredState = @{}

    foreach ($key in $InputObject.Keys) {
        switch ($key) {
            'incomingConnectionsEnabled' {
                $desiredState[$key] = ConvertTo-NormalizedBoolean -Value $InputObject[$key]
            }
            'guestConfigurationEnabled' {
                $desiredState[$key] = ConvertTo-NormalizedBoolean -Value $InputObject[$key]
            }
            'extensionsEnabled' {
                $desiredState[$key] = ConvertTo-NormalizedBoolean -Value $InputObject[$key]
            }
            'extensionAllowlist' {
                $desiredState[$key] = ConvertTo-NormalizedStringList -Value $InputObject[$key]
            }
            'extensionBlocklist' {
                $desiredState[$key] = ConvertTo-NormalizedStringList -Value $InputObject[$key]
            }
            'configMode' {
                $desiredState[$key] = ConvertTo-NormalizedConfigMode -Value $InputObject[$key]
            }
            'proxyUrl' {
                $desiredState[$key] = [string]$InputObject[$key]
            }
            'agentInstalled' { }
            '_inDesiredState' { }
            default {
                throw "Unsupported property '$key'."
            }
        }
    }

    return $desiredState
}

function Get-ConfigPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    $rawValue = Invoke-AzcmAgent -Arguments @('config', 'get', $PropertyName)
    if ([string]::IsNullOrWhiteSpace($rawValue)) {
        return $null
    }

    return $rawValue
}

function Get-CurrentState {
    $state = @{
        incomingConnectionsEnabled = $null
        guestConfigurationEnabled  = $null
        extensionsEnabled          = $null
        extensionAllowlist         = $null
        extensionBlocklist         = $null
        configMode                 = $null
        proxyUrl                   = $null
        agentInstalled             = $false
    }

    if ([string]::IsNullOrWhiteSpace($script:AzcmAgentPath)) {
        return $state
    }

    $state.agentInstalled = $true
    $state.incomingConnectionsEnabled = ConvertTo-NormalizedBoolean -Value (Get-ConfigPropertyValue -PropertyName 'incomingconnections.enabled')
    $state.guestConfigurationEnabled = ConvertTo-NormalizedBoolean -Value (Get-ConfigPropertyValue -PropertyName 'guestconfiguration.enabled')
    $state.extensionsEnabled = ConvertTo-NormalizedBoolean -Value (Get-ConfigPropertyValue -PropertyName 'extensions.enabled')
    $state.extensionAllowlist = ConvertTo-NormalizedStringList -Value (Get-ConfigPropertyValue -PropertyName 'extensions.allowlist')
    $state.extensionBlocklist = ConvertTo-NormalizedStringList -Value (Get-ConfigPropertyValue -PropertyName 'extensions.blocklist')
    $state.configMode = ConvertTo-NormalizedConfigMode -Value (Get-ConfigPropertyValue -PropertyName 'config.mode')
    $state.proxyUrl = Get-ConfigPropertyValue -PropertyName 'proxy.url'

    return $state
}

function Test-StringListEquality {
    param(
        [AllowNull()]
        [object]$Left,

        [AllowNull()]
        [object]$Right
    )

    $leftValues = @(ConvertTo-NormalizedStringList -Value $Left)
    $rightValues = @(ConvertTo-NormalizedStringList -Value $Right)

    if ($leftValues.Count -ne $rightValues.Count) {
        return $false
    }

    return $null -eq (Compare-Object -ReferenceObject $leftValues -DifferenceObject $rightValues)
}

function Test-InDesiredState {
    param(
        [hashtable]$CurrentState,
        [hashtable]$DesiredState
    )

    if (-not $CurrentState.agentInstalled) {
        return $false
    }

    foreach ($key in $DesiredState.Keys) {
        if ($key -in @('extensionAllowlist', 'extensionBlocklist')) {
            if (-not (Test-StringListEquality -Left $CurrentState[$key] -Right $DesiredState[$key])) {
                return $false
            }

            continue
        }

        if ($CurrentState[$key] -cne $DesiredState[$key]) {
            return $false
        }
    }

    return $true
}

function Set-ConfigPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PropertyName,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Value
    )

    $valueText = Join-ConfigValue -Value $Value
    $null = Invoke-AzcmAgent -Arguments @('config', 'set', $PropertyName, $valueText)
}

function Set-DesiredState {
    param(
        [hashtable]$CurrentState,
        [hashtable]$DesiredState
    )

    if (-not $CurrentState.agentInstalled) {
        throw 'The azcmagent executable was not found. Install the Azure Connected Machine agent first.'
    }

    foreach ($key in $DesiredState.Keys) {
        $currentValue = $CurrentState[$key]
        $desiredValue = $DesiredState[$key]
        $propertyName = $script:PropertyMap[$key]

        $needsUpdate = $false
        if ($key -in @('extensionAllowlist', 'extensionBlocklist')) {
            $needsUpdate = -not (Test-StringListEquality -Left $currentValue -Right $desiredValue)
        } else {
            $needsUpdate = $currentValue -cne $desiredValue
        }

        if (-not $needsUpdate) {
            continue
        }

        if ($key -ceq 'configMode' -and $desiredValue -ceq 'full') {
            Set-ConfigPropertyValue -PropertyName $propertyName -Value 'monitor'
            Set-ConfigPropertyValue -PropertyName $propertyName -Value 'full'
        } else {
            Set-ConfigPropertyValue -PropertyName $propertyName -Value $desiredValue
        }
    }

    return Get-CurrentState
}

function Get-ExportState {
    $currentState = Get-CurrentState

    if (-not $currentState.agentInstalled) {
        return @{}
    }

    $exportState = @{}
    foreach ($key in $script:PropertyMap.Keys) {
        $value = $currentState[$key]
        if ($null -ne $value) {
            $exportState[$key] = $value
        }
    }

    return $exportState
}

try {
    $script:AzcmAgentPath = Find-AzcmAgentCommand
    $inputObject = ConvertFrom-ResourceInput -InputObject $JsonInput

    switch ($Operation) {
        'Get' {
            $result = Get-CurrentState
        }
        'Test' {
            $desiredState = Get-DesiredState -InputObject $inputObject
            $currentState = Get-CurrentState
            $result = @{}
            foreach ($key in $desiredState.Keys) {
                if ($currentState.ContainsKey($key)) {
                    $result[$key] = $currentState[$key]
                }
            }
            $result._inDesiredState = (Test-InDesiredState -CurrentState $currentState -DesiredState $desiredState)
        }
        'Set' {
            $desiredState = Get-DesiredState -InputObject $inputObject
            $currentState = Get-CurrentState
            if (Test-InDesiredState -CurrentState $currentState -DesiredState $desiredState) {
                $result = $currentState
            } else {
                $result = Set-DesiredState -CurrentState $currentState -DesiredState $desiredState
            }
        }
        'Export' {
            $result = Get-ExportState
        }
    }

    $result | ConvertTo-Json -Compress -Depth 10
}
catch {
    Write-Error $_
    exit 1
}
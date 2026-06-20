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

<#
.SYNOPSIS
Finds the azcmagent executable path.

.DESCRIPTION
Resolves the azcmagent command from PATH and returns the resolved source path.

.INPUTS
None.

.OUTPUTS
System.String or System.Management.Automation.Language.NullString
Path to azcmagent when found; otherwise null.
#>
function Find-AzcmAgentCommand {
    $command = Get-Command -Name 'azcmagent' -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return $null
    }

    return $command.Source
}

<#
.SYNOPSIS
Converts incoming resource JSON into a hashtable.

.DESCRIPTION
Returns an empty hashtable for empty or whitespace input; otherwise parses JSON
input into a hashtable used by the resource operations.

.PARAMETER InputObject
JSON string provided to the resource operation.

.INPUTS
System.String

.OUTPUTS
System.Collections.Hashtable
#>
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

<#
.SYNOPSIS
Normalizes list-like values to a canonical string array.

.DESCRIPTION
Accepts strings, collections, or null and returns a trimmed, deduplicated,
sorted array of non-empty string values.

.PARAMETER Value
Input value to normalize.

.INPUTS
System.Object

.OUTPUTS
System.String[]
#>
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

<#
.SYNOPSIS
Converts a value to a normalized boolean.

.DESCRIPTION
Returns null for null input, returns boolean values unchanged, and attempts
to parse string values as booleans.

.PARAMETER Value
Input value to normalize.

.INPUTS
System.Object

.OUTPUTS
System.Boolean or $null
#>
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

<#
.SYNOPSIS
Normalizes and validates the config mode value.

.DESCRIPTION
Converts input to lowercase and validates that it is either monitor or full.

.PARAMETER Value
Input config mode value.

.INPUTS
System.Object

.OUTPUTS
System.String or $null
#>
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

<#
.SYNOPSIS
Converts normalized values into azcmagent argument text.

.DESCRIPTION
Formats booleans as lowercase text and joins enumerable values as
comma-separated strings.

.PARAMETER Value
Value to convert for azcmagent config set.

.INPUTS
System.Object

.OUTPUTS
System.String
#>
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

<#
.SYNOPSIS
Invokes azcmagent with the provided arguments.

.DESCRIPTION
Executes azcmagent, captures combined output, validates exit code, and returns
trimmed text output.

.PARAMETER Arguments
Argument list passed directly to azcmagent.

.PARAMETER IgnoreExitCode
Skips non-zero exit code validation when specified.

.INPUTS
System.String[]

.OUTPUTS
System.String
#>
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

<#
.SYNOPSIS
Builds validated desired state from input properties.

.DESCRIPTION
Validates supported keys and normalizes values to the internal desired-state
representation used by Test and Set operations.

.PARAMETER InputObject
Input hashtable containing desired property values.

.INPUTS
System.Collections.Hashtable

.OUTPUTS
System.Collections.Hashtable
#>
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

<#
.SYNOPSIS
Reads a single Azure Arc agent configuration property.

.DESCRIPTION
Invokes azcmagent config get for the requested property and returns null for
empty responses.

.PARAMETER PropertyName
Azcmagent configuration property name.

.INPUTS
System.String

.OUTPUTS
System.String or $null
#>
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

<#
.SYNOPSIS
Retrieves current state from the Azure Arc agent.

.DESCRIPTION
Returns a state object with normalized values for all resource properties. If
azcmagent is not available, returns defaults with agentInstalled set to false.

.INPUTS
None.

.OUTPUTS
System.Collections.Hashtable
#>
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

<#
.SYNOPSIS
Compares two list-like values for logical equality.

.DESCRIPTION
Normalizes both values as string arrays and compares size and content.

.PARAMETER Left
First value to compare.

.PARAMETER Right
Second value to compare.

.INPUTS
System.Object

.OUTPUTS
System.Boolean
#>
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

<#
.SYNOPSIS
Determines whether current state matches desired state.

.DESCRIPTION
Compares desired keys against current state and performs normalized list
comparison for allowlist and blocklist properties.

.PARAMETER CurrentState
Current resource state.

.PARAMETER DesiredState
Desired resource state.

.INPUTS
System.Collections.Hashtable

.OUTPUTS
System.Boolean
#>
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

<#
.SYNOPSIS
Sets a single Azure Arc agent configuration property.

.DESCRIPTION
Converts the provided value into azcmagent argument text and invokes
azcmagent config set.

.PARAMETER PropertyName
Azcmagent configuration property name.

.PARAMETER Value
Value to set for the property.

.INPUTS
System.String, System.Object

.OUTPUTS
None.
#>
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

<#
.SYNOPSIS
Applies desired state differences to Azure Arc agent settings.

.DESCRIPTION
Compares current and desired state and invokes azcmagent config set only for
properties that require updates.

.PARAMETER CurrentState
Current resource state.

.PARAMETER DesiredState
Desired resource state.

.INPUTS
System.Collections.Hashtable

.OUTPUTS
System.Collections.Hashtable
Updated current state after changes are applied.
#>
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

<#
.SYNOPSIS
Builds exportable state from current configuration.

.DESCRIPTION
Returns non-null writable properties suitable for export. Returns an empty
hashtable when the agent is not installed.

.INPUTS
None.

.OUTPUTS
System.Collections.Hashtable
#>
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
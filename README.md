# AzureConnectedMachineDsc

DSC resource for managing Azure Arc for Servers agent configuration.

## Prerequisites

- Windows PowerShell 7 (`pwsh`) available in `PATH`
- Azure Arc agent installed (`azcmagent` command available)
- Administrator session for `set` operations (resource requires elevated security context)

## Install DSC v3

### Stable

```powershell
winget install --id Microsoft.DSC --exact --source winget
```

### Preview (optional)

```powershell
winget install --id Microsoft.DSC.Preview --exact --source winget
```

### Verify installation

```powershell
dsc --version
```

## Make the resource discoverable

This repository keeps the resource files in `dsc_resources`.

You can use one of two methods:

### Method 1 (recommended): set `DSC_RESOURCE_PATH`

```powershell
$repoRoot = "D:\Git\AzureConnectedMachineDsc"
$env:DSC_RESOURCE_PATH = Join-Path $repoRoot 'dsc_resources'

# Optional: persist for future sessions
[System.Environment]::SetEnvironmentVariable('DSC_RESOURCE_PATH', $env:DSC_RESOURCE_PATH, 'User')
```

### Method 2: copy resource files to DSC root folder

```powershell
$repoRoot = "D:\Git\AzureConnectedMachineDsc"
$resourceSource = Join-Path $repoRoot 'dsc_resources\*'
$dscRoot = Split-Path (Get-Command dsc -ErrorAction Stop).Source -Parent

Copy-Item -Path $resourceSource -Destination $dscRoot -Recurse -Force
```

## Quick validation

```powershell
# List resources and confirm the custom type is found
dsc resource list | Select-String 'Microsoft.Azure.Arc/AgentConfiguration'

# Get current state
'{}' | dsc resource get -r Microsoft.Azure.Arc/AgentConfiguration -f - | ConvertFrom-Json
```

## Run tests

```powershell
Set-Location D:\Git\AzureConnectedMachineDsc\dsc_resources\tests
$env:DSC_RESOURCE_PATH = "D:\Git\AzureConnectedMachineDsc\dsc_resources"
Invoke-Pester -Path .\azure_arc_agent.tests.ps1 -Output Detailed
```

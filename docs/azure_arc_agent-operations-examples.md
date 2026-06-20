# Microsoft.Azure.Arc/AgentConfiguration operation examples

Examples in this file are based on test behavior in dsc_resources/tests/azure_arc_agent.tests.ps1.

## Prerequisites

```powershell
$env:DSC_RESOURCE_PATH = "D:\Git\AzureConnectedMachineDsc\dsc_resources"
$resourceType = "Microsoft.Azure.Arc/AgentConfiguration"
```

## Get

Use an empty input object to read current agent configuration.

```powershell
'{}' | dsc resource get -r $resourceType -f - | ConvertFrom-Json
```

Expected fields in output include:

- actualState.agentInstalled
- actualState.incomingConnectionsEnabled
- actualState.guestConfigurationEnabled
- actualState.extensionsEnabled
- actualState.extensionAllowlist
- actualState.extensionBlocklist
- actualState.configMode

## Test

Provide the desired configuration and evaluate drift.

```powershell
$desired = @{
  incomingConnectionsEnabled = $false
  guestConfigurationEnabled  = $false
  extensionsEnabled          = $false
  extensionAllowlist         = @(
    "Microsoft.Azure.AzureDefenderForServers/MDE.Windows"
    "Microsoft.Azure.Monitor/AzureMonitorWindowsAgent"
  )
  extensionBlocklist         = @(
    "Microsoft.Azure.Automation.HybridWorker/HybridWorkerForWindows"
    "Microsoft.Azure.Automation/HybridWorkerForLinux"
    "Microsoft.Azure.Extensions/CustomScript"
    "Microsoft.Cplat.Core/RunCommandHandlerLinux"
    "Microsoft.Cplat.Core/RunCommandHandlerWindows"
    "Microsoft.Compute/CustomScriptExtension"
    "Microsoft.EnterpriseCloud.Monitoring/MicrosoftMonitoringAgent"
    "Microsoft.EnterpriseCloud.Monitoring/OMSAgentForLinux"
  )
  configMode = "full"
}

$desired | ConvertTo-Json -Depth 10 -Compress |
  dsc resource test -r $resourceType -f - |
  ConvertFrom-Json
```

Result includes:

- desired properties echoed as current values for compared keys
- _inDesiredState (true or false)

## Set

Set applies desired values. This operation requires elevated permissions.

```powershell
$desired = @{
  incomingConnectionsEnabled = $false
  guestConfigurationEnabled  = $false
  extensionsEnabled          = $false
  extensionAllowlist         = @(
    "Microsoft.Azure.AzureDefenderForServers/MDE.Windows"
    "Microsoft.Azure.Monitor/AzureMonitorWindowsAgent"
  )
  extensionBlocklist         = @(
    "Microsoft.Azure.Automation.HybridWorker/HybridWorkerForWindows"
    "Microsoft.Azure.Automation/HybridWorkerForLinux"
    "Microsoft.Azure.Extensions/CustomScript"
    "Microsoft.Cplat.Core/RunCommandHandlerLinux"
    "Microsoft.Cplat.Core/RunCommandHandlerWindows"
    "Microsoft.Compute/CustomScriptExtension"
    "Microsoft.EnterpriseCloud.Monitoring/MicrosoftMonitoringAgent"
    "Microsoft.EnterpriseCloud.Monitoring/OMSAgentForLinux"
  )
  configMode = "full"
}

$desired | ConvertTo-Json -Depth 10 -Compress |
  dsc resource set -r $resourceType -f - |
  ConvertFrom-Json
```

Expected afterState values in tests:

- incomingConnectionsEnabled = false
- guestConfigurationEnabled = false
- extensionsEnabled = false
- extensionAllowlist contains Microsoft.Azure.AzureDefenderForServers/MDE.Windows and Microsoft.Azure.Monitor/AzureMonitorWindowsAgent
- extensionBlocklist contains Microsoft.Cplat.Core/RunCommandHandlerWindows
- configMode = full

## Export

Export returns current non-null properties as reusable configuration state.

```powershell
'{}' | dsc resource export -r $resourceType -f - | ConvertFrom-Json
```

Typical use: pipe export output to file and use it as baseline desired state.

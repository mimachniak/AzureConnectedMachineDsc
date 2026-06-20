# Microsoft.Azure.Arc/AgentConfiguration parameters

This document describes all resource properties, allowed values, and usage notes for the DSC v3 resource type:

- Microsoft.Azure.Arc/AgentConfiguration

## Writable properties

| Property | Type | Allowed values | Notes |
|---|---|---|---|
| incomingConnectionsEnabled | boolean or null | true, false, null | Maps to azcmagent config key incomingconnections.enabled. |
| guestConfigurationEnabled | boolean or null | true, false, null | Maps to azcmagent config key guestconfiguration.enabled. |
| extensionsEnabled | boolean or null | true, false, null | Maps to azcmagent config key extensions.enabled. |
| extensionAllowlist | array of string or null | null or list of extension names | Maps to azcmagent config key extensions.allowlist. Empty list is allowed. |
| extensionBlocklist | array of string or null | null or list of extension names | Maps to azcmagent config key extensions.blocklist. Empty list is allowed. |
| configMode | string or null | monitor, full, null | Any other value fails validation. Comparison is case-insensitive in processing. |
| proxyUrl | string or null | any string, null | Maps to azcmagent config key proxy.url. |

## Read-only properties

| Property | Type | Allowed values | Notes |
|---|---|---|---|
| agentInstalled | boolean or null | true, false, null | Returned by get/test/set state output. Not intended as input. |
| _inDesiredState | boolean or null | true, false, null | Returned by test output. Not intended as input. |

## Input validation behavior

- Unknown properties are rejected.
- Boolean properties accept boolean values and boolean-like strings convertible to true/false.
- configMode accepts only monitor or full.
- extensionAllowlist and extensionBlocklist are normalized as string lists (trimmed, deduplicated, sorted).

## Security context requirement

The set operation requires elevated security context.

In resource manifest terms:

- set.requireSecurityContext = elevated

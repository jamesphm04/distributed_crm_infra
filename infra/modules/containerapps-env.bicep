@description('Azure region for every resource.')
param location string

@description('Short workload name used in resource names.')
param workload string

@description('Environment name used in resource names, e.g. dev.')
param environmentName string

@description('Tags applied to every resource.')
param tags object

@description('Resource ID of the Log Analytics workspace that receives container logs.')
param logAnalyticsWorkspaceId string

resource environment 'Microsoft.App/managedEnvironments@2025-07-01' = {
  name: 'cae-${workload}-${environmentName}'
  location: location
  tags: tags
  properties: {
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    appLogsConfiguration: {
      destination: 'azure-monitor'
    }
    zoneRedundant: false
  }
}

// Sends container console and system logs to the workspace through Azure Monitor, with no workspace key.
resource logsToWorkspace 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'logs-to-workspace'
  scope: environment
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

output name string = environment.name
output id string = environment.id
output defaultDomain string = environment.properties.defaultDomain

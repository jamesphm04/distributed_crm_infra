targetScope = 'subscription'

@description('Azure region for every resource.')
param location string

@description('Short workload name used in resource names.')
param workload string

@description('Environment name used in resource names, e.g. dev.')
param environmentName string

@description('Tags applied to every resource.')
param tags object

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${workload}-${environmentName}'
  location: location
  tags: tags
}

output resourceGroupName string = rg.name

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  scope: rg
  params: {
    location: location
    workload: workload
    environmentName: environmentName
    tags: tags
  }
}

module identities 'modules/identities.bicep' = {
  name: 'identities'
  scope: rg
  params: {
    location: location
    workload: workload
    environmentName: environmentName
    tags: tags
  }
}

module registry 'modules/registry.bicep' = {
  name: 'registry'
  scope: rg
  params: {
    location: location
    workload: workload
    environmentName: environmentName
    tags: tags
    pullPrincipalIds: [
      identities.outputs.bePrincipalId
      identities.outputs.workerPrincipalId
    ]
  }
}

module keyVault 'modules/keyvault.bicep' = {
  name: 'keyVault'
  scope: rg
  params: {
    location: location
    workload: workload
    environmentName: environmentName
    tags: tags
    secretReaderPrincipalIds: [
      identities.outputs.bePrincipalId
      identities.outputs.workerPrincipalId
    ]
  }
}

module serviceBus 'modules/servicebus.bicep' = {
  name: 'serviceBus'
  scope: rg
  params: {
    location: location
    workload: workload
    environmentName: environmentName
    tags: tags
    senderPrincipalIds: [
      identities.outputs.bePrincipalId
      identities.outputs.workerPrincipalId
    ]
    receiverPrincipalIds: [
      identities.outputs.workerPrincipalId
    ]
  }
}

module postgres 'modules/postgres.bicep' = {
  name: 'postgres'
  scope: rg
  params: {
    location: location
    workload: workload
    environmentName: environmentName
    tags: tags
    databaseName: 'distributed_crm'
  }
}

module redis 'modules/redis.bicep' = {
  name: 'redis'
  scope: rg
  params: {
    location: location
    workload: workload
    environmentName: environmentName
    tags: tags
    userPrincipalIds: [
      identities.outputs.bePrincipalId
      identities.outputs.workerPrincipalId
    ]
  }
}

module containerAppsEnvironment 'modules/containerapps-env.bicep' = {
  name: 'containerAppsEnvironment'
  scope: rg
  params: {
    location: location
    workload: workload
    environmentName: environmentName
    tags: tags
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
  }
}

output keyVaultName string = keyVault.outputs.name

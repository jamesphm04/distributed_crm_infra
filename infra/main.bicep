targetScope = 'subscription'

@description('Azure region for every resource.')
param location string

@description('Short workload name used in resource names.')
param workload string

@description('Environment name used in resource names, e.g. dev.')
param environmentName string

@description('Tags applied to every resource.')
param tags object

@description('Principal ID of the GitHub Actions identity, from the dcrm-cicd stack (deploy.sh passes it).')
param pipelinePrincipalId string

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${workload}-${environmentName}'
  location: location
  tags: tags
}

output resourceGroupName string = rg.name

module pipelineAccess 'modules/pipeline-access.bicep' = {
  name: 'pipelineAccess'
  scope: rg
  params: {
    pipelinePrincipalId: pipelinePrincipalId
  }
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  scope: rg
  params: {
    location: location
    workload: workload
    environmentName: environmentName
    tags: tags
    publisherPrincipalIds: [
      identities.outputs.bePrincipalId
      identities.outputs.workerPrincipalId
    ]
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
      identities.outputs.migratePrincipalId
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
    // Only be reads secrets (its Google sign-in settings); the worker has none.
    secretReaderPrincipalIds: [
      identities.outputs.bePrincipalId
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
    migrateIdentityName: identities.outputs.migrateIdentityName
    migratePrincipalId: identities.outputs.migratePrincipalId
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

// Everything an app deployment needs, read from this stack by the pipelines: the stack is the single source of truth
// for names and IDs that change with every teardown and rebuild. None of these are secrets.
output containerAppsEnvironmentId string = containerAppsEnvironment.outputs.id
output registryLoginServer string = registry.outputs.loginServer
output keyVaultUri string = keyVault.outputs.uri
output postgresHost string = postgres.outputs.host
output postgresDatabaseName string = postgres.outputs.databaseName
output redisHost string = redis.outputs.host
output serviceBusNamespace string = serviceBus.outputs.fullyQualifiedNamespace
output appInsightsConnectionString string = monitoring.outputs.appInsightsConnectionString
output beIdentityId string = identities.outputs.beIdentityId
output beIdentityName string = identities.outputs.beIdentityName
output beClientId string = identities.outputs.beClientId
output workerIdentityId string = identities.outputs.workerIdentityId
output workerIdentityName string = identities.outputs.workerIdentityName
output workerClientId string = identities.outputs.workerClientId
output migrateIdentityId string = identities.outputs.migrateIdentityId
output migrateIdentityName string = identities.outputs.migrateIdentityName
output migrateClientId string = identities.outputs.migrateClientId

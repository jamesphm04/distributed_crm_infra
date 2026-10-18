@description('Azure region for every resource.')
param location string

@description('Short workload name used in resource names.')
param workload string

@description('Environment name used in resource names, e.g. dev.')
param environmentName string

@description('Tags applied to every resource.')
param tags object

resource beIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${workload}-be-${environmentName}'
  location: location
  tags: tags
}

resource workerIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${workload}-worker-${environmentName}'
  location: location
  tags: tags
}

// The migration job's identity: a Postgres Entra admin, so it can change the schema and create the apps' roles.
resource migrateIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${workload}-migrate-${environmentName}'
  location: location
  tags: tags
}

// Name: what Postgres knows the identity as. Client ID: what the app passes to ask for a token as this identity.
output beIdentityId string = beIdentity.id
output beIdentityName string = beIdentity.name
output beClientId string = beIdentity.properties.clientId
output bePrincipalId string = beIdentity.properties.principalId
output workerIdentityId string = workerIdentity.id
output workerIdentityName string = workerIdentity.name
output workerClientId string = workerIdentity.properties.clientId
output workerPrincipalId string = workerIdentity.properties.principalId
output migrateIdentityId string = migrateIdentity.id
output migrateIdentityName string = migrateIdentity.name
output migrateClientId string = migrateIdentity.properties.clientId
output migratePrincipalId string = migrateIdentity.properties.principalId

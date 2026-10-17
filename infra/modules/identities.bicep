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

output beIdentityId string = beIdentity.id
output bePrincipalId string = beIdentity.properties.principalId
output workerIdentityId string = workerIdentity.id
output workerPrincipalId string = workerIdentity.properties.principalId

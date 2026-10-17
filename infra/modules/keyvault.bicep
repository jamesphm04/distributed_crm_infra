@description('Azure region for every resource.')
param location string

@description('Short workload name used in resource names.')
param workload string

@description('Environment name used in resource names, e.g. dev.')
param environmentName string

@description('Tags applied to every resource.')
param tags object

@description('Principal IDs of the app identities allowed to read secrets.')
param secretReaderPrincipalIds string[]

// Built-in roles. Role definition IDs are the same in every Azure tenant.
var secretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6' // Key Vault Secrets User: read secret values
var secretsOfficerRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7' // Key Vault Secrets Officer: create, update, delete secrets

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-${workload}-${environmentName}-${take(uniqueString(resourceGroup().id), 8)}'
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    softDeleteRetentionInDays: 7
  }
}

resource appReaders 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in secretReaderPrincipalIds: {
    name: guid(vault.id, principalId, secretsUserRoleId)
    scope: vault
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', secretsUserRoleId)
      principalId: principalId
      principalType: 'ServicePrincipal'
    }
  }
]

resource deployerOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, deployer().objectId, secretsOfficerRoleId)
  scope: vault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', secretsOfficerRoleId)
    principalId: deployer().objectId
  }
}

output name string = vault.name
output uri string = vault.properties.vaultUri

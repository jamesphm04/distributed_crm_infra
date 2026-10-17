@description('Azure region for every resource.')
param location string

@description('Short workload name used in resource names.')
param workload string

@description('Environment name used in resource names, e.g. dev.')
param environmentName string

@description('Tags applied to every resource.')
param tags object

@description('Principal IDs of the identities allowed to use the cache.')
param userPrincipalIds string[]

resource cache 'Microsoft.Cache/redisEnterprise@2025-07-01' = {
  name: 'redis-${workload}-${environmentName}-${take(uniqueString(resourceGroup().id), 8)}'
  location: location
  tags: tags
  sku: {
    name: 'Balanced_B0'
  }
  properties: {
    highAvailability: 'Disabled'
    publicNetworkAccess: 'Enabled'
    minimumTlsVersion: '1.2'
  }
}

resource database 'Microsoft.Cache/redisEnterprise/databases@2025-07-01' = {
  parent: cache
  name: 'default'
  properties: {
    clientProtocol: 'Encrypted'
    port: 10000
    clusteringPolicy: 'EnterpriseCluster'
    evictionPolicy: 'NoEviction'
    accessKeysAuthentication: 'Disabled'
  }
}

resource accessAssignments 'Microsoft.Cache/redisEnterprise/databases/accessPolicyAssignments@2025-07-01' = [
  for principalId in userPrincipalIds: {
    parent: database
    name: take(replace(principalId, '-', ''), 60)
    properties: {
      accessPolicyName: 'default'
      user: {
        objectId: principalId
      }
    }
  }
]

output name string = cache.name
output host string = cache.properties.hostName

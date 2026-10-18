@description('Azure region for every resource.')
param location string

@description('Short workload name used in resource names.')
param workload string

@description('Environment name used in resource names, e.g. dev.')
param environmentName string

@description('Tags applied to every resource.')
param tags object

@description('Name of the application database.')
param databaseName string

@description('Name of the migration job identity, made a second Entra admin.')
param migrateIdentityName string

@description('Principal ID of the migration job identity.')
param migratePrincipalId string

resource server 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: 'psql-${workload}-${environmentName}-${take(uniqueString(resourceGroup().id), 8)}'
  location: location
  tags: tags
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  properties: {
    version: '17'
    storage: {
      storageSizeGB: 32
      autoGrow: 'Disabled'
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
    authConfig: {
      activeDirectoryAuth: 'Enabled'
      passwordAuth: 'Disabled'
      tenantId: tenant().tenantId
    }
    network: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// The person or pipeline running the deploy becomes the Entra admin, who creates the app roles with SQL.
resource entraAdmin 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2024-08-01' = {
  parent: server
  name: deployer().objectId
  properties: {
    principalName: deployer().userPrincipalName
    principalType: 'User'
    tenantId: tenant().tenantId
  }
}

// The migration job runs every deploy's schema changes and creates the apps' roles, both of which need an admin.
resource migrateAdmin 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2024-08-01' = {
  parent: server
  name: migratePrincipalId
  properties: {
    principalName: migrateIdentityName
    principalType: 'ServicePrincipal'
    tenantId: tenant().tenantId
  }
  dependsOn: [
    entraAdmin
  ]
}

// 0.0.0.0 to 0.0.0.0 is Azure's special rule for "allow connections from Azure services".
// A Flexible Server applies one change at a time, so its child resources are chained with dependsOn instead of running in parallel.
resource allowAzureServices 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2024-08-01' = {
  parent: server
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
  dependsOn: [
    migrateAdmin
  ]
}

resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: server
  name: databaseName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
  dependsOn: [
    allowAzureServices
  ]
}

output serverName string = server.name
output host string = server.properties.fullyQualifiedDomainName
output databaseName string = database.name

@description('Azure region for every resource.')
param location string

@description('Short workload name used in resource names.')
param workload string

@description('Environment name used in resource names, e.g. dev.')
param environmentName string

@description('Tags applied to every resource.')
param tags object

@description('Principal IDs of the identities allowed to send to the queue.')
param senderPrincipalIds string[]

@description('Principal IDs of the identities allowed to receive from the queue.')
param receiverPrincipalIds string[]

// Built-in roles. Role definition IDs are the same in every Azure tenant.
var dataSenderRoleId = '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39' // Azure Service Bus Data Sender
var dataReceiverRoleId = '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0' // Azure Service Bus Data Receiver

resource namespace 'Microsoft.ServiceBus/namespaces@2024-01-01' = {
  name: 'sb-${workload}-${environmentName}-${take(uniqueString(resourceGroup().id), 8)}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
  properties: {
    disableLocalAuth: true
    minimumTlsVersion: '1.2'
  }
}

// Matches servicebus/Config.json, which the local emulator reads.
resource queue 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' = {
  parent: namespace
  name: 'return-requests'
  properties: {
    lockDuration: 'PT1M'
    maxDeliveryCount: 5
    defaultMessageTimeToLive: 'PT1H'
    deadLetteringOnMessageExpiration: true
    requiresDuplicateDetection: true
    duplicateDetectionHistoryTimeWindow: 'PT5M'
    requiresSession: false
  }
}

resource senders 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in senderPrincipalIds: {
    name: guid(queue.id, principalId, dataSenderRoleId)
    scope: queue
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', dataSenderRoleId)
      principalId: principalId
      principalType: 'ServicePrincipal'
    }
  }
]

resource receivers 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in receiverPrincipalIds: {
    name: guid(queue.id, principalId, dataReceiverRoleId)
    scope: queue
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', dataReceiverRoleId)
      principalId: principalId
      principalType: 'ServicePrincipal'
    }
  }
]

output namespaceName string = namespace.name
output fullyQualifiedNamespace string = '${namespace.name}.servicebus.windows.net'

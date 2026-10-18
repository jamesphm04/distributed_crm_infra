targetScope = 'subscription'

@description('Principal ID of the GitHub Actions identity.')
param principalId string

// Built-in role "Reader": the pipelines read the dev stack's outputs (IDs and host names, no secrets), and a
// subscription-level deployment stack can only be read with a role at subscription scope.
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'

resource subscriptionReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, principalId, readerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

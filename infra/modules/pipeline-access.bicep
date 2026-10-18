@description('Principal ID of the GitHub Actions identity.')
param pipelinePrincipalId string

// Built-in role "Contributor" on this resource group only: push images to the registry, deploy the Container Apps
// and the migration job, start the job. It can't grant roles, so it can't widen its own or the apps' access.
var contributorRoleId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'

resource pipelineContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, pipelinePrincipalId, contributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', contributorRoleId)
    principalId: pipelinePrincipalId
    principalType: 'ServicePrincipal'
  }
}

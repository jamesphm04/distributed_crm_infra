targetScope = 'subscription'

// The GitHub Actions identity. Kept out of the dev stack so its client ID survives every teardown and rebuild of
// the environment, and the IDs stored in GitHub never change. An identity costs nothing.

@description('Azure region for every resource.')
param location string

@description('Short workload name used in resource names.')
param workload string

@description('Tags applied to every resource.')
param tags object

@description('GitHub account that owns the repos.')
param githubOwner string

@description('Repos whose workflows may sign in, each from its "dev" GitHub environment.')
param githubRepos string[]

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${workload}-cicd'
  location: location
  tags: tags
}

module identity 'identity.bicep' = {
  name: 'pipelineIdentity'
  scope: rg
  params: {
    location: location
    workload: workload
    tags: tags
    githubOwner: githubOwner
    githubRepos: githubRepos
  }
}

module subscriptionReader 'subscription-reader.bicep' = {
  name: 'pipelineSubscriptionReader'
  params: {
    principalId: identity.outputs.principalId
  }
}

output pipelineClientId string = identity.outputs.clientId
output pipelinePrincipalId string = identity.outputs.principalId

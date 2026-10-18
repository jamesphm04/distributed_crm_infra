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

resource pipeline 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${workload}-github'
  location: location
  tags: tags
}

// Trust GitHub's OIDC token for a job in the repo's "dev" environment, and nothing else: not other repos, not other
// branches' jobs without that environment, not pull requests from forks.
// One at a time: an identity rejects concurrent writes to its federated credentials.
@batchSize(1)
resource githubTrust 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = [
  for repo in githubRepos: {
    parent: pipeline
    name: 'github-${repo}-dev'
    properties: {
      issuer: 'https://token.actions.githubusercontent.com'
      subject: 'repo:${githubOwner}/${repo}:environment:dev'
      audiences: [
        'api://AzureADTokenExchange'
      ]
    }
  }
]

output clientId string = pipeline.properties.clientId
output principalId string = pipeline.properties.principalId

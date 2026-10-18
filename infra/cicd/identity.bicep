@description('Azure region for every resource.')
param location string

@description('Short workload name used in resource names.')
param workload string

@description('Tags applied to every resource.')
param tags object

@description('GitHub account that owns the repos, and its numeric ID.')
param githubOwner githubAccount

@description('Repos whose workflows may sign in, each from its "dev" GitHub environment.')
param githubRepos githubAccount[]

type githubAccount = {
  name: string
  id: int
}

resource pipeline 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${workload}-github'
  location: location
  tags: tags
}

// Trust GitHub's OIDC token for a job in the repo's "dev" environment, and nothing else: not other repos, not other
// branches' jobs without that environment, not pull requests from forks.
// The subject is GitHub's immutable format, repo:<owner>@<owner id>/<repo>@<repo id>:environment:<name>. The IDs
// never change, so a deleted repo re-created under the same name, or a taken-over username, can't match it.
// One at a time: an identity rejects concurrent writes to its federated credentials.
@batchSize(1)
resource githubTrust 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = [
  for repo in githubRepos: {
    parent: pipeline
    name: 'github-${repo.name}-dev'
    properties: {
      issuer: 'https://token.actions.githubusercontent.com'
      subject: 'repo:${githubOwner.name}@${githubOwner.id}/${repo.name}@${repo.id}:environment:dev'
      audiences: [
        'api://AzureADTokenExchange'
      ]
    }
  }
]

output clientId string = pipeline.properties.clientId
output principalId string = pipeline.properties.principalId

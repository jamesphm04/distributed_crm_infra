using 'main.bicep'

param location = 'australiaeast'
param workload = 'dcrm'
param tags = {
  project: 'distributed-crm'
  purpose: 'demo'
  owner: 'james'
}
// Numeric IDs are public; look them up with: gh api repos/<owner>/<repo> --jq '.owner.id, .id'
param githubOwner = {
  name: 'jamesphm04'
  id: 153576708
}
param githubRepos = [
  {
    name: 'distributed_crm_be'
    id: 1369763321
  }
  {
    name: 'distributed_crm_worker'
    id: 1369764964
  }
]

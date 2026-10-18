using 'main.bicep'

param location = 'australiaeast'
param workload = 'dcrm'
param tags = {
  project: 'distributed-crm'
  purpose: 'demo'
  owner: 'james'
}
param githubOwner = 'jamesphm04'
// The worker's GitHub repo is named distributed_crm_etl.
param githubRepos = [
  'distributed_crm_be'
  'distributed_crm_etl'
]

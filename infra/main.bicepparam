using 'main.bicep'

param location = 'australiaeast'
param workload = 'dcrm'
param environmentName = 'dev'
param tags = {
  project: 'distributed-crm'
  purpose: 'demo'
  owner: 'james'
}

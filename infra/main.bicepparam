using 'main.bicep'

param location = 'australiaeast'
param workload = 'dcrm'
param environmentName = 'dev'
param tags = {
  project: 'distributed-crm'
  purpose: 'demo'
  owner: 'james'
}

// Read from the environment so the ID isn't committed; deploy.sh sets it from the dcrm-cicd stack's output.
param pipelinePrincipalId = readEnvironmentVariable('PIPELINE_PRINCIPAL_ID')

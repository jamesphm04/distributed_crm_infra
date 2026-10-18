using 'main.bicep'

param location = 'australiaeast'
param workload = 'dcrm'
param environmentName = 'dev'
param tags = {
  project: 'distributed-crm'
  purpose: 'demo'
  owner: 'james'
}

// 0.5 GB normally. Raised to 5 GB for the Phase 15 load tests and the demo (about AUD 4-5 per GB ingested); set it
// back to '0.5' after the demo.
param logDailyCapGb = '5'

// Read from the environment so the ID isn't committed; deploy.sh sets it from the dcrm-cicd stack's output.
param pipelinePrincipalId = readEnvironmentVariable('PIPELINE_PRINCIPAL_ID')

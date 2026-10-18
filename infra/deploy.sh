#!/usr/bin/env bash
# Plans, creates or deletes everything in main.bicep as one deployment stack (dcrm-dev). The GitHub Actions
# identity lives in a second stack (dcrm-cicd, cicd/main.bicep) that "up" creates or updates and "down" leaves alone,
# so the IDs stored in GitHub stay valid across teardowns.
set -euo pipefail

subscription="distributed-crm-sandbox"
location="australiaeast"
stack="dcrm-dev"
params="$(dirname "$0")/main.bicepparam"
cicd_stack="dcrm-cicd"
cicd_params="$(dirname "$0")/cicd/main.bicepparam"
# Local, gitignored, and also what docker compose reads. The source of the values copied into Key Vault.
env_file="$(dirname "$0")/../.env"

# Every resource provider the templates use, directly or as a side effect (App Insights creates a
# Failure Anomalies alert rule through Microsoft.AlertsManagement). A new subscription has most of them off.
providers=(
  Microsoft.App Microsoft.Cache Microsoft.DBforPostgreSQL Microsoft.ServiceBus Microsoft.KeyVault
  Microsoft.ContainerRegistry Microsoft.OperationalInsights Microsoft.Insights Microsoft.ManagedIdentity
  Microsoft.AlertsManagement
)

# Prints one output of a subscription-level stack, or nothing if the stack doesn't exist.
stack_output() {
  az stack sub show --subscription "$subscription" --name "$1" \
    --query "outputs.$2.value || properties.outputs.$2.value" -o tsv 2>/dev/null || true
}

# main.bicepparam reads the pipeline's principal ID from the environment.
load_pipeline_principal() {
  PIPELINE_PRINCIPAL_ID="$(stack_output "$cicd_stack" pipelinePrincipalId)"
  if [[ -z "$PIPELINE_PRINCIPAL_ID" ]]; then
    echo "The $cicd_stack stack doesn't exist yet; run '$0 up' (or '$0 cicd') first." >&2
    exit 1
  fi
  export PIPELINE_PRINCIPAL_ID
}

cicd() {
  az stack sub create --subscription "$subscription" --location "$location" \
    --name "$cicd_stack" --parameters "$cicd_params" \
    --action-on-unmanage deleteAll --deny-settings-mode none --yes --output none

  # The three values each app repo stores as GitHub secrets. IDs, not credentials: sign-in is OIDC.
  echo "GitHub secrets for distributed_crm_be and distributed_crm_etl:"
  echo "  AZURE_CLIENT_ID=$(stack_output "$cicd_stack" pipelineClientId)"
  echo "  AZURE_TENANT_ID=$(az account show --subscription "$subscription" --query tenantId -o tsv)"
  echo "  AZURE_SUBSCRIPTION_ID=$(az account show --subscription "$subscription" --query id -o tsv)"
}

plan() {
  load_pipeline_principal
  az deployment sub what-if --subscription "$subscription" --location "$location" \
    --name "$stack" --parameters "$params"
}

register_providers() {
  local provider
  for provider in "${providers[@]}"; do
    if [[ "$(az provider show --subscription "$subscription" -n "$provider" --query registrationState -o tsv)" != "Registered" ]]; then
      echo "Registering $provider (one-time, takes a few minutes)..."
      az provider register --subscription "$subscription" -n "$provider" --wait
    fi
  done
}

# Prints one KEY=value from .env without running the file as a script.
env_value() {
  local value
  value="$(grep -E "^$1=" "$env_file" | tail -1 | cut -d= -f2-)"
  value="${value%\"}"; value="${value#\"}"
  if [[ -z "$value" ]]; then
    echo "Set $1 in $env_file." >&2
    exit 1
  fi
  printf '%s' "$value"
}

# Copies be's Google sign-in settings into Key Vault, where its Container App reads them. They aren't in the repo
# (the allowed email is personal data), and a purged vault loses them, so every "up" sets them again.
set_app_secrets() {
  local vault attempt
  vault="$(stack_output "$stack" keyVaultName)"

  # The value goes through a file descriptor rather than the command line, which other processes can read.
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if az keyvault secret set --subscription "$subscription" --vault-name "$vault" --name google-client-id \
        --file <(env_value GOOGLE_CLIENT_ID) --output none 2>/dev/null \
      && az keyvault secret set --subscription "$subscription" --vault-name "$vault" --name allowed-email-0 \
        --file <(env_value ALLOWED_EMAIL) --output none 2>/dev/null; then
      echo "Key Vault secrets set in $vault."
      return
    fi
    # A role assignment can take a few minutes to apply, and the deployer's Secrets Officer role is brand new.
    echo "Key Vault not writable yet (attempt $attempt of 10), waiting for the role assignment to apply..."
    sleep 30
  done
  echo "Couldn't set the Key Vault secrets; check the Key Vault Secrets Officer assignment." >&2
  exit 1
}

up() {
  register_providers
  env_value GOOGLE_CLIENT_ID >/dev/null
  env_value ALLOWED_EMAIL >/dev/null
  cicd
  load_pipeline_principal
  az stack sub create --subscription "$subscription" --location "$location" \
    --name "$stack" --parameters "$params" \
    --action-on-unmanage deleteAll --deny-settings-mode none --yes --output none
  set_app_secrets
}

down() {
  local vault
  vault="$(stack_output "$stack" keyVaultName)"

  az stack sub delete --subscription "$subscription" --name "$stack" \
    --action-on-unmanage deleteAll --yes

  # A deleted vault keeps its name for the soft-delete period; purging frees it for the next "up".
  if [[ -n "$vault" ]]; then
    az keyvault purge --subscription "$subscription" --name "$vault"
  fi
}

case "${1:-}" in
  plan) plan ;;
  up) up ;;
  down) down ;;
  cicd) cicd ;;
  *)
    echo "Usage: $0 plan|up|down|cicd" >&2
    exit 2
    ;;
esac

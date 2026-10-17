#!/usr/bin/env bash
# Plans, creates or deletes everything in main.bicep as one deployment stack.
set -euo pipefail

subscription="distributed-crm-sandbox"
location="australiaeast"
stack="dcrm-dev"
params="$(dirname "$0")/main.bicepparam"

# Every resource provider the templates use, directly or as a side effect (App Insights creates a
# Failure Anomalies alert rule through Microsoft.AlertsManagement). A new subscription has most of them off.
providers=(
  Microsoft.App Microsoft.Cache Microsoft.DBforPostgreSQL Microsoft.ServiceBus Microsoft.KeyVault
  Microsoft.ContainerRegistry Microsoft.OperationalInsights Microsoft.Insights Microsoft.ManagedIdentity
  Microsoft.AlertsManagement
)

plan() {
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

up() {
  register_providers
  az stack sub create --subscription "$subscription" --location "$location" \
    --name "$stack" --parameters "$params" \
    --action-on-unmanage deleteAll --deny-settings-mode none --yes
}

down() {
  local vault
  vault="$(az stack sub show --subscription "$subscription" --name "$stack" \
    --query "outputs.keyVaultName.value || properties.outputs.keyVaultName.value" -o tsv)"

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
  *)
    echo "Usage: $0 plan|up|down" >&2
    exit 2
    ;;
esac

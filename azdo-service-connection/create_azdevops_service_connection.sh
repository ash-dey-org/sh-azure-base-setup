#!/bin/bash
# Script to create Azure DevOps service connection using workload federated identity
# Usage: ./create_azdevops_service_connection.sh <azure_ad_app_client_id> <azure_ad_app_object_id> <azure_devops_org> <azure_devops_project> <app_service_name> <subscription_id> <subscription_name> <tenant_id>

set -e

CLIENT_ID="$1"
OBJECT_ID="$2"
AZDO_ORG="$3"
AZDO_PROJECT="$4"
APP_SERVICE_NAME="$5"
SUBSCRIPTION_ID="$6"
SUBSCRIPTION_NAME="$7"
TENANT_ID="$8"

if [ "$#" -ne 8 ]; then
  echo "Usage: $0 <azure_ad_app_client_id> <azure_ad_app_object_id> <azure_devops_org> <azure_devops_project> <app_service_name> <subscription_id> <subscription_name> <tenant_id>"
  exit 1
fi

# Step 2: Create federated credential for Azure DevOps pipeline
FEDERATED_CREDENTIAL_NAME="azdo-federated-cred-$APP_SERVICE_NAME"
ISSUER="https://token.actions.githubusercontent.com"
SUBJECT="repo:${AZDO_ORG}/${AZDO_PROJECT}:ref:refs/heads/main"

az rest --method post \
  --url "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID/federatedIdentityCredentials" \
  --body "{\n    \"name\": \"$FEDERATED_CREDENTIAL_NAME\",\n    \"issuer\": \"$ISSUER\",\n    \"subject\": \"$SUBJECT\",\n    \"description\": \"Federated credential for Azure DevOps pipeline\"\n  }"

echo "Federated credential created."

# Step 3 & 4: Create Azure DevOps service connection
SERVICE_CONNECTION_NAME="azdo-service-conn-$APP_SERVICE_NAME"

az devops service-endpoint azurerm create \
  --azure-rm-service-principal-id "$CLIENT_ID" \
  --azure-rm-subscription-id "$SUBSCRIPTION_ID" \
  --azure-rm-subscription-name "$SUBSCRIPTION_NAME" \
  --azure-rm-tenant-id "$TENANT_ID" \
  --name "$SERVICE_CONNECTION_NAME" \
  --org "https://dev.azure.com/$AZDO_ORG" \
  --project "$AZDO_PROJECT" \
  --service-principal-type "federated"

echo "Service connection '$SERVICE_CONNECTION_NAME' created in Azure DevOps project '$AZDO_PROJECT'."

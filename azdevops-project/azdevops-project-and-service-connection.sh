#!/usr/bin/env bash
set -euo pipefail

echo "======================================================"
echo " Azure DevOps Project & Permissions Bootstrap Script"
echo "======================================================"
echo
echo "This script will:"
echo "  - Create an Azure DevOps project (if it does not already exist)"
echo "  - Create an Administrator Team"
echo "  - Add the Admin team to Project Administrators"
echo "  - Add the default Project Team to Contributors"
echo "  - Check for existing project and skip creation if found"
echo "  - Create federated credentials for Azure AD apps using workload identity"
echo "  - Accept all required values as command-line arguments (no interactive prompts)"
echo "  - Support creation of multiple federated credentials for different app services"
echo
echo "Usage: $0 <project_name> <tenant_id> <subscription_id> <subscription_name> <app_service_name1> [<app_service_name2> ...]"
echo
echo "Required environment variables:"
echo "  ORG_URL   -> Azure DevOps organization URL"
echo "              e.g. https://dev.azure.com/myorg"
echo "  AZDO_PAT  -> Azure DevOps Personal Access Token"
echo
echo "Prerequisites:"
echo "  - Azure CLI logged in (az login)"
echo "  - azure-devops extension installed"
echo "  - jq installed"
echo "------------------------------------------------------"
echo

# -----------------------------
# Validate environment variables
# -----------------------------
if [[ -z "${ORG_URL:-}" ]]; then
  echo "❌ ERROR: ORG_URL environment variable is not set"
  exit 1
fi

if [[ -z "${AZDO_PAT:-}" ]]; then
  echo "❌ ERROR: AZDO_PAT environment variable is not set"
  exit 1
fi

export AZURE_DEVOPS_EXT_PAT="$AZDO_PAT"

# -----------------------------
# Parse arguments
# -----------------------------
if [[ $# -lt 5 ]]; then
  echo "Usage: $0 <project_name> <tenant_id> <subscription_id> <subscription_name> <app_service_name1>"
  exit 1
fi

PROJECT_NAME="$1"
TENANT_ID="$2"
SUBSCRIPTION_ID="$3"
SUBSCRIPTION_NAME="$4"
APP_SERVICE_NAME="$5"

# Check if project already exists
PROJECT_EXISTS=$(az devops project show --project "$PROJECT_NAME" --organization "$ORG_URL" --output json 2>/dev/null | jq -r '.id // empty')
# PROJECT_EXISTS=$(az devops project show --project "$PROJECT_NAME" --organization "$ORG_URL")
# echo $PROJECT_EXISTS

if [[ -n "$PROJECT_EXISTS" ]]; then
  echo "✔ Project '$PROJECT_NAME' already exists. Skipping project creation."
else
  read -rp "Enter Project Description: " PROJECT_DESC
  if [[ -z "$PROJECT_DESC" ]]; then
    echo "❌ ERROR: Project description must not be empty"
    exit 1
  fi
  echo
  echo "------------------------------------------------------"
  echo " Organization : $ORG_URL"
  echo " Project Name : $PROJECT_NAME"
  echo " Description  : $PROJECT_DESC"
  echo "------------------------------------------------------"
  echo
  read -rp "Continue? (y/n): " CONFIRM
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted by user."
    exit 0
  fi

  # -----------------------------
  # Create Project
  # -----------------------------
  echo
  echo "▶ Creating project..."

  PROJECT_ID=$(az devops project create \
    --name "$PROJECT_NAME" \
    --description "$PROJECT_DESC" \
    --visibility private \
    --organization "$ORG_URL" \
    --output json | jq -r '.id')

  echo "✔ Project created (ID: $PROJECT_ID)"

  # -----------------------------
  # Get Project Groups
  # -----------------------------
  echo
  echo "▶ Fetching project groups..."

  GROUPS=$(az devops security group list \
    --project "$PROJECT_NAME" \
    --organization "$ORG_URL" \
    --output json)

  PROJECT_ADMINS_DESC=$(echo "$GROUPS" | jq -r '.graphGroups[] | select(.displayName=="Project Administrators") | .descriptor')
  CONTRIBUTORS_DESC=$(echo "$GROUPS" | jq -r '.graphGroups[] | select(.displayName=="Contributors") | .descriptor')

  # -----------------------------
  # Get Default Project Team
  # -----------------------------
  echo
  echo "▶ Fetching default project team..."

  PROJECT_TEAM_ID=$(az devops team list \
    --project "$PROJECT_NAME" \
    --organization "$ORG_URL" \
    --output json | jq -r ".[] | select(.name==\"$PROJECT_NAME Team\") | .id")

  PROJECT_TEAM_DESC=$(az devops team show \
    --team-id "$PROJECT_TEAM_ID" \
    --project "$PROJECT_NAME" \
    --organization "$ORG_URL" \
    --output json | jq -r '.identity.descriptor')

  # -----------------------------
  # Create Admin Team
  # -----------------------------
  ADMIN_TEAM_NAME="$PROJECT_NAME Administrator Team"

  echo
  echo "▶ Creating admin team: $ADMIN_TEAM_NAME"

  ADMIN_TEAM_ID=$(az devops team create \
    --name "$ADMIN_TEAM_NAME" \
    --project "$PROJECT_NAME" \
    --organization "$ORG_URL" \
    --output json | jq -r '.id')

  ADMIN_TEAM_DESC=$(az devops team show \
    --team-id "$ADMIN_TEAM_ID" \
    --project "$PROJECT_NAME" \
    --organization "$ORG_URL" \
    --output json | jq -r '.identity.descriptor')

  # -----------------------------
  # Add Admin Team to Project Administrators
  # -----------------------------
  echo
  echo "▶ Adding admin team to Project Administrators..."

  az devops security group membership add \
    --group-id "$PROJECT_ADMINS_DESC" \
    --member-id "$ADMIN_TEAM_DESC" \
    --organization "$ORG_URL"

  # -----------------------------
  # Add Default Project Team to Contributors
  # -----------------------------
  echo
  echo "▶ Adding project team to Contributors..."

  az devops security group membership add \
    --group-id "$CONTRIBUTORS_DESC" \
    --member-id "$PROJECT_TEAM_DESC" \
    --organization "$ORG_URL"
fi

# -----------------------------
# Service Connection Setup (Federated Identity)
# -----------------------------

# APP_SERVICE_NAME="${APP_SERVICE_NAMES[0]}"
echo
echo "--- Federated Credential Creation for '$APP_SERVICE_NAME' ---"
# Resolve OBJECT_ID from APP_SERVICE_NAME
OBJECT_ID=$(jq -r .[].appId <<< "$(az ad sp list --display-name "$APP_SERVICE_NAME")")
if [[ -z "$OBJECT_ID" ]]; then
  echo "❌ ERROR: Could not resolve OBJECT_ID for app service name '$APP_SERVICE_NAME'"
  exit 1
fi

FEDERATED_CREDENTIAL_NAME="azdo-federated-cred-$APP_SERVICE_NAME"
ISSUER="https://vstoken.dev.azure.com/167b8081-a938-405a-99e0-41cba4a4deee"
ORG_NAME=$(basename "$ORG_URL")
SERVICE_CONNECTION_NAME="azdo-service-conn-$APP_SERVICE_NAME"
SUBJECT="sc://$ORG_NAME/$PROJECT_NAME/$SERVICE_CONNECTION_NAME"

# Check if federated credential already exists
json_array=$(az ad app federated-credential list --id "$OBJECT_ID")
fc_id_plan=$(echo "$json_array" | jq --arg fc_name_plan "$FEDERATED_CREDENTIAL_NAME" '.[] | select(.name == $fc_name_plan) | .name')
if [[ $fc_id_plan != "\"$FEDERATED_CREDENTIAL_NAME\"" ]]; then
  echo "Creating federated credential $FEDERATED_CREDENTIAL_NAME"
  cat > credential.json <<EOF
{
  "name": "$FEDERATED_CREDENTIAL_NAME",
  "issuer": "$ISSUER",
  "subject": "$SUBJECT",
  "description": "Federated credential for Azure DevOps pipeline",
  "audiences": ["api://AzureADTokenExchange"]
}
EOF
  az ad app federated-credential create --id "$OBJECT_ID" --parameters credential.json
  echo "Federated credential created."
  echo "Federated credential for '$APP_SERVICE_NAME' created in Azure AD app."
  rm -f credential.json
else
  echo "Federated Credential $FEDERATED_CREDENTIAL_NAME exists, skipping step...."
fi

# -----------------------------
# Azure DevOps Service Connection (Azure Resource Manager)
# -----------------------------

echo
echo "--- Setting up Azure DevOps Service Connection for Azure Resource Manager ---"
sleep 10 # Sleep to ensure federated credential is fully propagated in Azure AD before creating service connection

SERVICE_CONNECTION_NAME="azdo-service-conn-$APP_SERVICE_NAME"

echo
echo "--- Creating Azure DevOps Service Connection for Azure Resource Manager (Federated Identity, REST API) ---"

# Prepare service connection payload
cat > service-connection.json <<EOF
{
  "data": {
    "subscriptionId": "$SUBSCRIPTION_ID",
    "subscriptionName": "$SUBSCRIPTION_NAME",
    "tenantId": "$TENANT_ID",
    "servicePrincipalId": "$OBJECT_ID",
    "authenticationType": "federated"
  },
  "name": "$SERVICE_CONNECTION_NAME",
  "type": "azurerm",
  "authorization": {
    "scheme": "Federated",
    "parameters": {
      "servicePrincipalId": "$OBJECT_ID",
      "tenantId": "$TENANT_ID",
      "subscriptionId": "$SUBSCRIPTION_ID"
    }
  }
}
EOF

SERVICE_CONNECTION_URL="${ORG_URL%/}/$PROJECT_NAME/_apis/serviceendpoint/endpoints?api-version=7.1-preview.4"
echo "[Diagnostics] ORG_URL: $ORG_URL"
echo "[Diagnostics] PROJECT_NAME: $PROJECT_NAME"
echo "[Diagnostics] SERVICE_CONNECTION_URL: $SERVICE_CONNECTION_URL"
echo "[Diagnostics] AZDO_PAT (length): ${#AZDO_PAT}"
echo "[Diagnostics] service-connection.json contents:"
cat service-connection.json

RESPONSE=$(curl -v -X POST "$SERVICE_CONNECTION_URL" \
  -H "Content-Type: application/json" \
  -H "Authorization: Basic $(echo -n :$AZDO_PAT | base64)" \
  --data-binary @service-connection.json)

if echo "$RESPONSE" | grep -q 'id'; then
  echo "Service connection '$SERVICE_CONNECTION_NAME' created in Azure DevOps project '$PROJECT_NAME'."
else
  echo "Failed to create service connection. Response: $RESPONSE"
fi

rm -f service-connection.json

#!/usr/bin/env bash

set -euo pipefail



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

if [[ -z "${ORG_ID:-}" ]]; then
  echo "❌ ERROR: ORG_ID environment variable is not set"
  exit 1
fi

export AZURE_DEVOPS_EXT_PAT="$AZDO_PAT"

# -----------------------------
# Parse arguments and extract Azure context
# -----------------------------
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <project_name> <app_service_name1>"
  echo
  echo "=========================================================================="
  echo " Azure DevOps Project, Permissions and Service Connection Bootstrap Script"
  echo "=========================================================================="
  echo
  echo "This script will:"
  echo "  - Create an Azure DevOps project (if it does not already exist)"
  echo "  - Create an Administrator Team and add to Project Administrators"
  echo "  - Add the default Project Team to Contributors"
  echo "  - Check for existing project and skip creation if found"
  echo "  - Create federated credentials for Azure AD apps using workload identity"
  echo "  - Dynamically generate service connection using JSON files with runtime values (no hardcoded secrets)"
  echo "  - Accept only project name and app service name as command-line arguments (no interactive prompts except project description/confirmation)"
  echo "  - Remove the JSON files after use"
  echo
  echo "Usage: $0 <devops_project_name> <app_service_name>"
  echo
  echo "Required environment variables:"
  echo "  ORG_URL   -> Azure DevOps organization URL (e.g. https://dev.azure.com/myorg)"
  echo "  AZDO_PAT  -> Azure DevOps Personal Access Token"
  echo "  ORG_ID    -> Azure DevOps organization ID. It can be retrived from below url"
  echo "               https://dev.azure.com/{your_organization}/_apis/projects/{your_project}?api-version=7.2-preview"
  echo
  echo "Prerequisites:"
  echo "  - Azure CLI logged in (az login)"
  echo "  - azure-devops extension installed (az extension add --name azure-devops)"
  echo "  - jq installed (sudo apt install jq)"
  echo "------------------------------------------------------"
  echo
  exit 1
fi

PROJECT_NAME="$1"
APP_SERVICE_NAME="$2"

# Extract Azure context automatically
TENANT_ID=$(az account show --query tenantId -o tsv)
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
if [[ -z "$TENANT_ID" || -z "$SUBSCRIPTION_ID" || -z "$SUBSCRIPTION_NAME" ]]; then
  echo "❌ ERROR: Failed to extract Azure context (tenantId, subscriptionId, subscriptionName) from az CLI. Ensure you are logged in."
  exit 1
fi

# Check if project already exists
PROJECT_EXISTS=$(az devops project show --project "$PROJECT_NAME" --organization "$ORG_URL" --output json 2>/dev/null | jq -r '.id // empty')

if [[ -n "$PROJECT_EXISTS" ]]; then
  echo "✔ Project '$PROJECT_NAME' already exists. Skipping project creation."
  PROJECT_ID="$PROJECT_EXISTS"
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

echo
echo "--- Federated Credential Creation for '$APP_SERVICE_NAME' ---"
# Resolve APP_ID from APP_SERVICE_NAME
APP_ID=$(jq -r .[].appId <<< "$(az ad sp list --display-name "$APP_SERVICE_NAME")")
if [[ -z "$APP_ID" ]]; then
  echo "❌ ERROR: Could not resolve APP_ID for app service name '$APP_SERVICE_NAME'"
  exit 1
fi

FEDERATED_CREDENTIAL_NAME="azdo-federated-cred-$APP_SERVICE_NAME"
# Dynamically get Azure DevOps org ID from project metadata (collection.href)
# ORG_ID=$(curl -s -H "Authorization: Basic $(echo -n :$AZDO_PAT | base64)" "${ORG_URL%/}/_apis/projects/$PROJECT_NAME?api-version=7.2-preview" | jq -r '.collection.href | capture("/projectCollections/(?<orgid>[^/]+)") | .orgid')
if [[ -z "$ORG_ID" || "$ORG_ID" == "null" ]]; then
  echo "❌ ERROR: Could not retrieve Azure DevOps organization ID from project metadata ($ORG_URL, $PROJECT_NAME)"
  exit 1
fi
ISSUER="https://vstoken.dev.azure.com/$ORG_ID"
ORG_NAME=$(basename "$ORG_URL")
SERVICE_CONNECTION_NAME="sc-$APP_SERVICE_NAME"
SUBJECT="sc://$ORG_NAME/$PROJECT_NAME/$SERVICE_CONNECTION_NAME"

# Check if federated credential already exists
json_array=$(az ad app federated-credential list --id "$APP_ID")
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
  az ad app federated-credential create --id "$APP_ID" --parameters credential.json
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

# -----------------------------
# Generate ServiceConnectionGeneric.json dynamically
# -----------------------------

SERVICE_CONNECTION_GENERIC_JSON="ServiceConnectionGeneric.json"

cat > "$SERVICE_CONNECTION_GENERIC_JSON" <<EOF
{
  "data": {
    "subscriptionId": "$SUBSCRIPTION_ID",
    "subscriptionName": "$SUBSCRIPTION_NAME",
    "environment": "AzureCloud",
    "scopeLevel": "Subscription",
    "creationMode": "Manual"
  },
  "name": "$SERVICE_CONNECTION_NAME",
  "type": "AzureRM",
  "url": "https://management.azure.com/",
  "authorization": {
    "parameters": {
      "tenantid": "$TENANT_ID",
      "serviceprincipalid": "$APP_ID"
    },
    "scheme": "WorkloadIdentityFederation"
  },
  "isShared": false,
  "isReady": true,
  "serviceEndpointProjectReferences": [
    {
      "projectReference": {
        "id": "$PROJECT_ID",
        "name": "$PROJECT_NAME"
      },
      "name": "$SERVICE_CONNECTION_NAME"
    }
  ]
}
EOF

sleep 10 # Sleep to ensure federated credential is fully propagated in Azure AD before creating service connection

SERVICE_CONNECTION_NAME="sc-$APP_SERVICE_NAME"

echo
echo "--- Creating Azure DevOps Service Connection for Azure Resource Manager (Federated Identity, REST API) ---"

# Create service connection using az cli with the generated JSON
echo "▶ Creating Azure DevOps service connection from ServiceConnectionGeneric.json..."
SERVICE_CONN_OUTPUT=$(az devops service-endpoint create --service-endpoint-configuration ./ServiceConnectionGeneric.json --organization "$ORG_URL" --project "$PROJECT_NAME" 2>&1)
EXIT_CODE=$?
if [[ $EXIT_CODE -ne 0 ]]; then
  echo "❌ ERROR: Failed to create service connection. Output:"
  echo "$SERVICE_CONN_OUTPUT"
  rm -f "$SERVICE_CONNECTION_GENERIC_JSON"
  exit $EXIT_CODE
else
  echo "✔ Service connection created successfully."
fi
# Remove ServiceConnectionGeneric.json after use
if rm -f "$SERVICE_CONNECTION_GENERIC_JSON"; then
  echo "✔ ServiceConnectionGeneric.json deleted."
else
  echo "⚠️ WARNING: Failed to delete ServiceConnectionGeneric.json. Please remove manually."
fi

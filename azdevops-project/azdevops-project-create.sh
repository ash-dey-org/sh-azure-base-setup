#!/usr/bin/env bash
set -euo pipefail

echo "======================================================"
echo " Azure DevOps Project & Permissions Bootstrap Script"
echo "======================================================"
echo
echo "This script will:"
echo "  - Create an Azure DevOps project"
echo "  - Create an Administrator Team"
echo "  - Add the Admin team to Project Administrators"
echo "  - Add the default Project Team to Contributors"
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
# Prompt user for input
# -----------------------------
read -rp "Enter Project Name: " PROJECT_NAME
read -rp "Enter Project Description: " PROJECT_DESC

if [[ -z "$PROJECT_NAME" || -z "$PROJECT_DESC" ]]; then
  echo "❌ ERROR: Project name and description must not be empty"
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

echo
echo "======================================================"
echo "✔ Azure DevOps project setup completed successfully"
echo "======================================================"

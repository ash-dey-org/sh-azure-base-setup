#!/bin/bash

set -euo pipefail

# ------------------------------------------------------------
# This script:
#  1) Takes: <sp_name> <rg_name> <tfc_prj_name> <tfc_workspace_name>
#  2) Creates az RG, creates aad SP, assigns constrained permission,
#     creates federated credentials for Terraform Cloud
#  3) Assigns constrained Role Based Access Control Administrator role
#     to the RG if RG exists, else creates RG and assigns permission
#
# Requirements:
#  - bash, jq, az
#  - Azure CLI logged in and able to query subscription and service principal:
#      az login
#      az account show
#      az ad sp list --display-name ...
#
# Required env vars:
#  - TF_CLOUD_ORGANIZATION
#
# Usage:
#  $0 "<sp_name>" "<rg_name>" "<tfc_prj_name>" "<tfc_workspace_name>"
# ------------------------------------------------------------

SP_NAME="${1:-}"
RG_NAME="${2:-}"
TFC_PRJ_NAME="${3:-}"
TFC_WORKSPACE_NAME="${4:-}"

if [[ -z "${SP_NAME}" || -z "${RG_NAME}" || -z "${TFC_PRJ_NAME}" || -z "${TFC_WORKSPACE_NAME}" ]]; then
    clear
    echo ""
    echo "------------------------------------------------------------"
    echo "This script:"
    echo "  1) Takes arguments: <sp_name> <rg_name> <tfc_prj_name> <tfc_workspace_name>"
    echo "  2) Creates az RG, creates aad SP, assigns constrained permission, creates federated credentials for Terraform Cloud"
    echo "  3) Assigns constrained Role Based Access Control Administrator role to RG if RG exists, else creates RG and assigns permission"
    echo ""
    echo "Requirements:"
    echo "  - bash, jq, az cli installed"
    echo "  - Azure CLI logged in and default subscription set and able to query/modify service principal:"
    echo "      az login"
    echo "      az account set --subscription <subscription_id>"
    echo "  - Resource groups will be created in the default subscription of the logged in Azure CLI account"
    echo ""
    echo "Required env vars:"
    echo "  - TF_CLOUD_ORGANIZATION"
    echo ""
    echo "Usage:"
    echo "  $0 \"<sp_name>\" \"<rg_name>\" \"<tfc_prj_name>\" \"<tfc_workspace_name>\""
    echo "------------------------------------------------------------"
    exit 2
fi

: "${TF_CLOUD_ORGANIZATION:?Environment variable must be set before running the script}"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required software: $1" >&2; exit 3; }; }
need_cmd jq
need_cmd az

# check if Resource group exists
if [[ "$(az group exists --name "$RG_NAME")" == "true" ]]; then
    echo "Resource Group $RG_NAME already exists"
    subs_id=$(jq -r .id <<< "$(az account show)")
else
    echo "Resource Group $RG_NAME does not exist"
    read -r -p "Enter the Azure region (AustraliaEast|AustraliaSouthEast) to create resource group: " location
    read -r -p "Enter the tag for Environment (dev|test|uat|prod|bcp-prod): " environment
    read -r -p "Enter the tag for App name: " app
    read -r -p "Enter the tag for Owner (IT Infra team): " owner
    echo "Creating Resource Group $RG_NAME in region $location"
    rg_output=$(jq -r .id <<< "$(az group create --name "$RG_NAME" --location "$location" --tags Environment="$environment" App="$app" Owner="$owner")")
    subs_id=$(echo "$rg_output" | cut -d/ -f3)
    # create cannot delete lock for the resource group
    # az group lock create --lock-type CanNotDelete -n "$RG_NAME-lock" -g "$RG_NAME"
fi

# Function to ensure constrained RBAC administrator role is assigned and direct roles are granted
assign_roles_to_sp() {
    local appId="$1"
    local subs_id="$2"
    local rg_name="$3"
    local scope="/subscriptions/$subs_id/resourceGroups/$rg_name"

    local rbac_admin_role="Role Based Access Control Administrator"

    # Direct roles for the SP itself
    local direct_roles=(
        "Contributor"
        "App Configuration Data Owner"
        "Key Vault Secrets Officer"
    )

    # Roles this SP is allowed to assign to others
    local allowed_roles=(
        "App Configuration Data Owner"
        "Key Vault Secrets Officer"
        "Storage Blob Data Contributor"
    )

    declare -A role_guid_map
    local role
    local role_guid
    local ids_csv=""

    echo "Resolving role definition GUIDs for allowed roles..."

    for role in "${allowed_roles[@]}"; do
        role_guid=$(az role definition list --name "$role" --query '[0].name' -o tsv)
        if [[ -z "$role_guid" ]]; then
            echo "ERROR: failed to resolve role definition GUID for role: $role" >&2
            exit 1
        fi
        role_guid_map["$role"]="$role_guid"
        echo " - $role -> $role_guid"
        ids_csv="${ids_csv}${role_guid}, "
    done

    ids_csv="${ids_csv%, }"

    local condition="((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${ids_csv}})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${ids_csv}}))"

    echo "Checking existing '$rbac_admin_role' assignment..."
    local existing_assignment_id
    local existing_condition

    existing_assignment_id=$(az role assignment list \
        --scope "$scope" \
        --assignee "$appId" \
        --role "$rbac_admin_role" \
        --query '[0].id' -o tsv)

    existing_condition=$(az role assignment list \
        --scope "$scope" \
        --assignee "$appId" \
        --role "$rbac_admin_role" \
        --query '[0].condition' -o tsv)

    if [[ -n "$existing_assignment_id" ]]; then
        if [[ "$existing_condition" == "$condition" ]]; then
            echo "Constrained '$rbac_admin_role' already present with expected condition"
        else
            echo "Updating '$rbac_admin_role' condition"
            az role assignment update \
                --ids "$existing_assignment_id" \
                --condition "$condition" \
                --condition-version "2.0"
        fi
    else
        echo "Creating constrained '$rbac_admin_role' assignment"
        az role assignment create \
            --assignee "$appId" \
            --role "$rbac_admin_role" \
            --scope "$scope" \
            --condition "$condition" \
            --condition-version "2.0"
    fi

    echo "Ensuring direct role assignments..."
    for role in "${direct_roles[@]}"; do
        assigned=$(az role assignment list \
            --assignee "$appId" \
            --scope "$scope" \
            --role "$role" \
            --query '[0].roleDefinitionName' -o tsv)

        if [[ "$assigned" == "$role" ]]; then
            echo " - Role '$role' already assigned"
        else
            echo " - Assigning direct role '$role'"
            az role assignment create \
                --assignee "$appId" \
                --role "$role" \
                --scope "$scope"
        fi
    done
}

# check if service principal exists
if [[ "$(az ad sp list --display-name "$SP_NAME")" != '[]' ]]; then
    echo "Service Principal $SP_NAME already exists, checking role assignment"
    appId=$(jq -r '.[].appId' <<< "$(az ad sp list --display-name "$SP_NAME")")
    assign_roles_to_sp "$appId" "$subs_id" "$RG_NAME"
else
    echo "Service Principal $SP_NAME does not exist"
    echo "Creating service principal $SP_NAME"
    sp_create_output=$(az ad sp create-for-rbac -n "$SP_NAME" --only-show-errors)
    appId=$(jq -r .appId <<< "$sp_create_output")
    assign_roles_to_sp "$appId" "$subs_id" "$RG_NAME"
fi

fc_name_plan="fc-$RG_NAME-tf-plan"
fc_name_apply="fc-$RG_NAME-tf-apply"
fc_desc="Federated credential for Terraform for RG $RG_NAME"
issuer="https://app.terraform.io"
subject_plan="organization:$TF_CLOUD_ORGANIZATION:project:$TFC_PRJ_NAME:workspace:$TFC_WORKSPACE_NAME:run_phase:plan"
subject_apply="organization:$TF_CLOUD_ORGANIZATION:project:$TFC_PRJ_NAME:workspace:$TFC_WORKSPACE_NAME:run_phase:apply"
audiences='["api://AzureADTokenExchange"]'

# set parameters for terraform run phase plan
plan=$(cat <<EOL
{
    "name": "$fc_name_plan",
    "issuer": "$issuer",
    "subject": "$subject_plan",
    "description": "$fc_desc plan",
    "audiences": $audiences
}
EOL
)

# set parameters for terraform run phase apply
apply=$(cat <<EOL
{
    "name": "$fc_name_apply",
    "issuer": "$issuer",
    "subject": "$subject_apply",
    "description": "$fc_desc apply",
    "audiences": $audiences
}
EOL
)

objId=$(jq -r '.[].appId' <<< "$(az ad sp list --display-name "$SP_NAME")")

# check if the federated credential already exists for plan
json_array=$(az ad app federated-credential list --id "$objId")
fc_existing_plan=$(echo "$json_array" | jq -r \
    --arg issuer "$issuer" \
    --arg subject "$subject_plan" \
    '.[] | select(.issuer == $issuer and .subject == $subject) | .name' | head -n 1)

if [[ -n "$fc_existing_plan" ]]; then
    echo "Federated credential already exists for PLAN (name: $fc_existing_plan). Skipping this step."
else
    echo "Creating federated credential $fc_name_plan"
    az ad app federated-credential create --id "$objId" --parameters "$plan"
fi

# check if the federated credential already exists for apply
json_array=$(az ad app federated-credential list --id "$objId")
fc_existing_apply=$(echo "$json_array" | jq -r \
    --arg issuer "$issuer" \
    --arg subject "$subject_apply" \
    '.[] | select(.issuer == $issuer and .subject == $subject) | .name' | head -n 1)

if [[ -n "$fc_existing_apply" ]]; then
    echo "Federated credential already exists for APPLY (name: $fc_existing_apply). Skipping this step."
else
    echo "Creating federated credential $fc_name_apply"
    az ad app federated-credential create --id "$objId" --parameters "$apply"
fi
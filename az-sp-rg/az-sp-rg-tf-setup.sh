#!/bin/bash

set -euo pipefail

# ------------------------------------------------------------
# This script:
#  1) Takes: <sp_name> <rg_name> <tfc_prj_name> <tfc_workspace_name>
#  2) Creates az RG, creates aad SP, assigns permission, creates federated credentials for Terraform Cloud
#  3) Assigns SP owner role to RG if RG exists, else creates RG and assigns permission
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
    echo "  2) Creates az RG, creates aad SP, assigns permission, creates federated credentials for Terraform Cloud"
    echo "  3) Assigns SP owner role to RG if RG exists, else creates RG and assigns permission"
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
if [ $(az group exists --name $RG_NAME) = true ]

    then
        echo Resource Group $RG_NAME already exists
        # echo "Extracting subscription id"
        subs_id=$(jq -r .id <<< "$(az account show)")

# create resource group
    else
        echo "Resource Group $RG_NAME does not exist"
        read -p "Enter the Azure region (AustraliaEast|AustraliaSouthEast) to create resource group: " location
        read -p "Enter the tag for Environment (dev|test|uat|prod|bcp-prod): " environment
        read -p "Enter the tag for App name: " app
        read -p "Enter the tag for Owner (IT Infra team): " owner
        echo creating Resource Group $RG_NAME in region $location
        rg_output=$(jq -r .id <<< "$(az group create --name $RG_NAME --location $location --tags Environment=$environment App=$app Owner=$owner)")
        subs_id=$(echo $rg_output | cut -d/ -f3)
        # create cannot delete lock for the reosurce group
        # az group lock create --lock-type CanNotDelete -n $RG_NAME-lock -g $RG_NAME
fi


# Function to ensure all required roles are assigned to a service principal
assign_roles_to_sp() {
    local appId="$1"
    local subs_id="$2"
    local rg_name="$3"
    local roles=("Owner" "App Configuration Data Owner" "Key Vault Secrets Officer")
    declare -A role_assigned
    for role in "${roles[@]}"; do
        assigned=$(az role assignment list --resource-group "$rg_name" --assignee "$appId" --role "$role" | jq -r '.[].roleDefinitionName')
        if [[ $assigned == "$role" ]]; then
            role_assigned[$role]=true
        else
            role_assigned[$role]=false
        fi
    done
    all_roles_assigned=true
    for role in "${roles[@]}"; do
        if [[ ${role_assigned[$role]} == false ]]; then
            all_roles_assigned=false
            break
        fi
    done
    if $all_roles_assigned; then
        echo "All required roles already assigned"
    else
        echo "Assigning missing roles to service principal"
        for role in "${roles[@]}"; do
            if [[ ${role_assigned[$role]} == false ]]; then
                echo "Assigning $role role"
                az role assignment create --assignee "$appId" --role "$role" --scope /subscriptions/$subs_id/resourceGroups/$rg_name
            fi
        done
    fi
}

# check if service principal exists
if [[ $(az ad sp list --display-name $SP_NAME) != '[]' ]]; then
    echo "Service Principal $SP_NAME already exists, checking if role assignment exists"
    appId=$(jq -r .[].appId <<< "$(az ad sp list --display-name $SP_NAME)")
    assign_roles_to_sp "$appId" "$subs_id" "$RG_NAME"
else
    echo "Service Principal $SP_NAME does not exist"
    echo "Creating service principal $SP_NAME"
    sp_create_output=$(az ad sp create-for-rbac -n $SP_NAME --role Owner --scopes /subscriptions/$subs_id/resourceGroups/$RG_NAME --only-show-errors)
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

objId=$(jq -r .[].appId <<< "$(az ad sp list --display-name $SP_NAME)")
json_array=$(az ad app federated-credential list --id $objId)

fc_id_plan=$(echo "$json_array" | jq  --arg fc_name_plan "$fc_name_plan" '.[] | select(.name == $fc_name_plan) | .name')

#check if the federated credential already exists for plan
if [[ $fc_id_plan != "\"$fc_name_plan\"" ]]
    then
        echo "Creating federated ceredential $fc_name_plan"
        az ad app federated-credential create --id $objId --parameters "$plan"

    else
        echo "Federated Credential $fc_name_plan exists, skipping step...."
fi


fc_id_apply=$(echo "$json_array" | jq  --arg fc_name_apply "$fc_name_apply" '.[] | select(.name == $fc_name_apply) | .name')

#check if the federated credential already exists for apply
if [[ $fc_id_apply != "\"$fc_name_apply\"" ]]
    then
        echo "Creating federated ceredential $fc_name_apply"
        az ad app federated-credential create --id $objId --parameters "$apply"
    else
        echo "Federated Credential $fc_name_apply exists, skipping step...."

fi


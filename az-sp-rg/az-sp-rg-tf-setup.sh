#!/bin/bash
# Check 4 arguments are passed with the script

## TO DO
## why role assignment of the RG not lisitng correctly

if [ $# -ne 4 ]; then
    clear
    echo "Usage : $0 SP_name RG_name tfc_prj_name tfc_workspace_name"
    echo
    echo "Assumption: environment variable TF_CLOUD_ORGANIZATION is avilable"
    echo "This script requires 4 arguments and a few other inputs e.g. RG location, mandatory tags etc""
    echo "creates az RG, creates aad SP, assigns permission, creates federated credentials for Terraform Cloud"
    echo
    echo "1. Display name of the Azure service principal (e.g. tf-<env>-sp-<app>-<VS-AD>)"
    echo "2. Name of the Azure resource group (e.g. IT-DEV-XXX-RG)"
    echo "3. Terraform cloud app-project name (e.g. prj-xxx-xxx)"
    echo "4. Terraform cloud app-workspace name (e.g. xxx-xxx-dev)"
    echo
    echo "if the resource group already exists, it will assign SP contributor role to RG"
    echo "if the resource group does not exist, then it will create resources and assign permission"
    echo
    echo "requires environemnt variable TF_CLOUD_ORGANIZATION"
    echo "requires default subscription set (az account set --subscription xxxx)"
    exit 0
fi


# check if Resource group exists
if [ $(az group exists --name $2) = true ]

    then
        echo Resource Group $2 already exists
        # echo "Extracting subscription id"
        subs_id=$(jq -r .id <<< "$(az account show)")

# create resource group
    else
        echo "Resource Group $2 does not exist"
        read -p "Enter the Azure region (AustraliaEast|AustraliaSouthEast) to create resource group: " location
        read -p "Enter the tag for Environment (dev|test|uat|prod|bcp-prod): " environment
        read -p "Enter the tag for App name: " app
        read -p "Enter the tag for Owner (IT Infra team): " owner
        echo creating Resource Group $2 in region $location
        rg_output=$(jq -r .id <<< "$(az group create --name $2 --location $location --tags Environment=$environment App=$app Owner=$owner)")
        subs_id=$(echo $rg_output | cut -d/ -f3)
        # create cannot delete lock for the reosurce group
        # az group lock create --lock-type CanNotDelete -n $2-lock -g $2
fi

# check if service principal exists
if [[ $(az ad sp list --display-name $1) != '[]' ]]
# if az ad sp list --display-name $1 | grep -Pq '"displayName":'
    then
        echo "Service Principal $1 already exists, checking if role assignment exists"
        appId=$(jq -r .[].appId <<< "$(az ad sp list --display-name $1)")
        RGappID=$(jq -r ".[] | select(.principalName==\"$appId\") | .principalName" <<< "$(az role assignment list --resource-group $2)")
        # echo RG appId $RGappID
        if [[ $RGappID = $appId ]]
            then
                echo "role assignement already exists"

            else
                echo "role assignement does not exist, creating role assignment"
                az role assignment create --assignee $appId --role Contributor --scope /subscriptions/$subs_id/resourceGroups/$2
                # az role assignment list --resource-group $2
        fi

    else
        echo "Service Principal $1 does not exist"
        echo "creating service principal $1 and assigning permission"
        az ad sp create-for-rbac -n $1 --role Contributor --scopes /subscriptions/$subs_id/resourceGroups/$2
fi


fc_name_plan="fc-$2-tf-plan"
fc_name_apply="fc-$2-tf-apply"
fc_desc="Federated credential for Terraform for RG $2"
issuer="https://app.terraform.io"
subject_plan="organization:$TF_CLOUD_ORGANIZATION:project:$3:workspace:$4:run_phase:plan"
subject_apply="organization:$TF_CLOUD_ORGANIZATION:project:$3:workspace:$4:run_phase:apply"
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

objId=$(jq -r .[].appId <<< "$(az ad sp list --display-name $1)")
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


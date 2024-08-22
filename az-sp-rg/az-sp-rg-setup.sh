#!/bin/bash
# Check 4 arguments are passed with the script

## TO DO
## why role assignment of the RG not lisitng correctly

if [ $# -ne 2 ]; then
    clear
    echo "Usage : $0 SP_name RG_name"
    echo
    echo "This script requires 2 arguments"
    echo "creates az RG, creates aad SP, assigns permission"
    echo
    echo "1. Display name of the Azure service principal (e.g. tf-np-sp-xxx-VS-AD)"
    echo "2. Name of the Azure resource group (e.g. IT-DEV-XXX-RG)"
    echo
    echo "if the resource group already exists, it will assign SP contributor role to RG"
    echo "if the resource group does not exist, then it will create resources and assign permission"
    echo
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
        read -p "Enter the tag for Environment: " environment
        read -p "Enter the tag for App name: " app
        read -p "Enter the tag for Owner: " owner
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



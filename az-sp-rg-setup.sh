#!/bin/bash
# Check 3 arguments are passed with the script

if [ $# -ne 2 ]; then
    echo "Usage : $0 SP_name RG_name RG_location"
    echo
    echo "This script requires two arguments"
    echo "The first argument - display name of the Azure service principal (tf-np-sp-xxx-VS-AD)"
    echo "The second argument - name of the Azure resource group (d-auea-sa-rg-xxxx)"
    echo "if the resources already exist, it will assign SP contributor role to RG"
    echo "if the resources does not exist, then it will create resources and assign permission"
    exit 0
fi


if [ $(az group exists --name $2) = true ]

    then
        echo Resource Group $2 already exists
        echo "Extracting subscription id"
        subs_id=$(jq -r .id <<< "$(az account show)")

    else
        echo "Resource Group $2 does not exist"
        read -p "Enter the Azure region (AustraliaEast|AustraliaSouthEast) to create resource group: " location
        echo creating Resource Group $2 in region $location
        # rg_output=$(jq -r .id <<< "$(az group create --name $2 --location $location)")
        # subs_id=$(echo $rg_output | cut -d/ -f3)
fi


if [[ $(az ad sp list --display-name $1) != '[]' ]]
# if az ad sp list --display-name $1 | grep -Pq '"displayName":'
    then
        echo "Service Principal $1 already exists, assigning permission"
        # az role assignment create --assignee $1 --role Contributor --scope /subscriptions/$subs_id/resourceGroups/$2

    else
        echo "Service Principal $1 does not exist"
        echo "creating service principal $1 and assigning permission"
        # az ad sp create-for-rbac -n $1 --role Contributor --scopes /subscriptions/$subs_id/resourceGroups/$2
fi





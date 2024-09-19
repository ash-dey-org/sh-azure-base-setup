#!/bin/bash
# Check 4 arguments are passed with the script

## TO DO
##

if [ $# -ne 4 ]; then
    clear
    echo "Usage : $0 entra_sp_name github_org_name github_repo_name github_branch_name"
    echo
    echo "This script requires 4 arguments"
    echo "Creates federated credential for github actions to deploy code to Azure form a specifc branch"
    echo
    echo "1. Display name of the Azure service principal (e.g. devops-dev-xxx-sp)"
    echo "2. Github organisation name (e.g. Standards-Australia)"
    echo "3. Github repo name (e.g. Store)"
    echo "4. Repo branch name (e.g. develop/test/uat/main)"
    echo
    echo "if the service principal already exists, it will created federated credential to sp"
    echo "if the service principal does not exist, it will create the sp and create federated credential to sp"
    echo
    echo "MUST LOGIN TO AZURE BEFORE RUNNING THIS SCRIPT"
    echo "az login"
    exit 0
fi

# check if service principal exists
if [[ $(az ad sp list --display-name $1) != '[]' ]]
# if az ad sp list --display-name $1 | grep -Pq '"displayName":'
    then
        echo "Service Principal $1 already exists, checking if federated credential exists"
        appId=$(jq -r .[].appId <<< "$(az ad sp list --display-name $1)")
    else
        echo "Service Principal $1 does not exist"
        echo "creating service principal $1 and assigning permission"
        az ad sp create-for-rbac -n $1
fi

# Variables - update these according to your environment
SP_ID=$(jq -r .[].appId <<< "$(az ad sp list --display-name $1)")       # The Object ID of the Service Principal
GH_REPO="$2/$3"        # GitHub owner/repo (e.g., owner/repo)
CRED_NAME="GitHubFederatedCredential-$3-$4"       # Federated credential name

# Azure login (uncomment if not already logged in)
# az login

# Check if the federated credential already exists
existing_cred=$(az ad app federated-credential list --id $SP_ID --query "[?name=='$CRED_NAME']" -o tsv)

if [ -n "$existing_cred" ]; then
    echo "Federated credential '$CRED_NAME' already exists."
else
    echo "Federated credential '$CRED_NAME' does not exist. Creating it now."

    # Create federated credential for GitHub Actions
    az ad app federated-credential create \
        --id $SP_ID \
        --parameters '{
          "name": "'$CRED_NAME'",
          "issuer": "https://token.actions.githubusercontent.com",
          "subject": "repo:'$GH_REPO':ref:refs/heads/'$4'",
          "description": "Federated credential for Github Actions for '$3' repo '$4' branch",
          "audiences": ["api://AzureADTokenExchange"]
        }'

    echo "Federated credential '$CRED_NAME' created for GitHub Actions."
fi

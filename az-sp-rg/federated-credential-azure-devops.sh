#!/bin/bash
# set default organization
# az devops configure --defaults organization=https://dev.azure.com/xxxx


## TO DO
##

if [ $# -ne 3 ]; then
    clear
    echo "Usage : $0 entra_sp_name Azure_resource_group_name azure_devops_project_name"
    echo
    echo "This script requires 3 arguments"
    echo "Creates federated credential and Azure devops service connection to deploy code to Azure"
    echo
    echo "1. Display name of the Azure service principal (e.g. devops-dev-store-sp)"
    echo "2. Azure Resource Group name (e.g. it-dev-store-rg)"
    echo "3. Azure devops project name (e.g. 'Standards Store')"
    echo
    echo "If the service principal already exists, it will add the federated credential to service principal"
    echo "If the service principal does not exist, it will create the sp and add federated credential to sp"
    echo "It will also create a service connection in Azure devops to deploy code to Azure"
    echo
    echo "MUST LOGIN TO AZURE AND EXPORT ENVIRONMENT VARIABLE & AZURE_DEVOPS_EXT_PAT"
    echo "az login"
    echo ". ~/scripts/_export_IT_Non_Prod.sh or . ~/scripts/_export_IT_Prod.sh"
    echo "export AZURE_DEVOPS_EXT_PAT="xxxx""
    echo "Default organization must be set using 'az devops configure --defaults organization=https://dev.azure.com/xxx'"
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

# Function to URL encode the project name
urlencode() {
    local encoded=""
    local length="${#1}"
    for (( i = 0; i < length; i++ )); do
        local c="${1:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) encoded+="$c" ;;
            ' ') encoded+="%20" ;; # Handles space specifically
            *) encoded+=$(printf '%%%02X' "'$c") ;;
        esac
    done
    echo "$encoded"
}

# Capture the project name from the first script argument
project_name="$3"
sp_name="$1"

# URL encode the project name
project_name_encoded=$(urlencode "$project_name")
# Define the API URL with the user input project name
api_url="https://dev.azure.com/standardsaus/_apis/projects/$project_name_encoded?api-version=7.1-preview.4"
# echo $api_url

# Call the API and extract the id from the JSON response
project_id=$(curl -s -u :$AZURE_DEVOPS_EXT_PAT $api_url | jq -r '.id')
# response=$(curl -s -u :$PAT $api_url)
# echo "$response"
# Check if the project_id is not empty
if [[ -n "$project_id" ]]; then
    echo "Azure devops project ID: $project_id"
else
    echo "Error: Could not fetch the Azure devops project ID. Please check the project name."
    exit 1
fi

# Variables - update these according to your environment
SP_ID=$(jq -r .[].appId <<< "$(az ad sp list --display-name $1)")       # The Object ID of the Service Principal
# TENANT_ID = $(az account show --query tenantId -o tsv)                # The Tenant ID of your Azure AD
# resource_path = $(az group show --name "$2" --query id -o tsv)
# SUBSCRIPTION_ID = $(echo $resource_path | awk -F'/' '{print $3}')
ADO_PROJECT=$3       # Azure DevOps project (e.g., myproject)
RG_NAME=$2
CRED_NAME="fc-$2-az-devops"
SC_NAME="$2-sc"
l
parameters=$(jq -n \
  --arg name "$CRED_NAME" \
  --arg issuer "$ADO_ISSUER" \
  --arg subject "sc://$ADO_ORG/$ADO_PROJECT/$SC_NAME" \
  --arg description "Federated credential for Azure Devops for RG $2" \
  '{
    name: $name,
    issuer: $issuer,
    subject: $subject,
    description: $description,
    audiences: ["api://AzureADTokenExchange"]
  }')


# Check if the federated credential already exists
existing_cred=$(az ad app federated-credential list --id $SP_ID --query "[?name=='$CRED_NAME']" -o tsv)

if [ -n "$existing_cred" ]; then
    echo "Federated credential '$CRED_NAME' already exists."
else
    echo "Federated credential '$CRED_NAME' does not exist. Creating it now."

    # Create federated credential for Azure devops
    az ad app federated-credential create --id "$SP_ID" --parameters "$parameters"
    echo "Federated credential '$CRED_NAME' created for Azure devops."
fi

echo "Creating Azure Devops service connection......."
echo "ALLOW SOME TIME FOR FEDERATED CREDENTIAL TO PROPAGATE"
read -p "Press enter to continue"

# create azure devops service endpoint


# Use sed to replace other variables in the template file
sed -e "s|\${project_id}|$project_id|g" \
    -e "s|\${SC_NAME}|$SC_NAME|g" \
    -e "s|\${SP_ID}|$SP_ID|g" \
    -e "s|\${ADO_PROJECT}|$ADO_PROJECT|g" \
    -e "s|\${sp_name}|$sp_name|g" \
    -e "s|\${ADO_ISSUER}|$ADO_ISSUER|g" \
    -e "s|\${ADO_ORG}|$ADO_ORG|g" \
    devops.json.template > devops.json.temp

# substitute the environmental variables in the temp file
envsubst < devops.json.temp > devops.json

echo $ADO_PROJECT
az devops service-endpoint create --service-endpoint-configuration ./devops.json --org https://dev.azure.com/$ADO_ORG --project "$ADO_PROJECT" --debug
rm devops.json
rm devops.json.temp
# Use envsubst to replace placeholders in devops.json with environment variables
# envsubst < ./devops.json | az devops service-endpoint create --service-endpoint-configuration /dev/stdin


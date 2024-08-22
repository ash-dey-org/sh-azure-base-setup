#!/bin/bash


if [ $# -ne 2 ]; then
    clear
    echo "Usage : $0 kv_name file_name"
    echo
    echo "This script requires 2 arguments"
    echo "Imports key vault secrtes from a file containing comman separated values: Keyname,secretvalue"
    echo
    echo "1. Display name of the key valut"
    echo "2. full path fo the file containing secret"
    echo
    echo "requires default subscription set (az account set --subscription xxxx)"
    exit 0
fi


# Set your Azure Key Vault name
vaultName=$1

# Path to your text file containing secrets
secretsFile=$2

# Loop through each line in the text file
while IFS=',' read -r secretName secretValue; do
    # Import the secret into Azure Key Vault
    az keyvault secret set --vault-name $vaultName --name $secretName --value "$secretValue"

    echo "Imported secret: $secretName"
done < "$secretsFile"

echo "All secrets imported successfully."

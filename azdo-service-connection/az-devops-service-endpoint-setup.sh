#!/bin/bash
# Check 1 argument is passed with the script

if [ $# -ne 6 ]; then
    clear
    echo "Usage : $0 app_client_id az_subs_id az_subs_name tenant_id svc_connection_name az_devops_prj_name"
    echo
    echo "This script will add an azurerm service connection to azure devops project"
    echo "This script requires 6 arguments"
    echo
    echo "Use double quote if there is a space in names e.g. \"IT Non-Production\" or \"Reader Room\""
    echo
    echo "you must login to azure devop"
    echo "az devops login --organization https://dev.azure.com/xxx"

    exit 0
fi


prj_name=$(az devops project show --project "$6" | jq -r '.name')


if [ "$prj_name" != "$6" ];

    then
        echo project $6 does not exist
        exit 0

    else
        # echo "Project $6 exisits, provide more input for the service connection"
        az devops service-endpoint azurerm create --azure-rm-service-principal-id "$1" --azure-rm-subscription-id "$2" --azure-rm-subscription-name "$3" --azure-rm-tenant-id "$4" --name "$5" --project "$6"
fi

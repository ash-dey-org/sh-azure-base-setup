### Setup of service connection in Azure DEVOPS project.

##### Script usage:
```
script_name <app_client_id> <az_subs_id>
<az_subs_name> <tenant_id> <svc_connection_name> <az_devops_prj_name>
```
##### More information:
This script will add an azurerm service connection to azure devops project
This script requires 6 arguments

Use double quote if there is a space in names e.g. "IT Non-Production" or "Reader Room"


##### Dependency:
you must login to azure devops using cli before executing the script, it will prompt for PAT
```
az devops login --organization https://dev.azure.com/xxx
```

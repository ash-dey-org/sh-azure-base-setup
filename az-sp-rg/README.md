### Setup of az Resource Group and service principal for terraform cloud to deploy resources.

</br>
##### script usage:
<script_name> <Service_Principal_name> <Resource_Group_name>

</br>
##### More information
Creates Azure Resource Group, if it does not exist already.
Creates Service Principal (rbac), if it does not exist already.
Assigns contributor role to service principal to the resource group.

</br>
##### Dependency
Requires log into azure subscription using az cli before running the script
$ az login
\$ az account set --subscription <subs_id>

### Used for initial setup of Azure Resource Group before Terraform Cloud can be used to deploy resources.


script usage:
<script_name> <Service_Principal_name> <Resource_Group_name>

Creates Azure Resource Group, if it does not exist already.
Creates Service Principal (rbac), if it does not exist already.
Assigns contributor role to service principal to the resource group.



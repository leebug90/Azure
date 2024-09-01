# Getting arguments
RG=$1

# Create a ssh key
az sshkey create --name "mySSHKey" --resource-group "$RG"

# Save a public key
result=$(az sshkey show --name "mySSHKey" --resource-group "$RG")
echo $result > $AZ_SCRIPTS_OUTPUT_PATH


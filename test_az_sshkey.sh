# Getting arguments
RG=$1

# Create a ssh key
az sshkey create --name "mySSHKey" --resource-group "$RG"

# Save a public key
myPubKey=$(az sshkey show --name "mySSHKey" --resource-group "$RG" --query "publicKey")

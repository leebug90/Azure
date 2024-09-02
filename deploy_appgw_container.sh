# Pass all arguments to variables
AKS_NAME=$1
IDENTITY_RESOURCE_NAME=$2
RESOURCE_GROUP=$3
VNET_NAME=$4
ALB_SUBNET_NAME=$5 
ALB_Version=$6

echo "data from arguments ==> $AKS_NAME $IDENTITY_RESOURCE_NAME $RESOURCE_GROUP $VNET_NAME $ALB_SUBNET_NAME $ALB_Version"
echo "Install kubectl.."
az aks install-cli --only-show-errors
sleep 5

# Create a user managed identity for ALB controller and federate the identity as Workload identity to use in AKS cluster
mcResourceGroup=$(az aks show --resource-group $RESOURCE_GROUP --name $AKS_NAME --query "nodeResourceGroup" -o tsv)
mcResourceGroupId=$(az group show --name $mcResourceGroup --query id -o tsv)

#echo "Creating identity $IDENTITY_RESOURCE_NAME in resource group $RESOURCE_GROUP"
#az identity create --resource-group $RESOURCE_GROUP --name $IDENTITY_RESOURCE_NAME
principalId="$(az identity show -g $RESOURCE_GROUP -n $IDENTITY_RESOURCE_NAME --query principalId -o tsv)"

echo "Waiting 60 seconds to allow for replication of the identity..."
sleep 60

echo "Apply Reader role to the AKS managed cluster resource group for the newly provisioned identity"
#az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --scope $mcResourceGroupId --role "acdd72a7-3385-48ef-bd42-f606fba81ae7" # Reader role

echo "Set up federation with AKS OIDC issuer"
AKS_OIDC_ISSUER="$(az aks show -n "$AKS_NAME" -g "$RESOURCE_GROUP" --query "oidcIssuerProfile.issuerUrl" -o tsv)"
az identity federated-credential create --name "azure-alb-identity" \
    --identity-name "$IDENTITY_RESOURCE_NAME" \
    --resource-group $RESOURCE_GROUP \
    --issuer "$AKS_OIDC_ISSUER" \
    --subject "system:serviceaccount:azure-alb-system:alb-controller-sa"

# Install ALB controller in the default namespaces 
#   - default for helm chart & azure-alb-sytem for ALB controller

# otherwise, use the options
# --namespace <helm-resource-namespace>
# --set albController.namespace=<alb-controller-namespace>

# Install Helm
echo "Installing Helm..."
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
sleep 5

echo "login to AKS cluster to use kubctl"
az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_NAME --overwrite-existing

helm install alb-controller oci://mcr.microsoft.com/application-lb/charts/alb-controller \
     --version $ALB_Version \
     --set albController.podIdentity.clientID=$(az identity show -g $RESOURCE_GROUP -n azure-alb-identity --query clientId -o tsv)

echo "Wait for 10 seconds after installing ALB controller..."
sleep 10

# Delegate a subnet to association resource
#az network vnet subnet update --resource-group $RESOURCE_GROUP --name $ALB_SUBNET_NAME --vnet-name $VNET_NAME --delegations 'Microsoft.ServiceNetworking/trafficControllers'
ALB_SUBNET_ID=$(az network vnet subnet list --resource-group $RESOURCE_GROUP --vnet-name $VNET_NAME --query "[?name=='$ALB_SUBNET_NAME'].id" --output tsv)
echo "ALB subnet ID==> $ALB_SUBNET_ID"


# Delegate AppGw for Containers Configuration Manager role to AKS Managed Cluster RG
#az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --scope $mcResourceGroupId --role "fbc52c3f-28ad-4303-a892-8a056630b8f1" 

# Delegate Network Contributor permission for join to association subnet
#az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --scope $ALB_SUBNET_ID --role "4d97b98b-1d4f-4787-a291-c67834d212e7" 

# Create ApplicationLoadBalancer Kubernetes resource
command="kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: alb-test-infra
EOF"
az aks command invoke --name $AKS_NAME --resource-group $RESOURCE_GROUP --command "$command"


command="kubectl apply -f - <<EOF
apiVersion: alb.networking.azure.io/v1
kind: ApplicationLoadBalancer
metadata:
  name: alb-test
  namespace: alb-test-infra
spec:
  associations:
  - $ALB_SUBNET_ID
EOF"
az aks command invoke --name $AKS_NAME --resource-group $RESOURCE_GROUP --command "$command"

# Deploy sample HTTP application
command="kubectl apply -f https://trafficcontrollerdocs.blob.core.windows.net/examples/https-scenario/ssl-termination/deployment.yaml"
az aks command invoke --name $AKS_NAME --resource-group $RESOURCE_GROUP --command "$command"

# Deploy the required Gateway API resources
command="kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: gateway-01
  namespace: test-infra
  annotations:
    alb.networking.azure.io/alb-namespace: alb-test-infra
    alb.networking.azure.io/alb-name: alb-test
spec:
  gatewayClassName: azure-alb-external
  listeners:
  - name: https-listener
    port: 443
    protocol: HTTPS
    allowedRoutes:
      namespaces:
        from: Same
    tls:
      mode: Terminate
      certificateRefs:
      - kind : Secret
        group: ""
        name: listener-tls-secret
EOF"
az aks command invoke --name $AKS_NAME --resource-group $RESOURCE_GROUP --command "$command"

# Verify the status
echo "Verify the status of Gateway API resoruces ...."
command="kubectl get gateway gateway-01 -n test-infra -o yaml"
az aks command invoke --name $AKS_NAME --resource-group $RESOURCE_GROUP --command "$command"

# Deploy HTTP Route
command="kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: https-route
  namespace: test-infra
spec:
  parentRefs:
  - name: gateway-01
  rules:
  - backendRefs:
    - name: echo
      port: 80
EOF"
az aks command invoke --name $AKS_NAME --resource-group $RESOURCE_GROUP --command "$command"

# Verify Http Route
sleep 30
echo "Verify Http Route...."
command="kubectl get httproute https-route -n test-infra -o yaml"
az aks command invoke --name $AKS_NAME --resource-group $RESOURCE_GROUP --command "$command"

# Wait till FQDN is programmed & Get FQDN
# Initialize the start time
start_time=$(date +%s)

# Set the timeout duration (in seconds)
timeout_duration=300

# Set the check interval (in seconds)
check_interval=5

command="kubectl get gateway gateway-01 -n test-infra -o jsonpath='{.status.addresses[0].value}'"
testfqdn=$(az aks command invoke --name $AKS_NAME --resource-group $RESOURCE_GROUP --command "$command")

while [["$testfqdn" != *"alb.azure.com"*]]; do
    # Get the current time
    current_time=$(date +%s)

    # Calculate the elapsed time
    elapsed_time=$((current_time - start_time))

    # Check if timeout duration has been reached
    if (( elapsed_time >= timeout_duration )); then
        echo "Timeout reached: testfqdn is still not 'ok'."
        exit 1
    fi

    # Check the value of testfqdn
    testfqdn=$(az aks command invoke --name $AKS_NAME --resource-group $RESOURCE_GROUP --command "$command")
    if [["$testfqdn" == *"alb.azure.com"*]]; then
        echo "test_result is 'ok'."
        break
    else
        echo "Waiting for testfqdn to become 'ok'... (Elapsed time: ${elapsed_time}s)"
    fi

    # Wait for the specified check interval before checking again
    sleep $check_interval
done    

clean_string=$(echo "$testfqdn" | tr '\n\r' ' ')
clean_fqdn=$(echo "$clean_string" | awk '{print $NF}')

# Print out the FQDN...
echo "======================================================"
echo " curl -kv https://$clean_fqdn/"
echo "======================================================"

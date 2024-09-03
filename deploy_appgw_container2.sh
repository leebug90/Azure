# Pass all arguments to variables
AKS_NAME=$1
IDENTITY_RESOURCE_NAME=$2
RESOURCE_GROUP=$3
VNET_NAME=$4
ALB_SUBNET_NAME=$5 
ALB_Version=$6
Lab_Scenario=$7

echo "data from arguments ==> $AKS_NAME $IDENTITY_RESOURCE_NAME $RESOURCE_GROUP $VNET_NAME $ALB_SUBNET_NAME $ALB_Version"
echo "Install kubectl.."
az aks install-cli --only-show-errors
sleep 5

# Create a user managed identity for ALB controller and federate the identity as Workload identity to use in AKS cluster
#mcResourceGroup=$(az aks show --resource-group $RESOURCE_GROUP --name $AKS_NAME --query "nodeResourceGroup" -o tsv)
#mcResourceGroupId=$(az group show --name $mcResourceGroup --query id -o tsv)

#echo "Creating identity $IDENTITY_RESOURCE_NAME in resource group $RESOURCE_GROUP"
#az identity create --resource-group $RESOURCE_GROUP --name $IDENTITY_RESOURCE_NAME
#principalId="$(az identity show -g $RESOURCE_GROUP -n $IDENTITY_RESOURCE_NAME --query principalId -o tsv)"

#echo "Waiting 60 seconds to allow for replication of the identity..."
#sleep 60

#echo "Apply Reader role to the AKS managed cluster resource group for the newly provisioned identity"
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

echo "login to AKS cluster to use kubctl..."
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
echo "Creating Application Load Balancer..."
command="kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: alb-test-infra
EOF"
az aks command invoke --name $AKS_NAME --resource-group $RESOURCE_GROUP --command "$command"

# Deploy Application Gateway for Container
echo "Deploying Application Gateway for Container..."
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

############################################################
# Lab Scenario List 
# Lab1 - TLS/SSL offload
# Lab2 - Header Rewriting
# Lab3 - Multi-site Hosting
############################################################

# Lab1 - TLS/SSL offload
cmdApp_lab1="kubectl apply -f https://trafficcontrollerdocs.blob.core.windows.net/examples/https-scenario/ssl-termination/deployment.yaml"
cmdGw_lab1="kubectl apply -f - <<EOF
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
cmdRoute_lab1="kubectl apply -f - <<EOF
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

# Lab2 - Header Rewriting
cmdApp_lab2="kubectl apply -f https://trafficcontrollerdocs.blob.core.windows.net/examples/traffic-split-scenario/deployment.yaml"
cmdGw_lab2="kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
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
  - name: http-listener
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Same
EOF"
cmdRoute_lab2="kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: header-rewrite-route
  namespace: test-infra
spec:
  parentRefs:
    - name: gateway-01
      namespace: test-infra
  hostnames:
    - "contoso.com"
  rules:
    - matches:
        - headers:
          - name: user-agent
            value: Mozilla/5\.0 AppleWebKit/537\.36 \(KHTML, like Gecko; compatible; bingbot/2\.0; \+http://www\.bing\.com/bingbot\.htm\) Chrome/
            type: RegularExpression
      filters:
        - type: RequestHeaderModifier
          requestHeaderModifier:
            set:
              - name: user-agent
                value: SearchEngine-BingBot
            add:
              - name: AGC-Header-Add
                value: AGC-value
            remove: ["client-custom-header"]
      backendRefs:
        - name: backend-v2
          port: 8080
    - backendRefs:
        - name: backend-v1
          port: 8080
EOF"

echo "Deploy HTTP application, Gateway API, and Route..."
case $Lab_Scenario in
  "Lab1")
    echo "Deploying the Lab1 for TLS/SSL offloading."
    az aks command invoke --name $AKS_NAME --resource-group $RESOURCE_GROUP --command "$cmdApp_lab1"
    sleep 2
    az aks command invoke --name $AKS_NAME --resource-group $RESOURCE_GROUP --command "$cmdGw_lab1"
    sleep 2
    az aks command invoke --name $AKS_NAME --resource-group $RESOURCE_GROUP --command "$cmdRoute_lab1"
    sleep 2
    ;;
  "Lab2")
    echo "Deploying the Lab2 for Header Rewriting."
    az aks command invoke --name $AKS_NAME --resource-group $RESOURCE_GROUP --command "$cmdApp_lab2"
    sleep 2
    az aks command invoke --name $AKS_NAME --resource-group $RESOURCE_GROUP --command "$cmdGw_lab2"
    sleep 2
    az aks command invoke --name $AKS_NAME --resource-group $RESOURCE_GROUP --command "$cmdRoute_lab2"
    sleep 2
    ;;
  *)
    echo "Sorry, I don't have information on that Lab."
    ;;
esac

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
echo "FQDN value at the begining: $testfqdn  "

while [[ "$testfqdn" != *"alb.azure.com"* ]]; do
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
    if [[ "$testfqdn" == *"alb.azure.com"* ]]; then
        echo "test_result is 'ok'."
        break
    #else
        #echo "Waiting for testfqdn to become 'ok'... (Elapsed time: ${elapsed_time}s)"
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

# Passing FQDN value over to ARM template
echo "{\"TestFQDN\":\"$clean_fqdn\"}" | jq -c '.' > $AZ_SCRIPTS_OUTPUT_PATH

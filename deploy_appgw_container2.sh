# Pass all arguments to variables
AKS_NAME=$1
IDENTITY_RESOURCE_NAME=$2
RESOURCE_GROUP=$3
VNET_NAME=$4
ALB_SUBNET_NAME=$5 
ALB_Version=$6
Lab_Scenario=$7

# check the values from ARM template
echo "data from arguments ==> $AKS_NAME $IDENTITY_RESOURCE_NAME $RESOURCE_GROUP $VNET_NAME $ALB_SUBNET_NAME $ALB_Version $Lab_Scenario"

echo "Install kubectl.."
az aks install-cli --only-show-errors
sleep 5

echo "Set up federation with AKS OIDC issuer"
AKS_OIDC_ISSUER="$(az aks show -n "$AKS_NAME" -g "$RESOURCE_GROUP" --query "oidcIssuerProfile.issuerUrl" -o tsv)"
az identity federated-credential create --name "azure-alb-identity" \
    --identity-name "$IDENTITY_RESOURCE_NAME" \
    --resource-group $RESOURCE_GROUP \
    --issuer "$AKS_OIDC_ISSUER" \
    --subject "system:serviceaccount:azure-alb-system:alb-controller-sa"

# Install Helm package
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

# Getting Subnet ID for Application Gateway for Container
ALB_SUBNET_ID=$(az network vnet subnet list --resource-group $RESOURCE_GROUP --vnet-name $VNET_NAME --query "[?name=='$ALB_SUBNET_NAME'].id" --output tsv)
echo "ALB subnet ID==> $ALB_SUBNET_ID"

# Create LoadBalancer Kubernetes resource
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
# Lab3 - URL Redirect
# Lab4 - URL Rewrite
# Lab5 - Multi-site hosting
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

# Lab3 - URL Redirect
cmdApp_lab3="kubectl apply -f https://trafficcontrollerdocs.blob.core.windows.net/examples/https-scenario/ssl-termination/deployment.yaml"
cmdGw_lab3="kubectl apply -f - <<EOF
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
cmdRoute1_lab3="kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: https-contoso
  namespace: test-infra
spec:
  parentRefs:
  - name: gateway-01
    sectionName: https-listener
  hostnames:
  - "contoso.com"
  rules:
  - backendRefs:
    - name: echo
      port: 80
EOF"
cmdRoute2_lab3="kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: http-to-https-contoso-redirect
  namespace: test-infra
spec:
  parentRefs:
  - name: gateway-01
    sectionName: http-listener
  hostnames:
  - "contoso.com"
  rules:
    - matches:
      filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
EOF"
cmdRoute3_lab3="kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: summer-promotion-redirect
  namespace: test-infra
spec:
  parentRefs:
  - name: gateway-01
    sectionName: https-listener
  hostnames:
  - "contoso.com"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /summer-promotion
    filters:
      - type: RequestRedirect
        requestRedirect:
          path:
            type: ReplaceFullPath
            replaceFullPath: /shop/category/5
          statusCode: 302
  - backendRefs:
    - name: echo
      port: 80
EOF"

# Lab4 - URL Rewrite
cmdApp_lab4="kubectl apply -f https://trafficcontrollerdocs.blob.core.windows.net/examples/traffic-split-scenario/deployment.yaml"
cmdGw_lab4="kubectl apply -f - <<EOF
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
cmdRoute_lab4="kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: rewrite-example
  namespace: test-infra
spec:
  parentRefs:
  - name: gateway-01
  hostnames:
  - "contoso.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /shop
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /ecommerce
      backendRefs:
        - name: backend-v1
          port: 8080
    - backendRefs:
        - name: backend-v2
          port: 8080
EOF"

# Lab5 - Multi-site hosting
cmdApp_lab5="kubectl apply -f https://trafficcontrollerdocs.blob.core.windows.net/examples/traffic-split-scenario/deployment.yaml"
cmdGw_lab5="kubectl apply -f - <<EOF
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
cmdRoute_lab5="kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: contoso-route
  namespace: test-infra
spec:
  parentRefs:
  - name: gateway-01
  hostnames:
  - "contoso.com"
  rules:
  - backendRefs:
    - name: backend-v1
      port: 8080
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: fabrikam-route
  namespace: test-infra
spec:
  parentRefs:
  - name: gateway-01
  hostnames:
  - "fabrikam.com"
  rules:
  - backendRefs:
    - name: backend-v2
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
  "Lab3")
    echo "Deploying the Lab3 for URL Redirect."
    az aks command invoke --name $AKS_NAME --resource-group $RESOURCE_GROUP --command "$cmdApp_lab3"
    sleep 2
    az aks command invoke --name $AKS_NAME --resource-group $RESOURCE_GROUP --command "$cmdGw_lab3"
    sleep 2
    az aks command invoke --name $AKS_NAME --resource-group $RESOURCE_GROUP --command "$cmdRoute1_lab3"
    sleep 2
    az aks command invoke --name $AKS_NAME --resource-group $RESOURCE_GROUP --command "$cmdRoute2_lab3"
    sleep 2
    az aks command invoke --name $AKS_NAME --resource-group $RESOURCE_GROUP --command "$cmdRoute3_lab3"
    sleep 2
    ;;
  "Lab4")
    echo "Deploying the Lab4 for URL Rewrite."
    az aks command invoke --name $AKS_NAME --resource-group $RESOURCE_GROUP --command "$cmdApp_lab4"
    sleep 2
    az aks command invoke --name $AKS_NAME --resource-group $RESOURCE_GROUP --command "$cmdGw_lab4"
    sleep 2
    az aks command invoke --name $AKS_NAME --resource-group $RESOURCE_GROUP --command "$cmdRoute_lab4"
    sleep 2
    ;;
  "Lab5")
    echo "Deploying the Lab5 for Multi-site hosting."
    az aks command invoke --name $AKS_NAME --resource-group $RESOURCE_GROUP --command "$cmdApp_lab5"
    sleep 2
    az aks command invoke --name $AKS_NAME --resource-group $RESOURCE_GROUP --command "$cmdGw_lab5"
    sleep 2
    az aks command invoke --name $AKS_NAME --resource-group $RESOURCE_GROUP --command "$cmdRoute_lab5"
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

# Set the timeout duration (in seconds); Wait for 5min
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
echo "FQDN after programmed: $clean_fqdn"

# Passing FQDN value over to ARM template
echo "{\"TestFQDN\":\"$clean_fqdn\"}" | jq -c '.' > $AZ_SCRIPTS_OUTPUT_PATH

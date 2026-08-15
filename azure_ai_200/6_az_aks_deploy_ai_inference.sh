#!/usr/bin/env bash
set -e

###############################################
# STEP 0 — VARIABLES (dynamic names for isolation)
###############################################
PREFIX=$(tr -dc 'a-z0-9' </dev/urandom | head -c 5)

RESOURCE_GROUP="rg-acr-demo-${PREFIX}"        # Resource group
LOCATION="eastus2"                            # Region
FOUNDRY_RESOURCE="ms-foundry-demo-${PREFIX}"  # Foundry instance
ACR_NAME="acrdemosvc${PREFIX}"                # Azure Container Registry
AKS_CLUSTER="aks-demo123-${PREFIX}"           # AKS cluster name
API_IMAGE_NAME="aks-api"                      # Image repo name (fixed)
AKS_VM_SIZE="Standard_D2s_v7"                 # Node size

SUBSCRIPTION_ID="78a15e40-dc01-4bdb-8cc6-7abf97430f10"
API_SOURCE_DIR="./aks_ai_app/api"             # API source folder
DEPLOYMENT_FILE="./aks_ai_app/k8s/deployment.yaml"
SERVICE_FILE="./aks_ai_app/k8s/service.yaml"

LLM_DEPLOYMENT_NAME="gpt-5-mini"
LLM_MODEL_NAME="gpt-5-mini"
LLM_MODEL_VERSION="2025-08-07"
FOUNDRY_MODEL_FORMAT="OpenAI"
FOUNDRY_SKU_CAPACITY=1
FOUNDRY_SKU_NAME="GlobalStandard"

###############################################
# STEP 1 — LOGIN & SELECT SUBSCRIPTION
###############################################
az login
az account set --subscription "$SUBSCRIPTION_ID"

###############################################
# STEP 2 — CREATE RESOURCE GROUP
###############################################
az group create --name "$RESOURCE_GROUP" --location "$LOCATION"

###############################################
# STEP 3 — CREATE MICROSOFT FOUNDRY RESOURCE
###############################################
az cognitiveservices account create \
  --name "$FOUNDRY_RESOURCE" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --custom-domain "$FOUNDRY_RESOURCE" \
  --kind AIServices \
  --sku s0 \
  --yes

###############################################
# STEP 4 — DEPLOY MODEL TO FOUNDRY
###############################################
az cognitiveservices account deployment create \
  --name "$FOUNDRY_RESOURCE" \
  --resource-group "$RESOURCE_GROUP" \
  --deployment-name "$LLM_DEPLOYMENT_NAME" \
  --model-name "$LLM_MODEL_NAME" \
  --model-version "$LLM_MODEL_VERSION" \
  --model-format "$FOUNDRY_MODEL_FORMAT" \
  --sku-capacity $FOUNDRY_SKU_CAPACITY \
  --sku-name "$FOUNDRY_SKU_NAME"

###############################################
# STEP 5 — GET FOUNDRY ENDPOINT
###############################################
FOUNDRY_ENDPOINT=$(az cognitiveservices account show \
  --name "$FOUNDRY_RESOURCE" \
  --resource-group "$RESOURCE_GROUP" \
  --query properties.endpoint -o tsv)
echo "Foundry Endpoint: $FOUNDRY_ENDPOINT"

###############################################
# STEP 6 — CREATE ACR (admin enabled)
###############################################
az acr create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$ACR_NAME" \
  --sku Basic \
  --admin-enabled true

###############################################
# STEP 7 — BUILD & PUSH API IMAGE TO ACR
###############################################
az acr build \
  --resource-group "$RESOURCE_GROUP" \
  --registry "$ACR_NAME" \
  --image "${API_IMAGE_NAME}:latest" \
  --file "$API_SOURCE_DIR/Dockerfile" \
  "$API_SOURCE_DIR"

###############################################
# STEP 8 — CREATE AKS CLUSTER (attach ACR)
###############################################
az aks create \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --name "$AKS_CLUSTER" \
  --node-count 1 \
  --node-vm-size "$AKS_VM_SIZE" \
  --tier free \
  --vm-set-type VirtualMachineScaleSets \
  --load-balancer-sku standard \
  --enable-managed-identity \
  --network-plugin azure \
  --no-ssh-key \
  --attach-acr "$ACR_NAME"

###############################################
# STEP 9 — GET AKS CREDENTIALS (WSL safe)
###############################################
mkdir -p ~/.kube
cp /mnt/c/Users/techn/.kube/config ~/.kube/config
chmod 600 ~/.kube/config

az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AKS_CLUSTER" \
  --file ~/.kube/config \
  --overwrite-existing

###############################################
# STEP 10 — ASSIGN OPENAI USER ROLE TO KUBELET
###############################################
KUBELET_ID=$(az aks show \
  --name "$AKS_CLUSTER" \
  --resource-group "$RESOURCE_GROUP" \
  --query "identityProfile.kubeletidentity.objectId" -o tsv)

az role assignment create \
  --assignee-object-id "$KUBELET_ID" \
  --role "Cognitive Services OpenAI User" \
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP" || true

###############################################
# STEP 11 — APPLY DEPLOYMENT (inject ACR + Foundry)
###############################################
sed -e "s|ACR_ENDPOINT|${ACR_NAME}.azurecr.io|g" \
    -e "s|API_IMAGE_NAME|${API_IMAGE_NAME}|g" \
    -e "s|FOUNDRY_ENDPOINT|${FOUNDRY_ENDPOINT}|g" \
    "$DEPLOYMENT_FILE" | kubectl apply -f -

###############################################
# STEP 12 — APPLY SERVICE
###############################################
kubectl apply -f "$SERVICE_FILE"

# list running pods in the current namespace
kubectl get pods 

# show detailed pod info, events, and container status
kubectl describe pod <pod_name>  

# list all pods across all namespaces
kubectl get pods -A         


###############################################
# STEP 13 — WAIT FOR LOAD BALANCER IP
###############################################
echo "Waiting for external IP..."
sleep 10
EXTERNAL_IP=$(kubectl get svc aks-api-service \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "External IP: $EXTERNAL_IP"

###############################################
# STEP 14 — UPDATE CLIENT .env
###############################################
cat > aks_ai_app/client/.env << EOF
API_ENDPOINT=http://$EXTERNAL_IP
OPENAI_API_ENDPOINT=$FOUNDRY_ENDPOINT
FOUNDRY_API_VERSION=${LLM_MODEL_VERSION}
OPENAI_DEPLOYMENT_NAME=$LLM_DEPLOYMENT_NAME
EOF

echo "Client updated. Run: python client/main.py"

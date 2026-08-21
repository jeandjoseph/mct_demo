#!/usr/bin/env bash
set -e

az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.ContainerRegistry
az provider register --namespace Microsoft.Compute
az provider register --namespace Microsoft.Network
az provider register --namespace Microsoft.Storage


############################################################
# STEP 0 - VARIABLES
# Update these values before running the script
############################################################
PREFIX=$(tr -dc 'a-z0-9' </dev/urandom | head -c 5) 
RESOURCE_GROUP="rg-aks-demo-${PREFIX}"
LOCATION="eastus2"

ACR_NAME="acrdemosvc${PREFIX}"
ACR_SERVER="${ACR_NAME}.azurecr.io"

AKS_CLUSTER="aks-demo-${PREFIX}"
AKS_VM_SIZE="Standard_D2s_v7"

API_IMAGE_NAME="aks-config-api"
IMAGE_TAG="latest"

SOURCE_FOLDER="../aks_data_app/api"
DOCKERFILE_PATH="../aks_data_app/api/Dockerfile"

############################################################
# STEP 1 - VERIFY AZURE LOGIN
############################################################

az login

echo "Current Azure Account"

az account show \
  --output table

############################################################
# STEP 2 - CREATE RESOURCE GROUP
############################################################

echo "Creating Resource Group..."

az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION

echo "done"

############################################################
# STEP 3 - CREATE AZURE CONTAINER REGISTRY (ACR)
############################################################

echo "Creating Azure Container Registry..."

az acr create \
  --resource-group $RESOURCE_GROUP \
  --name $ACR_NAME \
  --sku Basic \
  --admin-enabled true

############################################################
# STEP 4 - VERIFY ACR
############################################################

echo "Verifying ACR..."

az acr show \
  --resource-group $RESOURCE_GROUP \
  --name $ACR_NAME \
  --output table

############################################################
# STEP 5 - BUILD AND PUSH IMAGE TO ACR
#
# Builds the image directly in Azure using ACR Tasks.
############################################################

echo "Building and pushing image..."

az acr build \
  --resource-group $RESOURCE_GROUP \
  --registry $ACR_NAME \
  --image ${API_IMAGE_NAME}:${IMAGE_TAG} \
  --file $DOCKERFILE_PATH \
  $SOURCE_FOLDER

############################################################
# STEP 6 - VERIFY IMAGE EXISTS IN ACR
############################################################

echo "Listing image tags..."

az acr repository show-tags \
  --name $ACR_NAME \
  --repository $API_IMAGE_NAME \
  --output table

############################################################
# STEP 7 - CREATE AKS CLUSTER
#
# Creates a single-node AKS cluster and grants it
# access to pull images from the Azure Container Registry.
############################################################

echo "Creating AKS Cluster..."

az aks create \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --name $AKS_CLUSTER \
  --node-count 1 \
  --node-vm-size $AKS_VM_SIZE \
  --tier free \
  --vm-set-type VirtualMachineScaleSets \
  --load-balancer-sku standard \
  --enable-managed-identity \
  --network-plugin azure \
  --no-ssh-key \
  --attach-acr $ACR_NAME

############################################################
# STEP 8 - VERIFY AKS PROVISIONING STATUS
############################################################

echo "Checking AKS Status..."
# Check AKS provisioning status
az aks show \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_CLUSTER \
  --query provisioningState \
  --output tsv

# Check if the AKS cluster is running
az aks show \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_CLUSTER \
  --query powerState.code \
  -o tsv

# Check if the AKS cluster is private or public
az aks show \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_CLUSTER \
  --query "{Private:apiServerAccessProfile.enablePrivateCluster}"

# Check the AKS cluster FQDN
az aks show \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_CLUSTER \
  --query "{State:provisioningState,Power:powerState.code,FQDN:fqdn}" \
  -o yaml



# Get the AKS API server FQDN
az aks show \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_CLUSTER \
  --query fqdn \
  -o tsv

# Display active kubeconfig details
kubectl config view --minify

# Show the Kubernetes API server endpoint
kubectl config view --minify \
  -o jsonpath='{.clusters[0].cluster.server}'




############################################################
# STEP 9 - DOWNLOAD AKS CREDENTIALS
#
# Configures kubectl to connect to the cluster.
############################################################

echo "Getting AKS Credentials..."

az aks get-credentials \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_CLUSTER \
  --overwrite-existing

############################################################
# STEP 10 - VERIFY CLUSTER CONNECTIVITY
############################################################

echo "Listing Kubernetes Nodes..."

kubectl get nodes

# if it failed
# Reason: WSL cannot automatically use the Windows kubeconfig unless you copy it.
#  Without these three lines:
#    kubectl get pods fails
#    kubectl get svc fails
#    WSL cannot talk to your AKS cluster

You get “context not found” errors
mkdir -p ~/.kube
cp /mnt/c/Users/techn/.kube/config ~/.kube/config
chmod 600 ~/.kube/config

############################################################
# STEP 11 - VERIFY ACR ACCESS FROM AKS
############################################################

echo "Validating AKS Access to ACR..."

az aks check-acr \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_CLUSTER \
  --acr $ACR_SERVER

############################################################
# STEP 12 - DEPLOY KUBERNETES CONFIGURATION
############################################################

# Pre-requisites: 
  # Update Deployment yaml on line 22 with the correct image name and tag: 
  # <YOUR_ACR_ENDPOINT>/aks-config-api:latest
#acr_server=$(az acr show --resource-group $RESOURCE_GROUP --name $ACR_NAME --query loginServer -o tsv)
az acr show --name $ACR_NAME --query loginServer -o tsv



echo "Deploying ConfigMap..."

kubectl apply -f ../aks_data_app/k8s/configmap.yaml

echo "Deploying Secret..."

kubectl apply -f ../aks_data_app/k8s/secrets.yaml

echo "Deploying Persistent Volume Claim..."

kubectl apply -f ../aks_data_app/k8s/pvc.yaml

echo "Deploying Application..."

kubectl apply -f ../aks_data_app/k8s/deployment.yaml

echo "Deploying Service..."

kubectl apply -f ../aks_data_app/k8s/service.yaml



############################################################
# STEP 13 - VERIFY DEPLOYMENT
############################################################

# Restart:
kubectl get deployments

kubectl rollout restart deployment aks-config-api

kubectl rollout status deployment/aks-config-api

echo "Pods"

kubectl get pods

echo ""
echo "Deployments"

kubectl get deployments

echo ""
echo "Services"

kubectl get services

echo ""
echo "Persistent Volume Claims"

kubectl get pvc


############################################################
# STEP 14 - WATCH DEPLOYMENT UNTIL READY
############################################################

kubectl rollout status deployment/aks-config-api

############################################################
# STEP 15 - DISPLAY APPLICATION ENDPOINT
############################################################

kubectl get svc aks-config-api-service


# POWERSHELL TERMINAL COMMANDS
# change to powershell to run the following command
pip install -r requirements.txt


EXTERNAL_IP=$(kubectl get svc aks-config-api-service \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "External IP: $EXTERNAL_IP"


###############################################
# STEP 14 — UPDATE CLIENT .env
###############################################
cat > aks_data_app/client/.env << EOF
API_ENDPOINT=http://$EXTERNAL_IP
EOF

cd ./azure_ai_200/aks_data_app/client

python main.py

############################################################
# STEP 16 - VIEW APPLICATION LOGS (OPTIONAL)
############################################################

# kubectl logs deploy/aks-config-api

############################################################
# CLEANUP COMMANDS (OPTIONAL)
############################################################

# Delete AKS Cluster
# az aks delete \
#   --resource-group $RESOURCE_GROUP \
#   --name $AKS_CLUSTER \
#   --yes

# Delete ACR
# az acr delete \
#   --resource-group $RESOURCE_GROUP \
#   --name $ACR_NAME \
#   --yes

# Delete Resource Group
# az group delete \
#   --name $RESOURCE_GROUP \
#   --yes
# Optional: install Azure Container Apps CLI extension
# Notes: Required for 'az containerapp' commands if not already installed
# az extension add --name containerapp

# Register required resource providers for ACA + ACR + logging
# Notes: Ensures platform resource types are available in your subscription
az provider register --namespace Microsoft.App \
  --wait    # ACA control plane

az provider register --namespace Microsoft.OperationalInsights \
  --wait    # Log Analytics / diagnostics

az provider register --namespace Microsoft.ContainerRegistry
  # ACR resource provider (no --wait needed, but can be added)

#!/usr/bin/env bash
set -e

###############################################
# STEP 0 — VARIABLES (EDIT AS NEEDED)
# Notes: Central config for RG, ACR, ACA, image, and app settings
###############################################
RANDOM_SUFFIX=$(tr -dc 'a-z0-9' </dev/urandom | head -c 5)    # keeps globally-unique names unique

RESOURCE_GROUP="rg-acr-demo-$RANDOM_SUFFIX"
LOCATION="eastus2"
ACR_NAME="acrdemosvc$RANDOM_SUFFIX"
ACR_SERVER="$ACR_NAME.azurecr.io"
ACA_ENVIRONMENT="aca-env-demo"
CONTAINER_APP_NAME="az-aca-demo-app"
CONTAINER_IMAGE="aca_demo_api:v1.0.0"
TARGET_PORT=8000
MODEL_NAME="gpt-5.4-nano"
SOURCE_DIR="../acaapi"
EMBEDDINGS_API_KEY="demo-key-12345"

###############################################
# STEP 1 — CREATE RESOURCE GROUP
# Notes: Subscription-level container for all ACA/ACR resources
###############################################
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION"

###############################################
# STEP 2 — CREATE ACR (Basic SKU)
# Notes: Private container registry to store and serve images
###############################################
az acr create \
  --name "$ACR_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --sku Basic

###############################################
# STEP 3 — ENABLE ACR ADMIN ACCOUNT
# Notes: Enables username/password auth (useful for demos and quick tests)
###############################################
az acr update \
  --name "$ACR_NAME" \
  --admin-enabled true

# Start from her:
###############################################
# STEP 4 — BUILD IMAGE IN ACR (Cloud Build)
# Notes: Uses ACR Tasks to build and push image from local source directory
###############################################
az acr build \
  --registry "$ACR_NAME" \
  --image "$CONTAINER_IMAGE" \
  "$SOURCE_DIR"

###############################################
# STEP 5 — CREATE CONTAINER APPS ENVIRONMENT
# Notes: ACA environment hosting network, logging, and app runtime
###############################################
az containerapp env create \
  --name "$ACA_ENVIRONMENT" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION"

###############################################
# STEP 6 — DEPLOY CONTAINER APP
# Notes: Creates ACA app, pulls image from ACR, exposes HTTP endpoint
###############################################
az containerapp create \
  --name "$CONTAINER_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --environment "$ACA_ENVIRONMENT" \
  --image "$ACR_SERVER/$CONTAINER_IMAGE" \
  --ingress external \
  --min-replicas 0 \
  --max-replicas 3 \
  --target-port "$TARGET_PORT" \
  --env-vars MODEL_NAME="$MODEL_NAME" \
  --registry-server "$ACR_SERVER" \
  --registry-identity system

###############################################
# STEP 7 — SHOW CONTAINER APP URL
# Notes: Retrieves public FQDN for testing and API calls
###############################################
az containerapp show \
  --name "$CONTAINER_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query properties.configuration.ingress.fqdn \
  -o tsv

###############################################
# STEP 8 — SET ACA SECRET (EMBEDDINGS API KEY)
# Notes: Stores sensitive key as ACA secret, not plain env var
###############################################
az containerapp secret set \
  -n "$CONTAINER_APP_NAME" \
  -g "$RESOURCE_GROUP" \
  --secrets embeddings-api-key="$EMBEDDINGS_API_KEY"

###############################################
# STEP 9 — WIRE SECRET INTO ENV VAR
# Notes: Maps secret to runtime env var via secretref
###############################################
az containerapp update \
  -n "$CONTAINER_APP_NAME" \
  -g "$RESOURCE_GROUP" \
  --set-env-vars EMBEDDINGS_API_KEY=secretref:embeddings-api-key

###############################################
# STEP 10 — LIST ACA REVISIONS
# Notes: Shows deployment history and active revisions
###############################################
az containerapp revision list \
  -n "$CONTAINER_APP_NAME" \
  -g "$RESOURCE_GROUP" \
  -o table

###############################################
# STEP 11 — CAPTURE CLEAN FQDN
# Notes: Strips hidden characters for safe use in curl
###############################################
FQDN=$(az containerapp show \
  --name "$CONTAINER_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query properties.configuration.ingress.fqdn \
  -o tsv | tr -d '\r' | tr -d '\n' | xargs)

echo "Clean FQDN: $FQDN"

###############################################
# STEP 12 — HEALTH + ROOT ENDPOINT TESTS
# Notes: Verifies app responds on /health and /
###############################################
curl -s "https://$FQDN/health"
curl -v "https://$FQDN/"


###############################################
# STEP 13 — CALL /process API ENDPOINT
# Notes: Sends document.txt to ACA backend for processing.
#        Uses --data-binary to safely upload file contents.
###############################################
cd acaapi

curl -s -X POST "https://$FQDN/process" \
  -H "Content-Type: text/plain" \
  --data-binary @document.txt


###############################################
# STEP 14 — STREAM ACA LOGS
# Notes: Live logs for debugging startup, requests, and errors
###############################################
az containerapp logs show \
  -n "$CONTAINER_APP_NAME" \
  -g "$RESOURCE_GROUP" \
  --follow

# Remember to copy the preffix for the next script
echo $RANDOM_SUFFIX

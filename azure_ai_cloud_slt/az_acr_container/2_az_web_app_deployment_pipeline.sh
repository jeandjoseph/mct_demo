#!/usr/bin/env bash
set -e

###############################################
# STEP 0 — DEFINE DEPLOYMENT VARIABLES
# Notes: Uses a timestamp suffix to create
# globally unique Azure resource names

# Notes: Make sure you have a container image 
#built and pushed to ACR before running this script.
# if you not have use: 1.acr_cloud_build_pipeline.sh
###############################################

RANDOM_SUFFIX="xxxxx" # random value from the first script

RG_NAME="rg-acr-demo-$RANDOM_SUFFIX"
LOC="eastus2"
ACR_NAME="acrdemosvc$RANDOM_SUFFIX"
IMAGE_NAME="demoapp"
IMAGE_TAG_BUILD="v1.0.0"
PLAN_NAME="plan-demo-linux"
APP_NAME="webapp-demo-$RANDOM_SUFFIX"

###############################################
# STEP 1 — CREATE APP SERVICE PLAN
# Notes: Provisions Linux compute resources
# for hosting the containerized Web App
###############################################
az appservice plan create \
  --name "$PLAN_NAME" \
  --resource-group "$RG_NAME" \
  --sku B1 \
  --is-linux

###############################################
# STEP 2 — CREATE LINUX WEB APP
# Notes: Creates the Web App resource that
# will later be configured with a container
# image hosted in Azure Container Registry
###############################################
az webapp create \
  --name "$APP_NAME" \
  --resource-group "$RG_NAME" \
  --plan "$PLAN_NAME" \
  --container-image-name \
  "$ACR_NAME.azurecr.io/$IMAGE_NAME:$IMAGE_TAG_BUILD"

###############################################
# STEP 3 — ENABLE ACR ADMIN ACCOUNT
# Notes: Enables username/password access
# for demo and learning scenarios
###############################################
az acr update \
  --name "$ACR_NAME" \
  --admin-enabled true

###############################################
# STEP 4 — RETRIEVE ACR CREDENTIALS
# Notes: Obtains registry username and
# password for container image pulls
###############################################
ACR_USERNAME=$(az acr credential show \
  --name "$ACR_NAME" \
  --query username \
  --output tsv)

ACR_PASSWORD=$(az acr credential show \
  --name "$ACR_NAME" \
  --query passwords[0].value \
  --output tsv)

###############################################
# STEP 5 — CONFIGURE CONTAINER IMAGE
# Notes: Configures the Web App to pull
# the container image from ACR
###############################################
az webapp config container set \
  --name "$APP_NAME" \
  --resource-group "$RG_NAME" \
  --container-image-name \
  "$ACR_NAME.azurecr.io/$IMAGE_NAME:$IMAGE_TAG_BUILD" \
  --container-registry-url \
  "https://$ACR_NAME.azurecr.io" \
  --container-registry-user "$ACR_USERNAME" \
  --container-registry-password "$ACR_PASSWORD"
`


###############################################
# STEP 6 — RESTART WEB APP
# Notes: Forces App Service to pull the
# latest container configuration
###############################################
az webapp restart \
  --name "$APP_NAME" \
  --resource-group "$RG_NAME"

###############################################
# STEP 7 — VERIFY WEB APP CONFIGURATION
# Notes: Displays application metadata and
# deployment configuration details
###############################################
az webapp show \
  --name "$APP_NAME" \
  --resource-group "$RG_NAME" \
  --output json

###############################################
# STEP 8 — RETRIEVE APPLICATION URL
# Notes: Returns the default hostname used
# to access the deployed application
###############################################
APP_URL=$(az webapp show \
  --name "$APP_NAME" \
  --resource-group "$RG_NAME" \
  --query defaultHostName \
  --output tsv)

echo "https://$APP_URL"

###############################################
# STEP 9 — ENABLE APPLICATION LOGGING
# Notes: Stores application and web server
# logs in the App Service file system
###############################################
az webapp log config \
  --name "$APP_NAME" \
  --resource-group "$RG_NAME" \
  --application-logging filesystem \
  --web-server-logging filesystem

###############################################
# STEP 10 — STREAM APPLICATION LOGS
# Notes: Continuously displays container and
# application logs for troubleshooting
###############################################
az webapp log tail \
  --name "$APP_NAME" \
  --resource-group "$RG_NAME"
`
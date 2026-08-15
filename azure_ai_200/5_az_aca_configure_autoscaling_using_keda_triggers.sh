#!/usr/bin/env bash
set -e

############################################################
# OPTIONAL PREREQUISITES
# Note: 3.az_container_app_deployment_pipeline.sh first
############################################################

# Install Azure Container Apps extension if not already present.
# Required for all "az containerapp" commands.
# az extension add --name containerapp

############################################################
# STEP 1 - REGISTER REQUIRED RESOURCE PROVIDERS
# These providers must be registered in the subscription
# before creating ACA, ACR, and Log Analytics resources.
############################################################

# Azure Container Apps provider
az provider register \
  --namespace Microsoft.App \
  --wait

# Log Analytics provider
az provider register \
  --namespace Microsoft.OperationalInsights \
  --wait

# Azure Container Registry provider
az provider register \
  --namespace Microsoft.ContainerRegistry \
  --wait

############################################################
# STEP 2 - DEFINE VARIABLES
# Central location for all resource names and settings.
############################################################

RESOURCE_GROUP="rg-acr-demo-del"
LOCATION="eastus2"

# Azure Container Registry
ACR_NAME="acrdemosvcx"
ACR_SERVER="$ACR_NAME.azurecr.io"

# Azure Container Apps
ACA_ENVIRONMENT="aca-env-demo"
CONTAINER_APP_NAME="az-aca-demo-app"

# Container image and runtime settings
CONTAINER_IMAGE="aca_demo_api:v1.0.0"
TARGET_PORT=8000

# Application configuration
MODEL_NAME="gpt-5.4-nano"
EMBEDDINGS_API_KEY="demo-key-12345"

# Local source folder
SOURCE_DIR="./acaapi"

############################################################
# STEP 3 - VIEW CURRENT SCALING CONFIGURATION
# Useful for documenting the existing settings before changes.
############################################################

az containerapp show \
  --name "$CONTAINER_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.template.scale" \
  --output json

############################################################
# STEP 4 - CONFIGURE HTTP AUTO-SCALING
#
# Min replicas = 0
#   App can scale to zero when idle.
#
# Max replicas = 3
#   ACA can scale out to 3 instances.
#
# HTTP concurrency = 10
#   Create more replicas when requests exceed
#   10 concurrent requests per replica.
############################################################

az containerapp update \
  --name "$CONTAINER_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --min-replicas 0 \
  --max-replicas 3 \
  --scale-rule-name http-scaling \
  --scale-rule-type http \
  --scale-rule-http-concurrency 10

############################################################
# STEP 5 - VERIFY UPDATED SCALE SETTINGS
############################################################

az containerapp show \
  --name "$CONTAINER_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.template.scale" \
  --output json

############################################################
# STEP 6 - EXPORT COMPLETE ACA CONFIGURATION
#
# Creates a YAML file that can be edited manually and
# re-applied later.
############################################################

az containerapp show \
  --name "$CONTAINER_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --output yaml > app-config.yaml

############################################################
# STEP 7 - EDIT THE YAML FILE
#
# Open app-config.yaml and modify the scale section.
#
# Example:
#
# scale:
#   cooldownPeriod: 200
#   pollingInterval: 30
#   minReplicas: 1
#   maxReplicas: 5
#
# Save the file when finished.
############################################################

# code app-config.yaml
# nano app-config.yaml
# vi app-config.yaml

############################################################
# STEP 8 - APPLY THE UPDATED YAML CONFIGURATION
#
# Deploys any manual changes made to app-config.yaml.
############################################################

az containerapp update \
  --name "$CONTAINER_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --yaml app-config.yaml

############################################################
# STEP 9 - VERIFY THE FINAL CONFIGURATION
############################################################

az containerapp show \
  --name "$CONTAINER_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.template.scale" \
  --output yaml
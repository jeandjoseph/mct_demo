#!/usr/bin/env bash
set -e

###############################################
# STEP 0 — DEFINE DEPLOYMENT VARIABLES
# Notes: Centralized configuration for Azure
# resources, image names, tags, and source path
###############################################

RANDOM_SUFFIX=$(tr -dc 'a-z0-9' </dev/urandom | head -c 5)    # keeps globally-unique names unique

RG_NAME="rg-acr-demo-$RANDOM_SUFFIX"
LOC="eastus2"
ACR_NAME="acrdemosvc$RANDOM_SUFFIX"
IMAGE_NAME="demoapp"
IMAGE_TAG_BUILD="v1.0.0"
IMAGE_TAG_LOCAL="v2.0.0"
SOURCE_DIR="../az_acr_container"

echo $RG_NAME

###############################################
# STEP 1 — CREATE RESOURCE GROUP
# Notes: Creates or updates the resource group
# that will contain all Azure resources
###############################################
az group create \
  --name "$RG_NAME" \
  --location "$LOC"

###############################################
# STEP 2 — CREATE AZURE CONTAINER REGISTRY
# Notes: Provisions a Basic SKU container
# registry for storing and managing images
###############################################
az acr create \
  --name "$ACR_NAME" \
  --resource-group "$RG_NAME" \
  --sku Basic

###############################################
# STEP 3 — DISPLAY ACR LOGIN SERVER
# Notes: Returns the registry FQDN used for
# image tagging, pushing, and pulling
###############################################
az acr show \
  --name "$ACR_NAME" \
  --query loginServer \
  --output tsv

###############################################
# STEP 4 — ENABLE ACR ADMIN ACCOUNT
# Notes: Enables username/password access for
# testing, demos, and non-production scenarios
###############################################
az acr update \
  --name "$ACR_NAME" \
  --admin-enabled true

###############################################
# STEP 5 — BUILD IMAGE IN ACR
# Notes: Sends source code to ACR Tasks and
# performs a cloud-based container build
###############################################
az acr build \
  --registry "$ACR_NAME" \
  --image "$IMAGE_NAME:$IMAGE_TAG_BUILD" \
  "$SOURCE_DIR"

###############################################
# STEP 6 — LIST REGISTRY REPOSITORIES
# Notes: Displays all repositories currently
# stored within the container registry
###############################################
az acr repository list \
  --name "$ACR_NAME" \
  --output table

###############################################
# STEP 7 — DISPLAY IMAGE DETAILS
# Notes: Shows metadata for a specific image,
# including digest, tags, and manifest data
###############################################
az acr repository show \
  --name "$ACR_NAME" \
  --image "$IMAGE_NAME:$IMAGE_TAG_BUILD" \
  --output json


###############################################
# STEP 8 — LIST IMAGE TAGS
# Notes: Displays all tags associated with
# the selected repository
###############################################
az acr repository show-tags \
  --name "$ACR_NAME" \
  --repository "$IMAGE_NAME" \
  --output table

###############################################
# STEP 9 — DISPLAY MANIFEST METADATA
# Notes: Shows manifests, digests, creation
# timestamps, and repository metadata
###############################################
az acr manifest list-metadata \
  --registry "$ACR_NAME" \
  --name "$IMAGE_NAME" \
  --output json

###############################################
# STEP 10 — LIST ACR TASK RUN HISTORY
# Notes: Displays build and run executions
# previously performed within ACR Tasks
###############################################
az acr task list-runs \
  --registry "$ACR_NAME" \
  --output table

###############################################
# STEP 11 — INSPECT ACR RUN RESULTS
# Notes: Retrieves logs for the ACR Task run,
# including container startup, output, errors,
# and completion status
###############################################
az acr task logs \
  --registry "$ACR_NAME"

###############################################
# STEP 12 — EXECUTE COMMAND IN ACR TASK
# Notes: Launches an on-demand ACR Task and
# runs the specified command in the ACR runtime
###############################################
az acr run \
  --registry "$ACR_NAME" \
  --cmd "mcr.microsoft.com/azure-cli az version" \
  /dev/null

# Remember to copy the preffix for the second script
echo $RANDOM_SUFFIX
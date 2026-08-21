#!/usr/bin/env bash

set -e

# =============================================================================
# STEP 1: DECLARE ALL VARIABLES
# =============================================================================

RANDOM_SUFFIX=$(tr -dc 'a-z0-9' </dev/urandom | head -c 5)

RESOURCE_GROUP="rg-eventgrid-${RANDOM_SUFFIX}"
LOCATION="westus3"

NAMESPACE_NAME="egns-${RANDOM_SUFFIX}"
TOPIC_NAME="moderation-events"

SUB_FLAGGED="sub-flagged"
SUB_APPROVED="sub-approved"
SUB_ALL="sub-all-events"

SENDER_ROLE="EventGrid Data Sender"
RECEIVER_ROLE="EventGrid Data Receiver"

DELIVERY_CONFIG="{deliveryMode:Queue,queue:{receiveLockDurationInSeconds:60,maxDeliveryCount:10,eventTimeToLive:P1D}}"
FLAGGED_FILTER="{includedEventTypes:['com.contoso.ai.ContentFlagged']}"
APPROVED_FILTER="{includedEventTypes:['com.contoso.ai.ContentApproved']}"

USER_OBJECT_ID=""
USER_PRINCIPAL_NAME=""
NAMESPACE_ID=""
NAMESPACE_HOSTNAME=""
EVENTGRID_ENDPOINT=""


# =============================================================================
# STEP 2: VERIFY AZURE LOGIN
# =============================================================================

echo "Checking Azure login..."

if ! az account show >/dev/null 2>&1; then
    az login
fi

USER_OBJECT_ID=$(az ad signed-in-user show \
    --query "id" \
    --output tsv)

USER_PRINCIPAL_NAME=$(az ad signed-in-user show \
    --query "userPrincipalName" \
    --output tsv)

echo "Signed-in user: ${USER_PRINCIPAL_NAME}"


# =============================================================================
# STEP 3: PREPARE EVENT GRID
# =============================================================================

echo "Preparing Azure Event Grid..."

az config set extension.use_dynamic_install=yes_without_prompt >/dev/null

az provider register \
    --namespace Microsoft.EventGrid \
    --wait


# =============================================================================
# STEP 4: CREATE THE RESOURCE GROUP
# =============================================================================

echo "Creating resource group: ${RESOURCE_GROUP}"

az group create \
    --name "${RESOURCE_GROUP}" \
    --location "${LOCATION}" \
    --output none


# =============================================================================
# STEP 5: CREATE THE EVENT GRID NAMESPACE
# =============================================================================

echo "Creating Event Grid namespace: ${NAMESPACE_NAME}"

az eventgrid namespace create \
    --name "${NAMESPACE_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --location "${LOCATION}" \
    --sku "{name:standard,capacity:1}" \
    --output none


# =============================================================================
# STEP 6: CREATE THE NAMESPACE TOPIC
# =============================================================================

echo "Creating namespace topic: ${TOPIC_NAME}"

az eventgrid namespace topic create \
    --name "${TOPIC_NAME}" \
    --namespace-name "${NAMESPACE_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --event-retention-in-days 1 \
    --publisher-type Custom \
    --input-schema CloudEventSchemaV1_0 \
    --output none


# =============================================================================
# STEP 7: CREATE THE FLAGGED-EVENTS SUBSCRIPTION
# =============================================================================

echo "Creating subscription: ${SUB_FLAGGED}"

az eventgrid namespace topic event-subscription create \
    --name "${SUB_FLAGGED}" \
    --namespace-name "${NAMESPACE_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --topic-name "${TOPIC_NAME}" \
    --delivery-configuration "${DELIVERY_CONFIG}" \
    --event-delivery-schema CloudEventSchemaV1_0 \
    --filters-configuration "${FLAGGED_FILTER}" \
    --output none


# =============================================================================
# STEP 8: CREATE THE APPROVED-EVENTS SUBSCRIPTION
# =============================================================================

echo "Creating subscription: ${SUB_APPROVED}"

az eventgrid namespace topic event-subscription create \
    --name "${SUB_APPROVED}" \
    --namespace-name "${NAMESPACE_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --topic-name "${TOPIC_NAME}" \
    --delivery-configuration "${DELIVERY_CONFIG}" \
    --event-delivery-schema CloudEventSchemaV1_0 \
    --filters-configuration "${APPROVED_FILTER}" \
    --output none


# =============================================================================
# STEP 9: CREATE THE ALL-EVENTS SUBSCRIPTION
# =============================================================================

echo "Creating subscription: ${SUB_ALL}"

az eventgrid namespace topic event-subscription create \
    --name "${SUB_ALL}" \
    --namespace-name "${NAMESPACE_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --topic-name "${TOPIC_NAME}" \
    --delivery-configuration "${DELIVERY_CONFIG}" \
    --event-delivery-schema CloudEventSchemaV1_0 \
    --output none


# =============================================================================
# STEP 10: RETRIEVE THE NAMESPACE RESOURCE ID
# =============================================================================

NAMESPACE_ID=$(az eventgrid namespace show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${NAMESPACE_NAME}" \
    --query "id" \
    --output tsv)


# =============================================================================
# STEP 11: ASSIGN EVENT GRID ROLES
# =============================================================================

echo "Assigning ${SENDER_ROLE} role..."

az role assignment create \
    --role "${SENDER_ROLE}" \
    --assignee-object-id "${USER_OBJECT_ID}" \
    --assignee-principal-type User \
    --scope "${NAMESPACE_ID}" \
    --output none

echo "Assigning ${RECEIVER_ROLE} role..."

az role assignment create \
    --role "${RECEIVER_ROLE}" \
    --assignee-object-id "${USER_OBJECT_ID}" \
    --assignee-principal-type User \
    --scope "${NAMESPACE_ID}" \
    --output none


    


# =============================================================================
# STEP 12: RETRIEVE CONNECTION INFORMATION
# =============================================================================

NAMESPACE_HOSTNAME=$(az eventgrid namespace show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${NAMESPACE_NAME}" \
    --query "topicsConfiguration.hostname" \
    --output tsv)

EVENTGRID_ENDPOINT="https://${NAMESPACE_HOSTNAME}"


# =============================================================================
# STEP 13: SAVE BASH ENVIRONMENT VARIABLES
# =============================================================================

cat > .env <<EOF
export RANDOM_SUFFIX="${RANDOM_SUFFIX}"
export RESOURCE_GROUP="${RESOURCE_GROUP}"

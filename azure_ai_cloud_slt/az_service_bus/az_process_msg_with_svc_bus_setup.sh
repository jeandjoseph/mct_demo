#!/bin/bash

# ==========================================================
# VARIABLES - UPDATE THESE VALUES
# ==========================================================
RANDOM_SUFFIX=$(tr -dc 'a-z0-9' </dev/urandom | head -c 5)    # keeps globally-unique names unique
RG="az-svc-bus-demo-$RANDOM_SUFFIX"
LOCATION="westus3"

# Service Bus Namespace
NAMESPACE_NAME="az-event-driven-$RANDOM_SUFFIX"

# Messaging Entities
QUEUE_NAME="inference-requests"

TOPIC_NAME="inference-results"

NOTIFICATIONS_SUBSCRIPTION="notifications"

HIGH_PRIORITY_SUBSCRIPTION="high-priority"

HIGH_PRIORITY_RULE="high-priority-filter"

HIGH_PRIORITY_FILTER="priority = 'high'"

# ==========================================================
# LOGIN
# ==========================================================

az login

az provider register --namespace Microsoft.ServiceBus

# ==========================================================
# CREATE RESOURCE GROUP
# ==========================================================

az group create \
  --name $RG \
  --location $LOCATION

# ==========================================================
# CREATE SERVICE BUS NAMESPACE (STANDARD SKU REQUIRED)
# ==========================================================

az servicebus namespace create \
  --name $NAMESPACE_NAME \
  --resource-group $RG \
  --location $LOCATION \
  --sku Standard

# ==========================================================
# VERIFY NAMESPACE IS READY
# ==========================================================

az servicebus namespace show \
  --name $NAMESPACE_NAME \
  --resource-group $RG \
  --query provisioningState \
  --output table

# ==========================================================
# CREATE QUEUE
# ==========================================================

az servicebus queue create \
  --name $QUEUE_NAME \
  --namespace-name $NAMESPACE_NAME \
  --resource-group $RG \
  --max-delivery-count 5 \
  --enable-dead-lettering-on-message-expiration true

# ==========================================================
# CREATE TOPIC
# ==========================================================

az servicebus topic create \
  --name $TOPIC_NAME \
  --namespace-name $NAMESPACE_NAME \
  --resource-group $RG

# ==========================================================
# CREATE NOTIFICATIONS SUBSCRIPTION
# ==========================================================

az servicebus topic subscription create \
  --name $NOTIFICATIONS_SUBSCRIPTION \
  --topic-name $TOPIC_NAME \
  --namespace-name $NAMESPACE_NAME \
  --resource-group $RG

# ==========================================================
# CREATE HIGH PRIORITY SUBSCRIPTION
# ==========================================================

az servicebus topic subscription create \
  --name $HIGH_PRIORITY_SUBSCRIPTION \
  --topic-name $TOPIC_NAME \
  --namespace-name $NAMESPACE_NAME \
  --resource-group $RG

# ==========================================================
# REMOVE DEFAULT RULE
# ==========================================================

az servicebus topic subscription rule delete \
  --name '$Default' \
  --subscription-name $HIGH_PRIORITY_SUBSCRIPTION \
  --topic-name $TOPIC_NAME \
  --namespace-name $NAMESPACE_NAME \
  --resource-group $RG

# ==========================================================
# CREATE SQL FILTER
# Only messages where priority='high'
# ==========================================================

az servicebus topic subscription rule create \
  --name $HIGH_PRIORITY_RULE \
  --subscription-name $HIGH_PRIORITY_SUBSCRIPTION \
  --topic-name $TOPIC_NAME \
  --namespace-name $NAMESPACE_NAME \
  --resource-group $RG \
  --filter-sql-expression "$HIGH_PRIORITY_FILTER"

# ==========================================================
# ASSIGN SERVICE BUS DATA OWNER ROLE
# ==========================================================

USER_OBJECT_ID=$(az ad signed-in-user show \
  --query id \
  --output tsv)

NAMESPACE_ID=$(az servicebus namespace show \
  --name $NAMESPACE_NAME \
  --resource-group $RG \
  --query id \
  --output tsv)

az role assignment create \
  --assignee $USER_OBJECT_ID \
  --role "Azure Service Bus Data Owner" \
  --scope $NAMESPACE_ID

# ==========================================================
# SERVICE BUS FQDN
# Used with Entra ID / DefaultAzureCredential
# ==========================================================

SERVICE_BUS_FQDN="${NAMESPACE_NAME}.servicebus.windows.net"

echo ""
echo "========================================="
echo "Deployment Complete"
echo "========================================="
echo "Service Bus FQDN: $SERVICE_BUS_FQDN"
echo ""

#echo "export SERVICE_BUS_FQDN=$SERVICE_BUS_FQDN" > .env

# ==========================================================
# VALIDATION
# ==========================================================

echo "===== QUEUE ====="
az servicebus queue show \
  --name $QUEUE_NAME \
  --namespace-name $NAMESPACE_NAME \
  --resource-group $RG \
  --output table

echo "===== TOPIC ====="
az servicebus topic show \
  --name $TOPIC_NAME \
  --namespace-name $NAMESPACE_NAME \
  --resource-group $RG \
  --output table

echo "===== SUBSCRIPTIONS ====="
az servicebus topic subscription list \
  --topic-name $TOPIC_NAME \
  --namespace-name $NAMESPACE_NAME \
  --resource-group $RG \
  --output table

echo "===== SQL FILTER ====="
az servicebus topic subscription rule show \
  --name $HIGH_PRIORITY_RULE \
  --subscription-name $HIGH_PRIORITY_SUBSCRIPTION \
  --topic-name $TOPIC_NAME \
  --namespace-name $NAMESPACE_NAME \
  --resource-group $RG



# ==========================================================
# ADD GENERATED VALUES TO .ENV
# ==========================================================

USER_OBJECT_ID=$(az ad signed-in-user show \
  --query id \
  --output tsv)

NAMESPACE_ID=$(az servicebus namespace show \
  --name $NAMESPACE_NAME \
  --resource-group $RG \
  --query id \
  --output tsv)

SERVICE_BUS_FQDN="${NAMESPACE_NAME}.servicebus.windows.net"

# ==========================================================
# APPEND RUNTIME VALUES TO CLIENT ENV FILE
# ==========================================================

cat >> ./client/.env <<EOF

# Azure Service Bus Runtime Values
USER_OBJECT_ID=$USER_OBJECT_ID
NAMESPACE_ID=$NAMESPACE_ID
SERVICE_BUS_FQDN=$SERVICE_BUS_FQDN

EOF

echo "Runtime variables appended to ./client/.env"

# POWERSHELL
cd client

python3 -m venv .venv
source .venv/bin/activate

python -m ensurepip --upgrade
python -m pip install --upgrade pip setuptools wheel

python -m pip install -r requirements.txt


python app.py 


# Clean up resources
az group delete --name $RG --no-wait --yes
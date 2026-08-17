#!/usr/bin/env bash
###############################################################################
# Azure Cosmos DB for NoSQL — End-to-End RAG Demo
#
# What this script does, in order:
#   1. Logs in to Azure and sets the subscription
#   2. Creates a resource group
#   3. Creates a Cosmos DB for NoSQL account (serverless) with the
#      EnableNoSQLVectorSearch capability turned on
#   4. Grants your signed-in user the "Cosmos DB Built-in Data Contributor"
#      data-plane RBAC role (so the Python scripts can read/write data
#      using Azure AD auth instead of keys)
#   5. Creates a SQL database and a container with a vector embedding policy
#      + vector index policy (container-level vector search config)
#   6. Creates an Azure OpenAI resource and deploys an embedding model
#      (text-embedding-3-small) and a chat model (gpt-4o-mini)
#   7. Generates saleshistory.json — 27 realistic sales transactions across
#      5 products (NO vector embeddings in this file — those only ever live
#      inside the Cosmos DB container)
#   8. Loads saleshistory.json, calls Azure OpenAI to embed each transaction's
#      review text, and upserts every item (data + vector) into the container
#   9. Runs a couple of sample RAG queries: vector search (VectorDistance)
#      for retrieval + a grounded chat completion for the answer
#
# Reference docs reviewed before writing this script:
#   https://learn.microsoft.com/azure/cosmos-db/vector-search
#   https://learn.microsoft.com/azure/cosmos-db/how-to-python-vector-index-query
#   https://learn.microsoft.com/cli/azure/cosmosdb/sql/container
#   https://learn.microsoft.com/azure/cosmos-db/nosql/how-to-grant-data-plane-access
#   https://learn.microsoft.com/azure/foundry/openai/how-to/embeddings
#
# Prerequisites:
#   - Azure CLI (az) installed, version 2.60+
#   - Python 3.9+
#   - An Azure subscription that can create Azure OpenAI resources
#     (Azure OpenAI access may require approval on some subscriptions)
#
# This script is written to be re-run safely for most steps. The one
# exception is the container: a container's vector policy can never be
# changed after creation, so the script only creates it if it doesn't
# already exist.
###############################################################################

set -euo pipefail


#ref: mct_demo/tree/main/azure_ai_200/cosmos-nosql-rag-webapp

###############################################################################
# STEP 0 — EDIT THESE VALUES before running
###############################################################################
SUBSCRIPTION_ID=""                          # leave blank to use current az subscription
LOCATION="eastus2"                          # region for Cosmos DB + Azure OpenAI
RANDOM_SUFFIX=$(tr -dc 'a-z0-9' </dev/urandom | head -c 5)    # keeps globally-unique names unique
RESOURCE_GROUP="rg-cosmos-rag-demo-${RANDOM_SUFFIX}"

COSMOS_ACCOUNT="cosmos-rag-demo-${RANDOM_SUFFIX}"
COSMOS_DATABASE="salesdb"
COSMOS_CONTAINER="transactions"
PARTITION_KEY_PATH="/productId"

OPENAI_ACCOUNT="aoai-rag-demo-${RANDOM_SUFFIX}"
EMBEDDING_DEPLOYMENT="text-embedding-3-small"
EMBEDDING_MODEL_NAME="text-embedding-3-small"
EMBEDDING_MODEL_VERSION="1"
EMBEDDING_DIMENSIONS=256                    # kept small so a 'flat' (exact) index can be used

CHAT_DEPLOYMENT="gpt-5-nano"
CHAT_MODEL_NAME="gpt-5-nano"
CHAT_MODEL_VERSION="2025-08-07"

WORK_DIR="$(pwd)/cosmosdb"
VENV_DIR="${WORK_DIR}/.venv"
SALES_DATA_FILE="saleshistory.json"

step() { echo; echo "==> $1"; echo; }

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

###############################################################################
# STEP 1 — Prerequisite checks
###############################################################################
step "STEP 1: Checking prerequisites"
command -v az >/dev/null 2>&1 || { echo "Azure CLI (az) not found. Install it first."; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found. Install it first."; exit 1; }
echo "az and python3 found."

###############################################################################
# STEP 2 — Log in to Azure
###############################################################################
step "STEP 2: Logging in to Azure"
az account show >/dev/null 2>&1 || az login

if [ -n "$SUBSCRIPTION_ID" ]; then
  az account set --subscription "$SUBSCRIPTION_ID"
fi
echo "Using subscription: $(az account show --query name -o tsv)"

###############################################################################
# STEP 3 — Resource group
###############################################################################
step "STEP 3: Creating resource group '$RESOURCE_GROUP'"
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output none
echo "Resource group ready."

###############################################################################
# STEP 4 — Register required resource providers (usually already registered)
###############################################################################
step "STEP 4: Registering resource providers"
az provider register --namespace Microsoft.DocumentDB --wait
az provider register --namespace Microsoft.CognitiveServices --wait
echo "Providers registered."

###############################################################################
# STEP 5 — Create the Cosmos DB for NoSQL account with vector search enabled
###############################################################################
step "STEP 5: Creating Cosmos DB account '$COSMOS_ACCOUNT' (serverless + vector search)"
if az cosmosdb show --name "$COSMOS_ACCOUNT" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
  echo "Cosmos DB account already exists, skipping creation."
else
  az cosmosdb create \
    --name "$COSMOS_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --locations regionName="$LOCATION" failoverPriority=0 isZoneRedundant=false \
    --default-consistency-level Session \
    --capabilities EnableServerless EnableNoSQLVectorSearch \
    --output none
  echo "Cosmos DB account created."
fi

# Registration of EnableNoSQLVectorSearch is auto-approved but can take up to
# ~15 minutes to fully take effect. If container creation below fails with a
# vector-policy error, wait a few minutes and re-run the script.

COSMOS_ENDPOINT=$(az cosmosdb show \
  --name "$COSMOS_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --query "documentEndpoint" -o tsv)
echo "Cosmos DB endpoint: $COSMOS_ENDPOINT"

###############################################################################
# STEP 6 — Grant yourself data-plane RBAC access (no keys needed)
###############################################################################
step "STEP 6: Assigning 'Cosmos DB Built-in Data Contributor' role to your account"
PRINCIPAL_ID=$(az ad signed-in-user show --query id -o tsv)

# 00000000-0000-0000-0000-000000000002 is the fixed, built-in ID for the
# "Cosmos DB Built-in Data Contributor" role in every Cosmos DB account.
if az cosmosdb sql role assignment list \
    --account-name "$COSMOS_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --query "[?principalId=='${PRINCIPAL_ID}']" -o tsv | grep -q .; then
  echo "Role assignment already exists, skipping."
else
  az cosmosdb sql role assignment create \
    --account-name "$COSMOS_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --role-definition-id "00000000-0000-0000-0000-000000000002" \
    --principal-id "$PRINCIPAL_ID" \
    --scope "/" \
    --output none
  echo "Data-plane role assigned."
fi

###############################################################################
# STEP 7 — Create the SQL database
###############################################################################
step "STEP 7: Creating database '$COSMOS_DATABASE'"
az cosmosdb sql database create \
  --account-name "$COSMOS_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --name "$COSMOS_DATABASE" \
  --output none
echo "Database ready."

###############################################################################
# STEP 8 — Create the container with a vector embedding policy + vector index
###############################################################################
step "STEP 8: Creating container '$COSMOS_CONTAINER' with vector search config"

if az cosmosdb sql container show \
    --account-name "$COSMOS_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --database-name "$COSMOS_DATABASE" \
    --name "$COSMOS_CONTAINER" >/dev/null 2>&1; then
  echo "Container already exists (vector policies can't be changed after creation), skipping."
else
  # Container vector policy: tells Cosmos DB there is a vector at
  # /reviewTextVector, its data type, dimensions, and distance function.
  cat > vector-policy.json << EOF
{
    "vectorEmbeddings": [
        {
            "path": "/reviewTextVector",
            "dataType": "float32",
            "distanceFunction": "cosine",
            "dimensions": ${EMBEDDING_DIMENSIONS}
        }
    ]
}
EOF

  # Indexing policy: adds a 'flat' (exact / brute-force, 100% recall) vector
  # index on that same path, and excludes the raw vector array from the
  # normal property index (recommended — cuts RU cost on writes).
  cat > index-policy.json << 'EOF'
{
    "indexingMode": "consistent",
    "automatic": true,
    "includedPaths": [
        { "path": "/*" }
    ],
    "excludedPaths": [
        { "path": "/reviewTextVector/*" },
        { "path": "/\"_etag\"/?" }
    ],
    "vectorIndexes": [
        { "path": "/reviewTextVector", "type": "flat" }
    ]
}
EOF

  az cosmosdb sql container create \
    --account-name "$COSMOS_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --database-name "$COSMOS_DATABASE" \
    --name "$COSMOS_CONTAINER" \
    --partition-key-path "$PARTITION_KEY_PATH" \
    --idx @index-policy.json \
    --vector-embeddings @vector-policy.json \
    --output none
  echo "Container created with vector search enabled."
fi

###############################################################################
# STEP 9 — Create the Azure OpenAI resource
###############################################################################
step "STEP 9: Creating Azure OpenAI resource '$OPENAI_ACCOUNT'"
if az cognitiveservices account show --name "$OPENAI_ACCOUNT" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
  echo "Azure OpenAI resource already exists, skipping creation."
else
  az cognitiveservices account create \
    --name "$OPENAI_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --kind OpenAI \
    --sku S0 \
    --custom-domain "$OPENAI_ACCOUNT" \
    --yes \
    --output none
  echo "Azure OpenAI resource created."
fi

###############################################################################
# STEP 10 — Deploy the embedding model and the chat model
###############################################################################
step "STEP 10: Deploying models"

deploy_model_if_missing() {
  local deployment_name="$1" model_name="$2" model_version="$3" capacity="$4"
  if az cognitiveservices account deployment show \
      --name "$OPENAI_ACCOUNT" --resource-group "$RESOURCE_GROUP" \
      --deployment-name "$deployment_name" >/dev/null 2>&1; then
    echo "Deployment '$deployment_name' already exists, skipping."
  else
    az cognitiveservices account deployment create \
      --name "$OPENAI_ACCOUNT" \
      --resource-group "$RESOURCE_GROUP" \
      --deployment-name "$deployment_name" \
      --model-name "$model_name" \
      --model-version "$model_version" \
      --model-format OpenAI \
      --sku-name "Standard" \
      --sku-capacity "$capacity" \
      --output none
    echo "Deployed '$deployment_name'."
  fi
}

deploy_model_if_missing "$EMBEDDING_DEPLOYMENT" "$EMBEDDING_MODEL_NAME" "$EMBEDDING_MODEL_VERSION" 30
deploy_model_if_missing "$CHAT_DEPLOYMENT" "$CHAT_MODEL_NAME" "$CHAT_MODEL_VERSION" 10

AOAI_ENDPOINT=$(az cognitiveservices account show \
  --name "$OPENAI_ACCOUNT" --resource-group "$RESOURCE_GROUP" \
  --query "properties.endpoint" -o tsv)
AOAI_KEY=$(az cognitiveservices account keys list \
  --name "$OPENAI_ACCOUNT" --resource-group "$RESOURCE_GROUP" \
  --query "key1" -o tsv)
echo "Azure OpenAI endpoint: $AOAI_ENDPOINT"

###############################################################################
# STEP 11 — Generate saleshistory.json (5 products, 27 transactions, NO vectors)
###############################################################################
step "STEP 11: Generating $SALES_DATA_FILE"

cat > "$SALES_DATA_FILE" << 'EOF'
[
  {"id":"TXN-0001","transactionId":"TXN-0001","productId":"SKU-BIKE-001","productName":"TrailBlazer 27-Speed Mountain Bike","category":"Outdoor & Sports","unitPrice":549.99,"quantity":1,"totalAmount":549.99,"currency":"USD","transactionDate":"2026-01-08","customerId":"CUST-1001","customerName":"Emily Carter","city":"Denver","state":"CO","channel":"Online","paymentMethod":"Credit Card","reviewRating":5,"reviewText":"Shifting is smooth even on steep gravel climbs, and the 27-speed range covers everything from city commuting to mountain trails."},
  {"id":"TXN-0002","transactionId":"TXN-0002","productId":"SKU-BIKE-001","productName":"TrailBlazer 27-Speed Mountain Bike","category":"Outdoor & Sports","unitPrice":549.99,"quantity":1,"totalAmount":549.99,"currency":"USD","transactionDate":"2026-02-14","customerId":"CUST-1002","customerName":"Marcus Lee","city":"Boulder","state":"CO","channel":"In-Store","paymentMethod":"Debit Card","reviewRating":4,"reviewText":"Great value bike overall, though the stock seat could use more padding for long rides."},
  {"id":"TXN-0003","transactionId":"TXN-0003","productId":"SKU-BIKE-001","productName":"TrailBlazer 27-Speed Mountain Bike","category":"Outdoor & Sports","unitPrice":549.99,"quantity":2,"totalAmount":1099.98,"currency":"USD","transactionDate":"2026-03-02","customerId":"CUST-1003","customerName":"Priya Nair","city":"Fort Collins","state":"CO","channel":"Online","paymentMethod":"PayPal","reviewRating":5,"reviewText":"Bought one for me and one for my partner. Assembly was easy and the disc brakes feel very responsive."},
  {"id":"TXN-0004","transactionId":"TXN-0004","productId":"SKU-BIKE-001","productName":"TrailBlazer 27-Speed Mountain Bike","category":"Outdoor & Sports","unitPrice":549.99,"quantity":1,"totalAmount":549.99,"currency":"USD","transactionDate":"2026-04-19","customerId":"CUST-1004","customerName":"Diego Ramirez","city":"Colorado Springs","state":"CO","channel":"Online","paymentMethod":"Credit Card","reviewRating":3,"reviewText":"Frame quality is solid but the rear derailleur needed adjustment right out of the box."},
  {"id":"TXN-0005","transactionId":"TXN-0005","productId":"SKU-BIKE-001","productName":"TrailBlazer 27-Speed Mountain Bike","category":"Outdoor & Sports","unitPrice":549.99,"quantity":1,"totalAmount":549.99,"currency":"USD","transactionDate":"2026-05-27","customerId":"CUST-1005","customerName":"Hannah Kim","city":"Denver","state":"CO","channel":"In-Store","paymentMethod":"Gift Card","reviewRating":5,"reviewText":"Perfect for weekend trail rides. Tires grip well on loose dirt and the suspension soaks up bumps nicely."},
  {"id":"TXN-0006","transactionId":"TXN-0006","productId":"SKU-BIKE-001","productName":"TrailBlazer 27-Speed Mountain Bike","category":"Outdoor & Sports","unitPrice":549.99,"quantity":1,"totalAmount":549.99,"currency":"USD","transactionDate":"2026-06-30","customerId":"CUST-1006","customerName":"Owen Fisher","city":"Aurora","state":"CO","channel":"Online","paymentMethod":"Apple Pay","reviewRating":4,"reviewText":"Sturdy build for the price, just wish it shipped with pedals already attached."},

  {"id":"TXN-0007","transactionId":"TXN-0007","productId":"SKU-COFF-002","productName":"AeroBrew Programmable Coffee Maker","category":"Home Appliances","unitPrice":79.99,"quantity":1,"totalAmount":79.99,"currency":"USD","transactionDate":"2026-01-11","customerId":"CUST-1007","customerName":"Laura Bennett","city":"Austin","state":"TX","channel":"Online","paymentMethod":"Credit Card","reviewRating":5,"reviewText":"The programmable timer means I wake up to fresh coffee every morning without lifting a finger."},
  {"id":"TXN-0008","transactionId":"TXN-0008","productId":"SKU-COFF-002","productName":"AeroBrew Programmable Coffee Maker","category":"Home Appliances","unitPrice":79.99,"quantity":1,"totalAmount":79.99,"currency":"USD","transactionDate":"2026-02-05","customerId":"CUST-1008","customerName":"Kevin Zhao","city":"Round Rock","state":"TX","channel":"In-Store","paymentMethod":"Debit Card","reviewRating":4,"reviewText":"Brews a full pot quickly, but the carafe lid drips a little when pouring."},
  {"id":"TXN-0009","transactionId":"TXN-0009","productId":"SKU-COFF-002","productName":"AeroBrew Programmable Coffee Maker","category":"Home Appliances","unitPrice":79.99,"quantity":2,"totalAmount":159.98,"currency":"USD","transactionDate":"2026-03-16","customerId":"CUST-1009","customerName":"Sofia Martinez","city":"San Antonio","state":"TX","channel":"Online","paymentMethod":"PayPal","reviewRating":5,"reviewText":"Bought a second one as a gift. The auto shut-off feature gives real peace of mind."},
  {"id":"TXN-0010","transactionId":"TXN-0010","productId":"SKU-COFF-002","productName":"AeroBrew Programmable Coffee Maker","category":"Home Appliances","unitPrice":79.99,"quantity":1,"totalAmount":79.99,"currency":"USD","transactionDate":"2026-04-22","customerId":"CUST-1010","customerName":"Brian O'Connell","city":"Austin","state":"TX","channel":"Online","paymentMethod":"Credit Card","reviewRating":3,"reviewText":"Works fine but the display buttons feel a bit cheap and unresponsive at times."},
  {"id":"TXN-0011","transactionId":"TXN-0011","productId":"SKU-COFF-002","productName":"AeroBrew Programmable Coffee Maker","category":"Home Appliances","unitPrice":79.99,"quantity":1,"totalAmount":79.99,"currency":"USD","transactionDate":"2026-05-30","customerId":"CUST-1011","customerName":"Natalie Wong","city":"Houston","state":"TX","channel":"In-Store","paymentMethod":"Gift Card","reviewRating":4,"reviewText":"Easy to clean and the coffee strength selector actually makes a noticeable difference."},

  {"id":"TXN-0012","transactionId":"TXN-0012","productId":"SKU-LAPT-003","productName":"NovaBook Pro 14-inch Laptop","category":"Electronics","unitPrice":1299.99,"quantity":1,"totalAmount":1299.99,"currency":"USD","transactionDate":"2026-01-14","customerId":"CUST-1012","customerName":"Jordan Blake","city":"Seattle","state":"WA","channel":"Online","paymentMethod":"Credit Card","reviewRating":5,"reviewText":"Handles my video editing workflow effortlessly and the battery easily lasts a full workday."},
  {"id":"TXN-0013","transactionId":"TXN-0013","productId":"SKU-LAPT-003","productName":"NovaBook Pro 14-inch Laptop","category":"Electronics","unitPrice":1299.99,"quantity":1,"totalAmount":1299.99,"currency":"USD","transactionDate":"2026-02-09","customerId":"CUST-1013","customerName":"Amara Johnson","city":"Portland","state":"OR","channel":"Online","paymentMethod":"Apple Pay","reviewRating":4,"reviewText":"Fast and lightweight, though it does run warm under heavy multitasking."},
  {"id":"TXN-0014","transactionId":"TXN-0014","productId":"SKU-LAPT-003","productName":"NovaBook Pro 14-inch Laptop","category":"Electronics","unitPrice":1299.99,"quantity":1,"totalAmount":1299.99,"currency":"USD","transactionDate":"2026-03-21","customerId":"CUST-1014","customerName":"Ethan Park","city":"Seattle","state":"WA","channel":"In-Store","paymentMethod":"Debit Card","reviewRating":2,"reviewText":"Battery life dropped noticeably after a few weeks of daily use, expected more for this price."},
  {"id":"TXN-0015","transactionId":"TXN-0015","productId":"SKU-LAPT-003","productName":"NovaBook Pro 14-inch Laptop","category":"Electronics","unitPrice":1299.99,"quantity":1,"totalAmount":1299.99,"currency":"USD","transactionDate":"2026-04-05","customerId":"CUST-1015","customerName":"Grace Thompson","city":"Bellevue","state":"WA","channel":"Online","paymentMethod":"Credit Card","reviewRating":5,"reviewText":"The screen is gorgeous for photo editing and the keyboard feels premium to type on."},
  {"id":"TXN-0016","transactionId":"TXN-0016","productId":"SKU-LAPT-003","productName":"NovaBook Pro 14-inch Laptop","category":"Electronics","unitPrice":1299.99,"quantity":1,"totalAmount":1299.99,"currency":"USD","transactionDate":"2026-05-17","customerId":"CUST-1002","customerName":"Marcus Lee","city":"Boulder","state":"CO","channel":"Online","paymentMethod":"PayPal","reviewRating":4,"reviewText":"Boots up in seconds and the fingerprint login is convenient, just wish it had more ports."},
  {"id":"TXN-0017","transactionId":"TXN-0017","productId":"SKU-LAPT-003","productName":"NovaBook Pro 14-inch Laptop","category":"Electronics","unitPrice":1299.99,"quantity":1,"totalAmount":1299.99,"currency":"USD","transactionDate":"2026-06-24","customerId":"CUST-1016","customerName":"Isabella Rossi","city":"Tacoma","state":"WA","channel":"In-Store","paymentMethod":"Credit Card","reviewRating":3,"reviewText":"Decent performance for everyday tasks but the fan gets loud during video calls."},

  {"id":"TXN-0018","transactionId":"TXN-0018","productId":"SKU-YOGA-004","productName":"ZenFlex Adjustable Yoga Mat Set","category":"Fitness & Wellness","unitPrice":39.99,"quantity":1,"totalAmount":39.99,"currency":"USD","transactionDate":"2026-01-20","customerId":"CUST-1017","customerName":"Chloe Dubois","city":"San Diego","state":"CA","channel":"Online","paymentMethod":"Credit Card","reviewRating":5,"reviewText":"The extra cushioning is a game changer for my knees during floor poses."},
  {"id":"TXN-0019","transactionId":"TXN-0019","productId":"SKU-YOGA-004","productName":"ZenFlex Adjustable Yoga Mat Set","category":"Fitness & Wellness","unitPrice":39.99,"quantity":2,"totalAmount":79.98,"currency":"USD","transactionDate":"2026-02-27","customerId":"CUST-1018","customerName":"Ryan Patel","city":"Los Angeles","state":"CA","channel":"Online","paymentMethod":"PayPal","reviewRating":4,"reviewText":"Good grip during hot yoga sessions, though it retains a slight rubber smell at first."},
  {"id":"TXN-0020","transactionId":"TXN-0020","productId":"SKU-YOGA-004","productName":"ZenFlex Adjustable Yoga Mat Set","category":"Fitness & Wellness","unitPrice":39.99,"quantity":1,"totalAmount":39.99,"currency":"USD","transactionDate":"2026-03-30","customerId":"CUST-1019","customerName":"Megan Foster","city":"San Diego","state":"CA","channel":"In-Store","paymentMethod":"Debit Card","reviewRating":5,"reviewText":"Comes with resistance bands and a carrying strap, excellent value for a home studio setup."},
  {"id":"TXN-0021","transactionId":"TXN-0021","productId":"SKU-YOGA-004","productName":"ZenFlex Adjustable Yoga Mat Set","category":"Fitness & Wellness","unitPrice":39.99,"quantity":1,"totalAmount":39.99,"currency":"USD","transactionDate":"2026-04-14","customerId":"CUST-1020","customerName":"Aiden Brooks","city":"Irvine","state":"CA","channel":"Online","paymentMethod":"Gift Card","reviewRating":3,"reviewText":"Mat is comfortable but started curling at the edges after a month of daily use."},
  {"id":"TXN-0022","transactionId":"TXN-0022","productId":"SKU-YOGA-004","productName":"ZenFlex Adjustable Yoga Mat Set","category":"Fitness & Wellness","unitPrice":39.99,"quantity":1,"totalAmount":39.99,"currency":"USD","transactionDate":"2026-05-08","customerId":"CUST-1021","customerName":"Zoe Nakamura","city":"San Diego","state":"CA","channel":"Online","paymentMethod":"Credit Card","reviewRating":5,"reviewText":"Non-slip surface holds up even when I'm sweating through an intense session."},

  {"id":"TXN-0023","transactionId":"TXN-0023","productId":"SKU-BACK-005","productName":"UrbanTrek Waterproof Backpack","category":"Outdoor & Accessories","unitPrice":89.99,"quantity":1,"totalAmount":89.99,"currency":"USD","transactionDate":"2026-01-25","customerId":"CUST-1022","customerName":"Liam O'Brien","city":"Denver","state":"CO","channel":"Online","paymentMethod":"Credit Card","reviewRating":5,"reviewText":"Stayed completely dry during a rainy hike, the roll-top closure really works."},
  {"id":"TXN-0024","transactionId":"TXN-0024","productId":"SKU-BACK-005","productName":"UrbanTrek Waterproof Backpack","category":"Outdoor & Accessories","unitPrice":89.99,"quantity":1,"totalAmount":89.99,"currency":"USD","transactionDate":"2026-02-19","customerId":"CUST-1023","customerName":"Fatima Ahmed","city":"Salt Lake City","state":"UT","channel":"In-Store","paymentMethod":"Debit Card","reviewRating":4,"reviewText":"Plenty of compartments for gear organization, though the hip belt buckle feels a bit flimsy."},
  {"id":"TXN-0025","transactionId":"TXN-0025","productId":"SKU-BACK-005","productName":"UrbanTrek Waterproof Backpack","category":"Outdoor & Accessories","unitPrice":89.99,"quantity":1,"totalAmount":89.99,"currency":"USD","transactionDate":"2026-03-11","customerId":"CUST-1024","customerName":"Noah Sullivan","city":"Boise","state":"ID","channel":"Online","paymentMethod":"Apple Pay","reviewRating":5,"reviewText":"Padded straps make it comfortable even on long treks with a full load."},
  {"id":"TXN-0026","transactionId":"TXN-0026","productId":"SKU-BACK-005","productName":"UrbanTrek Waterproof Backpack","category":"Outdoor & Accessories","unitPrice":89.99,"quantity":2,"totalAmount":179.98,"currency":"USD","transactionDate":"2026-04-28","customerId":"CUST-1025","customerName":"Aria Kowalski","city":"Denver","state":"CO","channel":"Online","paymentMethod":"PayPal","reviewRating":4,"reviewText":"Durable material held up great on rocky terrain, just wish it had a built-in rain cover."},
  {"id":"TXN-0027","transactionId":"TXN-0027","productId":"SKU-BACK-005","productName":"UrbanTrek Waterproof Backpack","category":"Outdoor & Accessories","unitPrice":89.99,"quantity":1,"totalAmount":89.99,"currency":"USD","transactionDate":"2026-06-02","customerId":"CUST-1026","customerName":"Evan Whitfield","city":"Colorado Springs","state":"CO","channel":"In-Store","paymentMethod":"Credit Card","reviewRating":5,"reviewText":"Waterproof zippers and reflective strips make this perfect for early morning trail runs."}
]
EOF

echo "Generated $(python3 -c "import json;print(len(json.load(open('$SALES_DATA_FILE'))))") transactions in $SALES_DATA_FILE"


###############################################################################
# STEP 12 — Write the embedding/load script
###############################################################################
step "STEP 13: Writing load_and_embed.py"
cat > load_and_embed.py << 'PYEOF'
"""
Reads saleshistory.json, calls Azure OpenAI to create a vector embedding for
each transaction's review text, and upserts every item (original data +
embedding) into the Cosmos DB container. The source JSON file itself never
contains embeddings -- they only exist once written into Cosmos DB.
"""
import json
import os

from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential
from openai import AzureOpenAI

# .strip() guards against hidden \r/\n/space characters that can end up in
# these values when they're captured from CLI output (a common issue on
# Windows/WSL setups where a Windows-native az.exe returns CRLF line endings).
# An un-stripped endpoint causes a confusing "Bad Request - Invalid URL" error.
COSMOS_ENDPOINT = os.environ["COSMOS_ENDPOINT"].strip()
DATABASE_NAME = os.environ["COSMOS_DATABASE"].strip()
CONTAINER_NAME = os.environ["COSMOS_CONTAINER"].strip()

AOAI_ENDPOINT = os.environ["AOAI_ENDPOINT"].strip()
AOAI_KEY = os.environ["AOAI_KEY"].strip()
AOAI_EMBED_DEPLOYMENT = os.environ["AOAI_EMBED_DEPLOYMENT"].strip()
EMBED_DIMENSIONS = int(os.environ.get("EMBED_DIMENSIONS", "256"))

DATA_FILE = os.environ.get("SALES_DATA_FILE", "saleshistory.json")


def main():
    # Cosmos DB: authenticate with Azure AD, using the RBAC role the
    # deploy script already assigned to your signed-in user -- no keys.
    cosmos_client = CosmosClient(url=COSMOS_ENDPOINT, credential=DefaultAzureCredential())
    container = cosmos_client.get_database_client(DATABASE_NAME).get_container_client(CONTAINER_NAME)

    aoai_client = AzureOpenAI(
        azure_endpoint=AOAI_ENDPOINT,
        api_key=AOAI_KEY,
        api_version="2024-06-01",
    )

    with open(DATA_FILE, "r", encoding="utf-8") as f:
        transactions = json.load(f)

    print(f"Loaded {len(transactions)} transactions from {DATA_FILE}")

    for i, txn in enumerate(transactions, start=1):
        embed_source = (
            f"Product: {txn['productName']}. "
            f"Category: {txn['category']}. "
            f"Customer rating: {txn['reviewRating']} out of 5. "
            f"Review: {txn['reviewText']}"
        )

        response = aoai_client.embeddings.create(
            input=embed_source,
            model=AOAI_EMBED_DEPLOYMENT,
            dimensions=EMBED_DIMENSIONS,
        )
        vector = response.data[0].embedding

        item = dict(txn)
        item["reviewTextVector"] = vector

        container.upsert_item(item)
        print(f"[{i}/{len(transactions)}] Upserted {txn['transactionId']} ({txn['productName']})")

    print("Done. All transactions embedded and stored in Cosmos DB.")


if __name__ == "__main__":
    main()
PYEOF
echo "load_and_embed.py written."

###############################################################################
# STEP 13 — Write the RAG query script (retrieval + generation)
###############################################################################
step "STEP 14: Writing query_rag.py"
cat > query_rag.py << 'PYEOF'
"""
A minimal end-to-end RAG query:
  1. Embed the user's question with the same embedding model/dimensions
     used to embed the data.
  2. Retrieve the most similar transactions from Cosmos DB using the
     VectorDistance system function (vector search / retrieval step).
  3. Feed the retrieved reviews to a chat model as grounding context and
     ask it to answer the question, citing transaction IDs (generation step).
"""
import os
import sys

from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential
from openai import AzureOpenAI

# .strip() guards against hidden \r/\n/space characters picked up from CLI
# output capture (see the comment in load_and_embed.py for why).
COSMOS_ENDPOINT = os.environ["COSMOS_ENDPOINT"].strip()
DATABASE_NAME = os.environ["COSMOS_DATABASE"].strip()
CONTAINER_NAME = os.environ["COSMOS_CONTAINER"].strip()

AOAI_ENDPOINT = os.environ["AOAI_ENDPOINT"].strip()
AOAI_KEY = os.environ["AOAI_KEY"].strip()
AOAI_EMBED_DEPLOYMENT = os.environ["AOAI_EMBED_DEPLOYMENT"].strip()
AOAI_CHAT_DEPLOYMENT = os.environ["AOAI_CHAT_DEPLOYMENT"].strip()
EMBED_DIMENSIONS = int(os.environ.get("EMBED_DIMENSIONS", "256"))
TOP_K = int(os.environ.get("TOP_K", "5"))


def embed_query(client, text):
    response = client.embeddings.create(input=text, model=AOAI_EMBED_DEPLOYMENT, dimensions=EMBED_DIMENSIONS)
    return response.data[0].embedding


def retrieve(container, query_vector, top_k):
    # TOP N must always be used with VectorDistance queries per Microsoft's
    # guidance, to keep RU cost and latency bounded.
    query = (
        f"SELECT TOP {top_k} c.transactionId, c.productName, c.category, "
        "c.reviewRating, c.reviewText, c.transactionDate, "
        "VectorDistance(c.reviewTextVector, @qv) AS SimilarityScore "
        "FROM c ORDER BY VectorDistance(c.reviewTextVector, @qv)"
    )
    params = [{"name": "@qv", "value": query_vector}]
    return list(container.query_items(query=query, parameters=params, enable_cross_partition_query=True))


def generate_answer(client, question, retrieved):
    context = "\n".join(
        f"- [{r['transactionId']}] {r['productName']} ({r['category']}), "
        f"rating {r['reviewRating']}/5: \"{r['reviewText']}\""
        for r in retrieved
    )
    system_prompt = (
        "You are a retail analytics assistant. Answer the question using ONLY "
        "the sales transaction context provided. Cite transaction IDs in your "
        "answer. If the context doesn't contain the answer, say so."
    )
    user_prompt = f"Context:\n{context}\n\nQuestion: {question}"

    # No explicit 'temperature' override here on purpose: some newer models
    # (e.g. the GPT-5 reasoning-family models like gpt-5-nano) only support
    # the default value and reject any override with a 400 error. Omitting
    # it keeps this script working across model families without branching.
    response = client.chat.completions.create(
        model=AOAI_CHAT_DEPLOYMENT,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
    )
    return response.choices[0].message.content


def main():
    question = " ".join(sys.argv[1:]) or "Which products had complaints about durability or battery life?"

    cosmos_client = CosmosClient(url=COSMOS_ENDPOINT, credential=DefaultAzureCredential())
    container = cosmos_client.get_database_client(DATABASE_NAME).get_container_client(CONTAINER_NAME)
    aoai_client = AzureOpenAI(azure_endpoint=AOAI_ENDPOINT, api_key=AOAI_KEY, api_version="2024-06-01")

    print(f"Question: {question}\n")

    query_vector = embed_query(aoai_client, question)
    retrieved = retrieve(container, query_vector, TOP_K)

    print(f"Retrieved {len(retrieved)} similar transactions:")
    for r in retrieved:
        print(f"  [{r['transactionId']}] score={r['SimilarityScore']:.4f} - {r['productName']}")
    print()

    answer = generate_answer(aoai_client, question, retrieved)
    print("Answer:\n" + answer)


if __name__ == "__main__":
    main()
PYEOF
echo "query_rag.py written."


###############################################################################
# STEP 14 — Save environment variables for webapp
###############################################################################

pwd

cat > ../webapp/.env << EOF
COSMOS_ENDPOINT="$COSMOS_ENDPOINT"
COSMOS_DATABASE="$COSMOS_DATABASE"
COSMOS_CONTAINER="$COSMOS_CONTAINER"
AOAI_ENDPOINT="$AOAI_ENDPOINT"
AOAI_KEY="$AOAI_KEY"
AOAI_EMBED_DEPLOYMENT="$EMBEDDING_DEPLOYMENT"
AOAI_CHAT_DEPLOYMENT="$CHAT_DEPLOYMENT"
EMBED_DIMENSIONS="$EMBEDDING_DIMENSIONS"
SALES_DATA_FILE="$SALES_DATA_FILE"
EOF


###############################################################################
# STEP 16 — export env vars and run the loader script to embed and load transactions into Cosmos DB
###############################################################################
step "STEP 16: Embedding and loading transactions into Cosmos DB"

export COSMOS_ENDPOINT COSMOS_DATABASE COSMOS_CONTAINER
export AOAI_ENDPOINT AOAI_KEY
export AOAI_EMBED_DEPLOYMENT="$EMBEDDING_DEPLOYMENT"
export AOAI_CHAT_DEPLOYMENT="$CHAT_DEPLOYMENT"
export EMBED_DIMENSIONS="$EMBEDDING_DIMENSIONS"
export SALES_DATA_FILE

# use below scripts only if above steps fail to run the loader
#sed -i 's/os.environ\["COSMOS_ENDPOINT"\]/os.environ["COSMOS_ENDPOINT"].strip()/' load_and_embed.py query_rag.py
#sed -i 's/os.environ\["AOAI_ENDPOINT"\]/os.environ["AOAI_ENDPOINT"].strip()/' load_and_embed.py query_rag.py
#sed -i 's/os.environ\["AOAI_KEY"\]/os.environ["AOAI_KEY"].strip()/' load_and_embed.py query_rag.py


step "STEP 15: Setting up Python virtual environment"
python3 -m venv "$VENV_DIR"
# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"
pip install --quiet --upgrade pip
pip install --quiet "azure-cosmos>=4.7.0" "azure-identity>=1.17.0" "openai>=1.40.0" "python-dotenv"
echo "Python environment ready."

#pip install azure-cosmos azure-identity openai python-dotenv

#az login --use-device-code



python3 load_and_embed.py

###############################################################################
# STEP 16 — Run sample RAG queries
###############################################################################
step "STEP 16: Running sample RAG queries"

python3 query_rag.py "Which customers complained about battery life or durability?"
echo
echo "----------------------------------------------------------------------"
echo
python3 query_rag.py "What do customers say about the backpack's waterproofing?"




###############################################################################
# TRY UI APP
###############################################################################
cd ../webapp
#source ../cosmos-rag-demo/.venv/bin/activate   # reuse your existing venv
pip install -r requirements.txt
python3 app.py



###############################################################################
# DONE
###############################################################################
step "All done"
cat << SUMMARY
Resource group:      $RESOURCE_GROUP
Cosmos DB account:    $COSMOS_ACCOUNT
  Database:           $COSMOS_DATABASE
  Container:          $COSMOS_CONTAINER (partition key: $PARTITION_KEY_PATH)
  Vector path:        /reviewTextVector ($EMBEDDING_DIMENSIONS dims, cosine, flat index)
Azure OpenAI account: $OPENAI_ACCOUNT
  Embedding deployment: $EMBEDDING_DEPLOYMENT
  Chat deployment:      $CHAT_DEPLOYMENT
Data file:            $SALES_DATA_FILE
Scripts:               $WORK_DIR/load_and_embed.py, $WORK_DIR/query_rag.py

Try more queries:
  cd "$WORK_DIR" && source .venv/bin/activate
  python3 query_rag.py "Any feedback about the coffee maker's display or buttons?"

To avoid ongoing charges, delete everything when you're done:
  az group delete --name "$RESOURCE_GROUP" --yes --no-wait
SUMMARY
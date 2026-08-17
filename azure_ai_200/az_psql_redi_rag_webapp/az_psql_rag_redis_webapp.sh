#!/usr/bin/env bash
# ============================================================================
# RAG DEMO: Azure Database for PostgreSQL Flexible Server (pgvector + azure_ai)
#           + Azure Managed Redis caching
#
# Aligned with Microsoft Learn docs (checked Aug 2026):
#   - Vector search / pgvector:  learn.microsoft.com/azure/postgresql/extensions/how-to-use-pgvector
#   - azure_ai extension:        learn.microsoft.com/azure/postgresql/azure-ai/generative-ai-azure-overview
#   - Embeddings via azure_ai:   learn.microsoft.com/azure/postgresql/flexible-server/generative-ai-azure-openai
#   - Sentiment via azure_ai:    learn.microsoft.com/azure/postgresql/azure-ai/generative-ai-azure-cognitive
#   - Azure Managed Redis CLI:   learn.microsoft.com/azure/redis/scripts/create-manage-cache
#
# This is a single, linear, beginner-friendly script. No functions, and the
# only conditional (if/else) is the one place it is genuinely needed: showing
# a Redis cache hit vs. a cache miss in Phase 2.
#
# PREREQUISITES on the machine that runs this script:
#   - Azure CLI (az), logged in with an active subscription
#   - psql client
#   - redis-cli (from the redis-tools / redis package)
#   - curl, openssl (standard on most Linux/macOS shells)
#   - Quota/access to create an Azure OpenAI resource and deployment in your
#     subscription (Azure OpenAI access is limited-access and may need to be
#     requested first: https://aka.ms/oai/access)
# ============================================================================

set -e   # stop the script immediately if any command fails

# ----------------------------------------------------------------------------
# STEP 0: Configuration variables (edit these, or leave the defaults)
# ----------------------------------------------------------------------------
RANDOM_SUFFIX=$(tr -dc 'a-z0-9' </dev/urandom | head -c 5)    # keeps globally-unique names unique

LOCATION="westus3"
RESOURCE_GROUP="psql-rag-demo-rg-$RANDOM_SUFFIX"

PG_SERVER_NAME="ragdemo-pg-$RANDOM_SUFFIX"          # must be globally unique, lowercase
PG_ADMIN_USER="ragadmin"
PG_ADMIN_PASSWORD=$(openssl rand -base64 16)        # random demo password
DB_NAME="rag_demo_db"

OPENAI_RESOURCE_NAME="ragdemo-openai-$RANDOM_SUFFIX"
OPENAI_EMBED_DEPLOYMENT="text-embedding-ada-002"
OPENAI_EMBED_MODEL="text-embedding-ada-002"
EMBED_DIM=1536                                       # ada-002 embedding size

LANGUAGE_RESOURCE_NAME="ragdemo-lang-$RANDOM_SUFFIX"

REDIS_NAME="ragdemo-redis-$RANDOM_SUFFIX"
REDIS_SKU="Balanced_B1"
REDIS_PORT=10000                                      # Azure Managed Redis always uses 10000
CACHE_TTL_SECONDS=3600

echo "== Config =="
echo "Resource group : $RESOURCE_GROUP"
echo "Postgres server: $PG_SERVER_NAME"
echo "Postgres admin password (SAVE THIS): $PG_ADMIN_PASSWORD"
echo "============="

# ----------------------------------------------------------------------------
# STEP 1: Login and detect the caller's public IP (used for the firewall rule)
# ----------------------------------------------------------------------------
az login

MY_IP=$(curl -s https://ifconfig.me)
echo "Detected client IP for firewall rule: $MY_IP"

# ----------------------------------------------------------------------------
# STEP 2: Create the resource group
# ----------------------------------------------------------------------------
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION"

# ----------------------------------------------------------------------------
# STEP 3: Create the Azure OpenAI resource + an embedding model deployment
#         (this is what the azure_ai extension will call from inside Postgres)
# ----------------------------------------------------------------------------
az cognitiveservices account create \
  --name "$OPENAI_RESOURCE_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --kind OpenAI \
  --sku S0 \
  --custom-domain "$OPENAI_RESOURCE_NAME"

az cognitiveservices account deployment create \
  --name "$OPENAI_RESOURCE_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --deployment-name "$OPENAI_EMBED_DEPLOYMENT" \
  --model-name "$OPENAI_EMBED_MODEL" \
  --model-version "2" \
  --model-format OpenAI \
  --sku-name "GlobalStandard" \
  --sku-capacity 1

OPENAI_ENDPOINT=$(az cognitiveservices account show \
  --name "$OPENAI_RESOURCE_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.endpoint" -o tsv)

OPENAI_KEY=$(az cognitiveservices account keys list \
  --name "$OPENAI_RESOURCE_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "key1" -o tsv)

echo "Azure OpenAI endpoint: $OPENAI_ENDPOINT"

# ----------------------------------------------------------------------------
# STEP 4: Create an Azure AI Language resource (used for sentiment analysis)
# ----------------------------------------------------------------------------
az cognitiveservices account create \
  --name "$LANGUAGE_RESOURCE_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --kind TextAnalytics \
  --sku S \
  --custom-domain "$LANGUAGE_RESOURCE_NAME"

LANGUAGE_ENDPOINT=$(az cognitiveservices account show \
  --name "$LANGUAGE_RESOURCE_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.endpoint" -o tsv)

LANGUAGE_KEY=$(az cognitiveservices account keys list \
  --name "$LANGUAGE_RESOURCE_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "key1" -o tsv)

echo "Azure AI Language endpoint: $LANGUAGE_ENDPOINT"

# ----------------------------------------------------------------------------
# STEP 5: Create the Azure Database for PostgreSQL Flexible Server
#         (Burstable B1ms is the cheapest SKU, fine for a demo)
# ----------------------------------------------------------------------------
az postgres flexible-server create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$PG_SERVER_NAME" \
  --location "$LOCATION" \
  --admin-user "$PG_ADMIN_USER" \
  --admin-password "$PG_ADMIN_PASSWORD" \
  --sku-name Standard_B1ms \
  --tier Burstable \
  --storage-size 32 \
  --version 18 \
  --public-access "$MY_IP" \
  --yes

PG_HOST="${PG_SERVER_NAME}.postgres.database.azure.com"
export PGPASSWORD="$PG_ADMIN_PASSWORD"

# ----------------------------------------------------------------------------
# STEP 6: Allowlist the "vector" and "azure_ai" extensions on the server
#         (the pgvector binary is literally named "vector", not "pgvector")
# ----------------------------------------------------------------------------
az postgres flexible-server parameter set \
  --resource-group "$RESOURCE_GROUP" \
  --server-name "$PG_SERVER_NAME" \
  --name azure.extensions \
  --value "vector,azure_ai"

# ----------------------------------------------------------------------------
# STEP 7: Create the demo database
# ----------------------------------------------------------------------------
sudo apt update
sudo apt install postgresql-client
sudo apt install postgresql-client-common


psql -h "$PG_HOST" -U "$PG_ADMIN_USER" -d postgres \
  -c "CREATE DATABASE $DB_NAME;"

# ----------------------------------------------------------------------------
# STEP 8: Generate sample data CSVs (no embeddings in these files)
# ----------------------------------------------------------------------------

# --- sales_transactions.csv : 5 products, 27 transactions ---
cat > sales_transactions.csv << 'EOF'
transaction_id,product_id,product_name,quantity,unit_price,transaction_date,customer_id
1,P1,Wireless Mouse,2,24.99,2026-01-05,C1001
2,P2,Mechanical Keyboard,1,89.99,2026-01-06,C1002
3,P3,USB-C Hub,3,39.99,2026-01-07,C1003
4,P4,HD Webcam,1,54.99,2026-01-08,C1004
5,P5,Laptop Stand,2,29.99,2026-01-09,C1005
6,P1,Wireless Mouse,1,24.99,2026-01-12,C1006
7,P2,Mechanical Keyboard,2,89.99,2026-01-13,C1007
8,P3,USB-C Hub,1,39.99,2026-01-14,C1008
9,P4,HD Webcam,2,54.99,2026-01-15,C1009
10,P5,Laptop Stand,1,29.99,2026-01-16,C1010
11,P1,Wireless Mouse,3,24.99,2026-01-20,C1001
12,P2,Mechanical Keyboard,1,89.99,2026-01-21,C1011
13,P3,USB-C Hub,2,39.99,2026-01-22,C1012
14,P4,HD Webcam,1,54.99,2026-01-23,C1013
15,P5,Laptop Stand,4,29.99,2026-01-24,C1014
16,P1,Wireless Mouse,1,24.99,2026-02-02,C1015
17,P2,Mechanical Keyboard,2,89.99,2026-02-03,C1002
18,P3,USB-C Hub,1,39.99,2026-02-04,C1003
19,P4,HD Webcam,3,54.99,2026-02-05,C1004
20,P5,Laptop Stand,1,29.99,2026-02-06,C1005
21,P1,Wireless Mouse,2,24.99,2026-02-10,C1006
22,P2,Mechanical Keyboard,1,89.99,2026-02-11,C1007
23,P3,USB-C Hub,3,39.99,2026-02-12,C1008
24,P4,HD Webcam,1,54.99,2026-02-13,C1009
25,P5,Laptop Stand,2,29.99,2026-02-14,C1010
26,P1,Wireless Mouse,1,24.99,2026-02-18,C1011
27,P2,Mechanical Keyboard,3,89.99,2026-02-19,C1012
EOF

# --- product_reviews.csv : 5 products, 15 short reviews for sentiment/RAG ---
cat > product_reviews.csv << 'EOF'
review_id,product_id,review_text,review_date
1,P1,"This wireless mouse is super comfortable and the battery lasts forever.",2026-01-10
2,P1,"Tracking is a bit jumpy on glass surfaces, not what I expected.",2026-01-18
3,P1,"Solid budget mouse, does exactly what it says.",2026-02-01
4,P2,"The mechanical keyboard feels amazing to type on, worth every penny.",2026-01-11
5,P2,"Way too loud for an open office, my coworkers complained.",2026-01-19
6,P2,"Great build quality but the software for remapping keys is clunky.",2026-02-02
7,P3,"This USB-C hub finally let me use two monitors without lag.",2026-01-12
8,P3,"One of the ports stopped working after two weeks of light use.",2026-01-20
9,P3,"Compact, cool to the touch, and transfers files quickly.",2026-02-03
10,P4,"Video quality on this webcam is crisp even in low light.",2026-01-13
11,P4,"Autofocus hunts constantly during video calls, pretty distracting.",2026-01-21
12,P4,"Good value webcam, easy plug and play setup on my laptop.",2026-02-04
13,P5,"This laptop stand fixed my neck pain from looking down all day.",2026-01-14
14,P5,"Wobbles a little at the max height setting, wish it were sturdier.",2026-01-22
15,P5,"Lightweight, folds flat for travel, exactly what I needed.",2026-02-05
EOF

echo "Generated sales_transactions.csv and product_reviews.csv"

# ----------------------------------------------------------------------------
# STEP 9: Create tables + enable extensions (simple SQL, no embeddings yet)
# ----------------------------------------------------------------------------
cat > create_tables.sql << 'EOF'
-- Enable the vector extension (pgvector); the binary/extension name is "vector"
CREATE EXTENSION IF NOT EXISTS vector;

-- Enable the azure_ai extension (in-database calls to Azure OpenAI + Language)
CREATE EXTENSION IF NOT EXISTS azure_ai;

-- Raw sales data, no vectors
CREATE TABLE sales_transactions (
    transaction_id    INT PRIMARY KEY,
    product_id        TEXT NOT NULL,
    product_name      TEXT NOT NULL,
    quantity          INT NOT NULL,
    unit_price        NUMERIC(10,2) NOT NULL,
    transaction_date  DATE NOT NULL,
    customer_id       TEXT NOT NULL
);

-- Raw review text + metadata, no vectors
CREATE TABLE product_reviews (
    review_id               INT PRIMARY KEY,
    product_id               TEXT NOT NULL,
    review_text               TEXT NOT NULL,
    review_date               DATE NOT NULL,
    sentiment_label            TEXT,
    sentiment_positive_score   DOUBLE PRECISION,
    sentiment_neutral_score    DOUBLE PRECISION,
    sentiment_negative_score   DOUBLE PRECISION
);

-- Separate embeddings table, referencing product_reviews (keeps vectors apart
-- from the raw text table, matching the Microsoft Learn pattern)
CREATE TABLE review_embeddings (
    review_id  INT PRIMARY KEY REFERENCES product_reviews(review_id),
    embedding  VECTOR(1536)
);
EOF

psql -h "$PG_HOST" -U "$PG_ADMIN_USER" -d "$DB_NAME" -f create_tables.sql

# ----------------------------------------------------------------------------
# STEP 10: Load the two CSVs into their tables with \copy
# ----------------------------------------------------------------------------
psql -h "$PG_HOST" -U "$PG_ADMIN_USER" -d "$DB_NAME" \
  -c "\copy sales_transactions FROM 'sales_transactions.csv' WITH (FORMAT csv, HEADER true)"

psql -h "$PG_HOST" -U "$PG_ADMIN_USER" -d "$DB_NAME" \
  -c "\copy product_reviews(review_id,product_id,review_text,review_date) FROM 'product_reviews.csv' WITH (FORMAT csv, HEADER true)"

# ----------------------------------------------------------------------------
# STEP 11: Configure the azure_ai extension with the OpenAI + Language
#          endpoints and keys created in STEP 3 / STEP 4
# ----------------------------------------------------------------------------
psql -h "$PG_HOST" -U "$PG_ADMIN_USER" -d "$DB_NAME" \
  -c "SELECT azure_ai.set_setting('azure_openai.endpoint', '$OPENAI_ENDPOINT');"

psql -h "$PG_HOST" -U "$PG_ADMIN_USER" -d "$DB_NAME" \
  -c "SELECT azure_ai.set_setting('azure_openai.subscription_key', '$OPENAI_KEY');"

psql -h "$PG_HOST" -U "$PG_ADMIN_USER" -d "$DB_NAME" \
  -c "SELECT azure_ai.set_setting('azure_cognitive.endpoint', '$LANGUAGE_ENDPOINT');"

psql -h "$PG_HOST" -U "$PG_ADMIN_USER" -d "$DB_NAME" \
  -c "SELECT azure_ai.set_setting('azure_cognitive.subscription_key', '$LANGUAGE_KEY');"

# ----------------------------------------------------------------------------
# STEP 12: Generate embeddings for every review and store them in
#          review_embeddings, using azure_openai.create_embeddings()
# ----------------------------------------------------------------------------
psql -h "$PG_HOST" -U "$PG_ADMIN_USER" -d "$DB_NAME" -c "
INSERT INTO review_embeddings (review_id, embedding)
SELECT review_id,
       (azure_openai.create_embeddings('$OPENAI_EMBED_DEPLOYMENT', review_text))::vector
FROM product_reviews
ON CONFLICT (review_id) DO NOTHING;
"

# ----------------------------------------------------------------------------
# STEP 13: Run sentiment analysis on every review and store the results,
#          using azure_cognitive.analyze_sentiment()
# ----------------------------------------------------------------------------
psql -h "$PG_HOST" -U "$PG_ADMIN_USER" -d "$DB_NAME" -c "
UPDATE product_reviews r
SET sentiment_label          = (sub.s).sentiment,
    sentiment_positive_score = (sub.s).positive_score,
    sentiment_neutral_score  = (sub.s).neutral_score,
    sentiment_negative_score = (sub.s).negative_score
FROM (
    SELECT review_id, azure_cognitive.analyze_sentiment(review_text, 'en') AS s
    FROM product_reviews
) sub
WHERE r.review_id = sub.review_id;
"

# ----------------------------------------------------------------------------
# STEP 14: Index the embeddings for fast approximate similarity search
# ----------------------------------------------------------------------------
psql -h "$PG_HOST" -U "$PG_ADMIN_USER" -d "$DB_NAME" \
  -c "CREATE INDEX ON review_embeddings USING hnsw (embedding vector_cosine_ops);"

# ----------------------------------------------------------------------------
# STEP 15: One manual test query a learner can run by hand (cosine distance,
#          the <=> operator) -- top 5 most similar reviews to a sample phrase
# ----------------------------------------------------------------------------
psql -h "$PG_HOST" -U "$PG_ADMIN_USER" -d "$DB_NAME" -c "
SELECT r.review_id, r.product_id, r.review_text, r.sentiment_label,
       e.embedding <=> (azure_openai.create_embeddings('$OPENAI_EMBED_DEPLOYMENT', 'great value for money'))::vector AS distance
FROM product_reviews r
JOIN review_embeddings e ON r.review_id = e.review_id
ORDER BY distance
LIMIT 5;
"

# PHASE 1 COMPLETE:
# ============================================================================
# PHASE 1 COMPLETE: vector similarity search + sentiment analysis are working
# in PostgreSQL only, no Redis involved yet.
# ============================================================================


# ----------------------------------------------------------------------------
# STEP 16: Interactive manual test -- prompt the learner for a query, embed
#          it, run the similarity search, print matches + sentiment
# ----------------------------------------------------------------------------
while true; do
  read -r -p "Enter a search query to test the RAG pipeline (or 'done' to stop): " USER_QUERY

  if [ "$USER_QUERY" = "done" ]; then
    echo "Exiting query loop."
    break
  fi

  psql -h "$PG_HOST" -U "$PG_ADMIN_USER" -d "$DB_NAME" -c "
  SELECT r.review_id, r.product_id, r.review_text, r.sentiment_label,
         e.embedding <=> (azure_openai.create_embeddings('$OPENAI_EMBED_DEPLOYMENT', '$USER_QUERY'))::vector AS distance
  FROM product_reviews r
  JOIN review_embeddings e ON r.review_id = e.review_id
  ORDER BY distance
  LIMIT 5;
  "
done

# PROMPT EXAMPLE
## Straightforward matches:
#### great value for money
#### comfortable to use for long periods
#### good for video calls

### Should surface negative/mixed reviews:
#### product stopped working after a short time
#### too noisy for an office
#### wobbly and not sturdy

### Feature-specific:
#### connecting multiple monitors
#### works well in low light
#### easy to pack and travel with

# PHASE 2:
# Managed Redis for caching
# ============================================================================
# PHASE 2: Add Azure Managed Redis for caching
# ============================================================================

# ----------------------------------------------------------------------------
# STEP 17: Create the Azure Managed Redis instance
#          (uses the az redisenterprise command group; the CLI extension
#          installs automatically the first time you run it)
# ----------------------------------------------------------------------------
sudo apt install redis-tools

az redisenterprise create \
  --name "$REDIS_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku "$REDIS_SKU" \
  --public-network-access Enabled \
  --access-keys-authentication Enabled  

REDIS_HOST=$(az redisenterprise show \
  --name "$REDIS_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "hostName" -o tsv)

REDIS_KEY=$(az redisenterprise database list-keys \
  --cluster-name "$REDIS_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "primaryKey" -o tsv)

echo "Azure Managed Redis host: $REDIS_HOST : $REDIS_PORT"

# ----------------------------------------------------------------------------
# STEP 18: Caching pattern -- check Redis first, fall back to Postgres.
#          The cache key is a hash of the raw query text; the cached value is
#          the fully formatted result, so a cache hit skips BOTH the
#          embedding call AND the vector search in Postgres.
# ----------------------------------------------------------------------------
# Turn the query text into a fixed-length Redis key (same query = same key = cache hit)
CACHE_KEY="ragcache:$(echo -n "$USER_QUERY" | md5sum | cut -d' ' -f1)"

echo "----- First run (expect a CACHE MISS) -----"

CACHED_RESULT=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" --tls -a "$REDIS_KEY" --no-auth-warning GET "$CACHE_KEY")

if [ -z "$CACHED_RESULT" ]; then
  echo "Cache miss: recomputing embedding + running vector search in PostgreSQL..."

  FRESH_RESULT=$(psql -h "$PG_HOST" -U "$PG_ADMIN_USER" -d "$DB_NAME" -t -A -c "
    SELECT r.review_id || ' | ' || r.product_id || ' | ' || r.review_text || ' | ' || r.sentiment_label
    FROM product_reviews r
    JOIN review_embeddings e ON r.review_id = e.review_id
    ORDER BY e.embedding <=> (azure_openai.create_embeddings('$OPENAI_EMBED_DEPLOYMENT', '$USER_QUERY'))::vector
    LIMIT 5;
  ")

  echo "$FRESH_RESULT"

  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" --tls -a "$REDIS_KEY" --no-auth-warning \
    SET "$CACHE_KEY" "$FRESH_RESULT" EX "$CACHE_TTL_SECONDS" > /dev/null

  echo "Result stored in Redis for $CACHE_TTL_SECONDS seconds."
else
  echo "Cache hit: returning cached result instantly, no PostgreSQL call made."
  echo "$CACHED_RESULT"
fi


echo "----- Second run of the SAME query (expect a CACHE HIT) -----"
CACHED_RESULT_2=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" --tls -a "$REDIS_KEY" --no-auth-warning GET "$CACHE_KEY")

if [ -z "$CACHED_RESULT_2" ]; then
  echo "Unexpected cache miss on the second run -- check the TTL and cache key."
else
  echo "Cache hit: returning cached result instantly, no embedding call and no"
  echo "PostgreSQL vector search were needed this time -- this is the latency"
  echo "and cost saving Redis provides for repeated RAG queries."
  echo "$CACHED_RESULT_2"
fi


# ChatBot Conversation

while true; do
  read -r -p "Enter a search query to test caching (or 'done' to stop): " USER_QUERY

  if [ "$(echo "$USER_QUERY" | tr '[:upper:]' '[:lower:]')" = "done" ]; then
    echo "Exiting caching demo loop."
    break
  fi

  # Turn the query text into a fixed-length Redis key (same query = same key = cache hit)
  CACHE_KEY="ragcache:$(echo -n "$USER_QUERY" | md5sum | cut -d' ' -f1)"

  # Rough token estimate (~1.3 tokens per word for English) -- NOT the real billed
  # count. The azure_ai extension's create_embeddings() only returns the vector,
  # not a usage object, so this is just for a sense of scale. See note below.
  WORD_COUNT=$(echo -n "$USER_QUERY" | wc -w)
  EST_TOKENS=$(( (WORD_COUNT * 13 + 9) / 10 ))

  START_MS=$(date +%s%3N)

  # Ask Redis if this query's result is already cached (empty result = cache miss)
  CACHED_RESULT=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" --tls -a "$REDIS_KEY" --no-auth-warning GET "$CACHE_KEY")

  if [ -z "$CACHED_RESULT" ]; then
    echo "Cache miss: recomputing embedding + running vector search in PostgreSQL..."
    FRESH_RESULT=$(psql -h "$PG_HOST" -U "$PG_ADMIN_USER" -d "$DB_NAME" -t -A -c "
    SELECT r.review_id || ' | ' || r.product_id || ' | ' || r.review_text || ' | ' || r.sentiment_label
    FROM product_reviews r
    JOIN review_embeddings e ON r.review_id = e.review_id
    ORDER BY e.embedding <=> (azure_openai.create_embeddings('$OPENAI_EMBED_DEPLOYMENT', '$USER_QUERY'))::vector
    LIMIT 5;
    ")
    END_MS=$(date +%s%3N)
    ELAPSED_MS=$((END_MS - START_MS))

    echo "$FRESH_RESULT"

    if [ -z "$FRESH_RESULT" ]; then
      echo "PostgreSQL returned no result, nothing was cached. Check the error above."
    else
      redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" --tls -a "$REDIS_KEY" --no-auth-warning \
        SET "$CACHE_KEY" "$FRESH_RESULT" EX "$CACHE_TTL_SECONDS" > /dev/null
      echo "Result stored in Redis for $CACHE_TTL_SECONDS seconds."
    fi

    echo "Response time : ${ELAPSED_MS} ms  (MISS -- embedding call + Postgres vector search)"
    echo "Query size    : $WORD_COUNT words (~$EST_TOKENS tokens est., embedding call was billed)"
  else
    END_MS=$(date +%s%3N)
    ELAPSED_MS=$((END_MS - START_MS))

    echo "Cache hit: returning cached result instantly, no PostgreSQL call made."
    echo "$CACHED_RESULT"
    echo "Response time : ${ELAPSED_MS} ms  (HIT -- served from Redis, 0 tokens used)"
  fi

  echo ""
done


# PROMPT EXAMPLE
## Straightforward matches:
#### great value for money
#### comfortable to use for long periods
#### good for video calls

### Should surface negative/mixed reviews:
#### product stopped working after a short time
#### too noisy for an office
#### wobbly and not sturdy

### Feature-specific:
#### connecting multiple monitors
#### works well in low light
#### easy to pack and travel with



# SEMANTIC CACHE

# good for video calls
# works really well for video calls

# issue with cost to cach each


echo "Demo complete."
echo "Resources created in resource group: $RESOURCE_GROUP"
echo "Remember to delete them when you are done: az group delete --resource-group $RESOURCE_GROUP --yes --no-wait"

###############################################################################
# STEP 19
# SEMANTIC CACHE LOOP
###############################################################################

SEMANTIC_THRESHOLD=0.95

echo ""
echo "==============================================================="
echo "SEMANTIC CACHE CONFIGURATION"
echo "==============================================================="

###############################################################################
# CACHE TABLE
###############################################################################

psql \
  -h "$PG_HOST" \
  -U "$PG_ADMIN_USER" \
  -d "$DB_NAME" <<EOF

CREATE TABLE IF NOT EXISTS semantic_cache
(
    cache_id BIGSERIAL PRIMARY KEY,

    query_text TEXT NOT NULL,

    response_text TEXT NOT NULL,

    query_embedding VECTOR($EMBED_DIM),

    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS semantic_cache_embedding_idx
ON semantic_cache
USING hnsw (query_embedding vector_cosine_ops);

EOF

echo "Semantic cache table ready."

###############################################################################
# CONVERSATION LOOP
###############################################################################

while true
do

    echo ""
    read -r -p "Ask a question (or 'done'): " USER_QUERY

    ###########################################################################
    # EXIT
    ###########################################################################

    if [ "$(echo "$USER_QUERY" | tr '[:upper:]' '[:lower:]')" = "done" ]
    then
        echo "Goodbye."
        break
    fi

    START_MS=$(date +%s%3N)

    ###########################################################################
    # PERFORMANCE METADATA
    ###########################################################################

    QUERY_WORDS=$(echo "$USER_QUERY" | wc -w | xargs)

    TOKEN_ESTIMATE=$(python3 <<EOF
words=int("$QUERY_WORDS")
print(max(1, round(words * 1.5)))
EOF
)

    ###########################################################################
    # NORMALIZE
    ###########################################################################

    NORMALIZED_QUERY=$(echo "$USER_QUERY" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[[:punct:]]//g' \
        | xargs)

    EXACT_CACHE_KEY="exactcache:$(echo -n "$NORMALIZED_QUERY" | md5sum | cut -d' ' -f1)"

    ###########################################################################
    # L1 EXACT REDIS CACHE
    ###########################################################################

    EXACT_RESULT=$(redis-cli \
        -h "$REDIS_HOST" \
        -p "$REDIS_PORT" \
        --tls \
        -a "$REDIS_KEY" \
        --no-auth-warning \
        GET "$EXACT_CACHE_KEY")

    if [ -n "$EXACT_RESULT" ]
    then

        END_MS=$(date +%s%3N)

        echo ""
        echo "================================================="
        echo "L1 EXACT CACHE HIT"
        echo "================================================="
        echo "$EXACT_RESULT"

        echo ""
        echo "-------------------------------------------------"
        echo "PERFORMANCE DETAILS"
        echo "-------------------------------------------------"
        echo "Cache path    : L1 Redis exact cache HIT"
        echo "Process       : Served directly from Redis"
        echo "Embedding     : Skipped"
        echo "Vector search : Skipped"
        echo "Tokens used   : 0"
        echo "Query size    : $QUERY_WORDS words (~$TOKEN_ESTIMATE tokens est., not billed)"
        echo "Response time : $((END_MS-START_MS)) ms"
        echo "-------------------------------------------------"

        continue

    fi

    ###########################################################################
    # CREATE EMBEDDING ONCE
    ###########################################################################

    echo ""
    echo "Generating embedding..."

    QUERY_VECTOR=$(psql \
        -h "$PG_HOST" \
        -U "$PG_ADMIN_USER" \
        -d "$DB_NAME" \
        -t -A \
        -v deployment="$OPENAI_EMBED_DEPLOYMENT" \
        -v user_query="$USER_QUERY" <<'SQL'
SELECT replace(
    replace(
        azure_openai.create_embeddings(
            :'deployment',
            :'user_query'
        )::text,
        '{',
        '['
    ),
    '}',
    ']'
);
SQL
)

    if [ -z "$QUERY_VECTOR" ]
    then
        echo ""
        echo "ERROR: Failed to generate embedding."
        echo ""
        continue
    fi

    ###########################################################################
    # L2 SEMANTIC CACHE LOOKUP
    ###########################################################################

    CACHE_LOOKUP=$(psql \
        -h "$PG_HOST" \
        -U "$PG_ADMIN_USER" \
        -d "$DB_NAME" \
        -t -A \
        -F '|' \
        -v query_vector="$QUERY_VECTOR" <<'SQL'
SELECT
    cache_id,
    1 - (
        query_embedding <=>
        :'query_vector'::vector
    ) AS similarity
FROM semantic_cache
ORDER BY
    query_embedding <=>
    :'query_vector'::vector
LIMIT 1;
SQL
)

    CACHE_ID=$(echo "$CACHE_LOOKUP" | awk -F'|' '{print $1}')
    CACHE_SIMILARITY=$(echo "$CACHE_LOOKUP" | awk -F'|' '{print $2}')

    if [ -z "$CACHE_SIMILARITY" ]
    then
        CACHE_SIMILARITY=0
    fi

    SEMANTIC_HIT=$(python3 <<EOF
s=float("$CACHE_SIMILARITY")
t=float("$SEMANTIC_THRESHOLD")
print("true" if s >= t else "false")
EOF
)

    ###########################################################################
    # L2 SEMANTIC CACHE HIT
    ###########################################################################

    if [ "$SEMANTIC_HIT" = "true" ]
    then

        RESPONSE_TEXT=$(psql \
            -h "$PG_HOST" \
            -U "$PG_ADMIN_USER" \
            -d "$DB_NAME" \
            -t -A \
            -v cache_id="$CACHE_ID" <<'SQL'
SELECT response_text
FROM semantic_cache
WHERE cache_id = :'cache_id';
SQL
)

        redis-cli \
            -h "$REDIS_HOST" \
            -p "$REDIS_PORT" \
            --tls \
            -a "$REDIS_KEY" \
            --no-auth-warning \
            SET "$EXACT_CACHE_KEY" "$RESPONSE_TEXT" EX "$CACHE_TTL_SECONDS" \
            > /dev/null

        END_MS=$(date +%s%3N)

        echo ""
        echo "================================================="
        echo "L2 SEMANTIC CACHE HIT"
        echo "================================================="
        echo "Similarity: $CACHE_SIMILARITY"
        echo ""
        echo "$RESPONSE_TEXT"

        echo ""
        echo "-------------------------------------------------"
        echo "PERFORMANCE DETAILS"
        echo "-------------------------------------------------"
        echo "Cache path    : L2 PostgreSQL semantic cache HIT"
        echo "Process       : Generated embedding, found similar cached query"
        echo "Embedding     : Executed"
        echo "Vector search : Skipped main product review vector search"
        echo "Redis update  : Promoted semantic result into Redis exact cache"
        echo "Tokens used   : ~$TOKEN_ESTIMATE tokens est. for embedding"
        echo "Query size    : $QUERY_WORDS words (~$TOKEN_ESTIMATE tokens est., embedding call was billed)"
        echo "Similarity    : $CACHE_SIMILARITY"
        echo "Response time : $((END_MS-START_MS)) ms"
        echo "-------------------------------------------------"

        continue

    fi

    ###########################################################################
    # CACHE MISS
    ###########################################################################

    echo ""
    echo "================================================="
    echo "CACHE MISS"
    echo "================================================="

    FRESH_RESULT=$(psql \
      -h "$PG_HOST" \
      -U "$PG_ADMIN_USER" \
      -d "$DB_NAME" \
      -t -A \
      -v query_vector="$QUERY_VECTOR" <<'SQL'
SELECT
    r.review_id || ' | ' ||
    r.product_id || ' | ' ||
    r.review_text || ' | ' ||
    r.sentiment_label
FROM product_reviews r
JOIN review_embeddings e
      ON r.review_id = e.review_id
ORDER BY
    e.embedding <=>
    :'query_vector'::vector
LIMIT 5;
SQL
)

    echo "$FRESH_RESULT"

    ###########################################################################
    # SAVE EXACT CACHE
    ###########################################################################

    redis-cli \
        -h "$REDIS_HOST" \
        -p "$REDIS_PORT" \
        --tls \
        -a "$REDIS_KEY" \
        --no-auth-warning \
        SET "$EXACT_CACHE_KEY" "$FRESH_RESULT" EX "$CACHE_TTL_SECONDS" \
        > /dev/null

    ###########################################################################
    # SAVE SEMANTIC CACHE
    ###########################################################################

    psql \
        -h "$PG_HOST" \
        -U "$PG_ADMIN_USER" \
        -d "$DB_NAME" \
        -v user_query="$USER_QUERY" \
        -v response_text="$FRESH_RESULT" \
        -v query_vector="$QUERY_VECTOR" <<'SQL' > /dev/null
INSERT INTO semantic_cache
(
    query_text,
    response_text,
    query_embedding
)
VALUES
(
    :'user_query',
    :'response_text',
    :'query_vector'::vector
);
SQL

    END_MS=$(date +%s%3N)

    echo ""
    echo "Stored in semantic cache."

    echo ""
    echo "-------------------------------------------------"
    echo "PERFORMANCE DETAILS"
    echo "-------------------------------------------------"
    echo "Cache path    : MISS"
    echo "Process       : Recomputed embedding and ran PostgreSQL vector search"
    echo "Embedding     : Executed"
    echo "Vector search : Executed against product review embeddings"
    echo "Redis update  : Saved result into Redis exact cache"
    echo "Semantic save : Saved query, response, and embedding into semantic_cache"
    echo "Tokens used   : ~$TOKEN_ESTIMATE tokens est. for embedding"
    echo "Query size    : $QUERY_WORDS words (~$TOKEN_ESTIMATE tokens est., embedding call was billed)"
    echo "Response time : $((END_MS-START_MS)) ms"
    echo "-------------------------------------------------"
    echo ""

done

###############################################################################
# EXAMPLES
###############################################################################
# good for video calls

# works really well for video calls

# webcam performs nicely in meetings

# excellent camera for teams meetings

# great webcam quality for zoom

# all should start converging toward a semantic cache hit

###############################################################################

from sentence_transformers import SentenceTransformer
import psycopg2

# =====================================================
# STEP 1 - LOAD LOCAL EMBEDDING MODEL
# =====================================================
model = SentenceTransformer(
    "BAAI/bge-small-en-v1.5"
)

# =====================================================
# STEP 2 - SEARCH TEXT
# =====================================================
search_text = "premium sound quality"

# =====================================================
# STEP 3 - GENERATE QUERY EMBEDDING
# =====================================================
query_embedding = model.encode(
    search_text,
    normalize_embeddings=True
)

query_vector = "[" + ",".join(
    map(str, query_embedding.tolist())
) + "]"

# =====================================================
# STEP 4 - CONNECT TO POSTGRESQL
# =====================================================
conn = psycopg2.connect(
    host="localhost",
    port="5432",
    database="demo_db",
    user="admin",
    password="AdminPass123!"
)

cursor = conn.cursor()

# =====================================================
# STEP 5 - SIMILARITY SEARCH
# =====================================================
cursor.execute(
    """
    SELECT
        p.name,
        p.category,
        p.description,
        1 - (
            pv.embedding <=> %s::vector
        ) AS similarity
    FROM products p
    INNER JOIN products_vector pv
        ON p.productid = pv.productid
    ORDER BY similarity DESC
    LIMIT 5
    """,
    (query_vector,)
)

# =====================================================
# STEP 6 - DISPLAY RESULTS
# =====================================================
results = cursor.fetchall()

print(
    f"\nTop Products For: '{search_text}'\n"
)

for name, category, description, similarity in results:

    print(f"Name: {name}")
    print(f"Category: {category}")
    print(f"Description: {description}")
    print(f"Similarity: {similarity:.4f}")
    print("-" * 60)

cursor.close()
conn.close()
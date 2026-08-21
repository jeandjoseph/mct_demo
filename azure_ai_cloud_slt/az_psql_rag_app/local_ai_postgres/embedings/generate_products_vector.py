from sentence_transformers import SentenceTransformer
import psycopg2

# =====================================================
# STEP 1 - LOAD EMBEDDING MODEL
# =====================================================
model = SentenceTransformer("BAAI/bge-small-en-v1.5")

# =====================================================
# STEP 2 - CONNECT TO POSTGRESQL
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
# STEP 3 - READ PRODUCTS
# =====================================================
cursor.execute(
    """
    SELECT productid, name
    FROM products
    """
)

products = cursor.fetchall()

print(f"Found {len(products)} products")

# =====================================================
# STEP 4 - GENERATE & STORE EMBEDDINGS
# =====================================================
for productid, name in products:

    embedding = model.encode(
        name,
        normalize_embeddings=True
    )

    vector = "[" + ",".join(
        map(str, embedding.tolist())
    ) + "]"

    cursor.execute(
        """
        INSERT INTO products_vector
        (
            productid,
            embedding
        )
        VALUES
        (
            %s,
            %s::vector
        )
        ON CONFLICT (productid)
        DO UPDATE SET
            embedding = EXCLUDED.embedding
        """,
        (productid, vector)
    )

conn.commit()

print("Embeddings generated and stored successfully.")

# =====================================================
# STEP 5 - CLEAN UP
# =====================================================
cursor.close()
conn.close()
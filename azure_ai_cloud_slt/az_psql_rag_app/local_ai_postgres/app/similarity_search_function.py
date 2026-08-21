from sentence_transformers import SentenceTransformer


MODEL_NAME = "BAAI/bge-small-en-v1.5"


def load_embedding_model():
    model = SentenceTransformer(MODEL_NAME)
    return model


def convert_embedding_to_pgvector(embedding):
    return "[" + ",".join(map(str, embedding.tolist())) + "]"


def find_similar_products(client, model, search_text: str, top_k: int = 5) -> dict:
    if not search_text or search_text.strip() == "":
        return {
            "columns": ["message"],
            "rows": [("Please enter a search phrase.",)]
        }

    query_embedding = model.encode(
        search_text,
        normalize_embeddings=True
    )

    query_vector = convert_embedding_to_pgvector(query_embedding)

    sql_query = """
        SELECT
            p.name AS product_name,
            p.category,
            p.description,
            ROUND(
                CAST(
                    1 - (pv.embedding <=> %s::vector)
                    AS NUMERIC
                ),
                4
            ) AS similarity
        FROM products p
        INNER JOIN products_vector pv
            ON p.productid = pv.productid
        ORDER BY pv.embedding <=> %s::vector
        LIMIT %s;
    """

    return client.run_query(
        sql_query,
        (
            query_vector,
            query_vector,
            top_k
        )
    )
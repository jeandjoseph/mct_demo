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

import psycopg2

from presidio_analyzer import AnalyzerEngine
from presidio_anonymizer import AnonymizerEngine


# =====================================================
# STEP 1 - CONNECT TO POSTGRESQL
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
# STEP 2 - LOAD PII ENGINES
# =====================================================
analyzer = AnalyzerEngine()

anonymizer = AnonymizerEngine()

# =====================================================
# STEP 3 - PRODUCT NAME
# =====================================================
product_name = "EchoBuds Pro"

# =====================================================
# STEP 4 - GET REVIEW SUMMARY
# =====================================================
cursor.execute(
    """
    SELECT
        p.name,
        r.abstractive_summary,
        r.sentiment_label,
        r.positive_score,
        r.neutral_score,
        r.negative_score
    FROM products p
    INNER JOIN product_review_summary r
        ON p.productid = r.productid
    WHERE p.name = %s
    """,
    (product_name,)
)

result = cursor.fetchone()

if result:

    (
        product_name,
        review_summary,
        sentiment_label,
        positive_score,
        neutral_score,
        negative_score
    ) = result

    # =================================================
    # STEP 5 - DETECT PII
    # =================================================
    analyzer_results = analyzer.analyze(
        text=review_summary,
        language="en"
    )

    # =================================================
    # STEP 6 - REDACT PII
    # =================================================
    redacted_summary = anonymizer.anonymize(
        text=review_summary,
        analyzer_results=analyzer_results
    ).text

    # =================================================
    # STEP 7 - DISPLAY RESULTS
    # =================================================
    print(f"\nProduct: {product_name}")

    print(
        f"\nSummary:\n{redacted_summary}"
    )

    print(
        f"\nSentiment: {sentiment_label}"
    )

    print(
        f"\nPositive Score: {positive_score}"
    )

    print(
        f"\nNeutral Score: {neutral_score}"
    )

    print(
        f"\nNegative Score: {negative_score}"
    )

else:
    print("Product not found.")

cursor.close()
conn.close()
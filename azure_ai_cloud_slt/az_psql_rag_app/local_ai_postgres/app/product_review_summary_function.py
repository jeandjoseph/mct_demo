# =====================================================
# FILE: product_review_summary_function.py
# PURPOSE:
#   Retrieve product review summary from PostgreSQL and
#   redact ALL PII locally before returning results.
# =====================================================

import re

# =====================================================
# LOAD PII ENGINES (Presidio if available, else None)
# =====================================================
def load_pii_engines():
    try:
        from presidio_analyzer import AnalyzerEngine
        from presidio_anonymizer import AnonymizerEngine
        from presidio_anonymizer.entities import OperatorConfig

        analyzer = AnalyzerEngine()
        anonymizer = AnonymizerEngine()

        return {
            "analyzer": analyzer,
            "anonymizer": anonymizer,
            "OperatorConfig": OperatorConfig,
            "available": True
        }
    except Exception:
        return {
            "analyzer": None,
            "anonymizer": None,
            "OperatorConfig": None,
            "available": False
        }


# =====================================================
# REGEX FALLBACK REDACTOR
# =====================================================
def redact_with_regex(text):
    if text is None:
        return ""

    text = str(text)

    patterns = [
        # Emails
        (r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", "[EMAIL]"),
        # URLs
        (r"\b(?:https?://|www\.)\S+\b", "[URL]"),
        # US SSN
        (r"\b\d{3}-\d{2}-\d{4}\b", "[SSN]"),
        # Credit cards (13 to 19 digits, with optional separators)
        (r"\b(?:\d[ -]*?){13,19}\b", "[CREDIT_CARD]"),
        # Phone numbers (US + international-ish)
        (r"\b(?:\+?\d{1,3}[\s.-]?)?(?:\(?\d{3}\)?[\s.-]?)\d{3}[\s.-]?\d{4}\b", "[PHONE]"),
        # IPv4
        (r"\b(?:\d{1,3}\.){3}\d{1,3}\b", "[IP]"),
        # Dates (MM/DD/YYYY, YYYY-MM-DD, Mon DD, YYYY)
        (r"\b\d{4}-\d{2}-\d{2}\b", "[DATE]"),
        (r"\b\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b", "[DATE]"),
        (r"\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+\d{1,2},?\s+\d{4}\b", "[DATE]"),
        # US ZIP codes
        (r"\b\d{5}(?:-\d{4})?\b", "[ZIP]"),
        # Street addresses (very rough)
        (r"\b\d{1,5}\s+[A-Z][A-Za-z0-9.\-\s]{2,}\s+(?:Street|St|Avenue|Ave|Road|Rd|Boulevard|Blvd|Lane|Ln|Drive|Dr|Court|Ct|Way|Terrace|Ter|Place|Pl)\b\.?",
         "[ADDRESS]"),
        # Person full names (Capitalized First + Last, rough heuristic)
        (r"\b(?:Mr\.|Mrs\.|Ms\.|Dr\.|Prof\.)?\s?[A-Z][a-z]+\s+[A-Z][a-z]+\b", "[PERSON]"),
    ]

    redacted = text
    for pattern, tag in patterns:
        redacted = re.sub(pattern, tag, redacted)

    return redacted


# =====================================================
# REDACT PII (Presidio first, regex fallback)
# =====================================================
def redact_pii(text, pii_engines):
    if text is None:
        return ""

    text = str(text)
    if text.strip() == "":
        return ""

    if not pii_engines or not pii_engines.get("available"):
        return redact_with_regex(text)

    try:
        analyzer = pii_engines["analyzer"]
        anonymizer = pii_engines["anonymizer"]
        OperatorConfig = pii_engines["OperatorConfig"]

        entities_to_detect = [
            "PERSON", "EMAIL_ADDRESS", "PHONE_NUMBER", "CREDIT_CARD",
            "US_SSN", "US_BANK_NUMBER", "US_DRIVER_LICENSE", "US_PASSPORT",
            "US_ITIN", "IP_ADDRESS", "IBAN_CODE", "LOCATION",
            "DATE_TIME", "URL", "NRP", "MEDICAL_LICENSE", "CRYPTO"
        ]

        analyzer_results = analyzer.analyze(
            text=text,
            entities=entities_to_detect,
            language="en"
        )

        operators = {
            "DEFAULT": OperatorConfig("replace", {"new_value": "[REDACTED]"}),
            "PERSON": OperatorConfig("replace", {"new_value": "[PERSON]"}),
            "EMAIL_ADDRESS": OperatorConfig("replace", {"new_value": "[EMAIL]"}),
            "PHONE_NUMBER": OperatorConfig("replace", {"new_value": "[PHONE]"}),
            "CREDIT_CARD": OperatorConfig("replace", {"new_value": "[CREDIT_CARD]"}),
            "US_SSN": OperatorConfig("replace", {"new_value": "[SSN]"}),
            "IP_ADDRESS": OperatorConfig("replace", {"new_value": "[IP]"}),
            "LOCATION": OperatorConfig("replace", {"new_value": "[LOCATION]"}),
            "DATE_TIME": OperatorConfig("replace", {"new_value": "[DATE]"}),
            "URL": OperatorConfig("replace", {"new_value": "[URL]"}),
        }

        anonymized = anonymizer.anonymize(
            text=text,
            analyzer_results=analyzer_results,
            operators=operators
        )

        # Extra safety net using regex on top of Presidio output
        return redact_with_regex(anonymized.text)

    except Exception:
        return redact_with_regex(text)


# =====================================================
# SIMPLE LOCAL SENTIMENT (no external API)
# =====================================================
def local_sentiment_scores(text):
    if not text:
        return 0.0, 1.0, 0.0, "neutral"

    text_lower = text.lower()

    positive_words = [
        "love", "great", "excellent", "amazing", "awesome", "fantastic",
        "good", "best", "perfect", "wonderful", "happy", "recommend",
        "satisfied", "impressive", "quality", "smooth", "fast", "reliable"
    ]
    negative_words = [
        "bad", "poor", "terrible", "awful", "worst", "hate",
        "disappointed", "broken", "defective", "slow", "issue", "problem",
        "return", "refund", "cheap", "flimsy", "waste", "annoying"
    ]

    pos_hits = sum(text_lower.count(w) for w in positive_words)
    neg_hits = sum(text_lower.count(w) for w in negative_words)
    total = pos_hits + neg_hits

    if total == 0:
        return 0.0, 1.0, 0.0, "neutral"

    positive_score = round(pos_hits / total, 2)
    negative_score = round(neg_hits / total, 2)
    neutral_score = round(max(0.0, 1.0 - (positive_score + negative_score)), 2)

    if positive_score > negative_score:
        label = "positive"
    elif negative_score > positive_score:
        label = "negative"
    else:
        label = "neutral"

    return positive_score, neutral_score, negative_score, label


# =====================================================
# GET PRODUCT REVIEW SUMMARY (WITH FULL PII REDACTION)
# =====================================================
def get_product_review_summary(client, product_name, pii_engines):
    if not product_name or product_name.strip() == "":
        return {
            "columns": ["message"],
            "rows": [("Please enter a product name.",)]
        }

    sql_query = """
        SELECT
            p.name        AS product_name,
            p.category    AS category,
            p.description AS description,
            STRING_AGG(pr.review_text, ' || ') AS review_details
        FROM products p
        LEFT JOIN product_reviews pr
            ON p.productid = pr.productid
        WHERE LOWER(p.name) = LOWER(%s)
        GROUP BY p.name, p.category, p.description;
    """

    result = client.run_query(sql_query, (product_name,))

    if not result or "rows" not in result or len(result["rows"]) == 0:
        return {
            "columns": ["message"],
            "rows": [(f"No product or reviews found for '{product_name}'.",)]
        }

    row = result["rows"][0]
    product_name_val = row[0]
    category_val = row[1]
    description_val = row[2]
    review_details_raw = row[3] if row[3] else ""

    # ===== REDACT ALL PII BEFORE ANYTHING ELSE =====
    review_details_redacted = redact_pii(review_details_raw, pii_engines)
    description_redacted = redact_pii(description_val, pii_engines)

    # ===== SENTIMENT ON REDACTED TEXT =====
    positive_score, neutral_score, negative_score, sentiment_label = (
        local_sentiment_scores(review_details_redacted)
    )

    # ===== AI STYLE SUMMARY (RULE BASED, PII SAFE) =====
    if sentiment_label == "positive":
        summary = (
            f"Customers generally have a positive impression of "
            f"{product_name_val}. Reviews highlight satisfaction with quality "
            f"and overall experience."
        )
    elif sentiment_label == "negative":
        summary = (
            f"Customers report notable concerns about {product_name_val}. "
            f"Feedback indicates dissatisfaction that may need product or "
            f"support improvements."
        )
    else:
        summary = (
            f"Customer feedback on {product_name_val} is mixed or neutral, "
            f"with no dominant sentiment across the reviews."
        )

    columns = [
        "product_name",
        "category",
        "description",
        "sentiment_label",
        "positive_score",
        "neutral_score",
        "negative_score",
        "product_summary_feedback",
        "review_details"
    ]

    rows = [(
        product_name_val,
        category_val,
        description_redacted,
        sentiment_label,
        positive_score,
        neutral_score,
        negative_score,
        summary,
        review_details_redacted
    )]

    return {"columns": columns, "rows": rows}
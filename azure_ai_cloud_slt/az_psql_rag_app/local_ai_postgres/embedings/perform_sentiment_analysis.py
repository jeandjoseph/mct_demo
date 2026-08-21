import psycopg2
import torch

from transformers import AutoTokenizer, AutoModelForSeq2SeqLM
from vaderSentiment.vaderSentiment import SentimentIntensityAnalyzer


# =====================================================
# STEP 1 - LOAD LOCAL SUMMARIZATION MODEL
# =====================================================
MODEL_NAME = "google/flan-t5-small"

tokenizer = AutoTokenizer.from_pretrained(MODEL_NAME)
model = AutoModelForSeq2SeqLM.from_pretrained(MODEL_NAME)

device = "cuda" if torch.cuda.is_available() else "cpu"
model = model.to(device)
model.eval()


# =====================================================
# STEP 2 - LOAD LOCAL SENTIMENT ANALYZER
# =====================================================
sentiment_analyzer = SentimentIntensityAnalyzer()


# =====================================================
# STEP 3 - CONNECT TO POSTGRESQL
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
# STEP 4 - GET PRODUCT REVIEWS
# =====================================================
cursor.execute(
    """
    SELECT
        p.productid,
        STRING_AGG(r.review_text, ' ') AS combined_reviews
    FROM products AS p
    INNER JOIN product_reviews AS r
        ON p.productid = r.productid
    GROUP BY p.productid
    ORDER BY p.productid
    """
)

review_rows = cursor.fetchall()

print(f"Found {len(review_rows)} products with reviews")


# =====================================================
# STEP 5 - HELPER FUNCTION: CHUNK LONG TEXT
# =====================================================
def chunk_text_by_tokens(text, max_tokens=450):
    token_ids = tokenizer.encode(
        text,
        truncation=False,
        add_special_tokens=False
    )

    chunks = []

    for i in range(0, len(token_ids), max_tokens):
        chunk_ids = token_ids[i:i + max_tokens]
        chunk_text = tokenizer.decode(
            chunk_ids,
            skip_special_tokens=True
        )
        chunks.append(chunk_text)

    return chunks


# =====================================================
# STEP 6 - HELPER FUNCTION: SUMMARIZE TEXT
# =====================================================
def summarize_text(text):
    if text is None or text.strip() == "":
        return "No reviews available."

    chunks = chunk_text_by_tokens(text, max_tokens=450)

    partial_summaries = []

    for chunk in chunks:
        prompt = (
            "Summarize the following product reviews in 2 concise sentences:\n\n"
            f"{chunk}"
        )

        inputs = tokenizer(
            prompt,
            return_tensors="pt",
            max_length=512,
            truncation=True
        ).to(device)

        with torch.no_grad():
            output_ids = model.generate(
                **inputs,
                max_new_tokens=80,
                num_beams=4,
                early_stopping=True,
                no_repeat_ngram_size=3
            )

        summary = tokenizer.decode(
            output_ids[0],
            skip_special_tokens=True
        )

        partial_summaries.append(summary)

    if len(partial_summaries) == 1:
        return partial_summaries[0]

    combined_partial_summary = " ".join(partial_summaries)

    final_prompt = (
        "Create one final 2 sentence summary from these product review summaries:\n\n"
        f"{combined_partial_summary}"
    )

    final_inputs = tokenizer(
        final_prompt,
        return_tensors="pt",
        max_length=512,
        truncation=True
    ).to(device)

    with torch.no_grad():
        final_output_ids = model.generate(
            **final_inputs,
            max_new_tokens=80,
            num_beams=4,
            early_stopping=True,
            no_repeat_ngram_size=3
        )

    final_summary = tokenizer.decode(
        final_output_ids[0],
        skip_special_tokens=True
    )

    return final_summary


# =====================================================
# STEP 7 - HELPER FUNCTION: ANALYZE SENTIMENT
# =====================================================
def analyze_sentiment(text):
    if text is None or text.strip() == "":
        return "neutral", 0.0, 1.0, 0.0

    scores = sentiment_analyzer.polarity_scores(text)

    positive_score = scores["pos"]
    neutral_score = scores["neu"]
    negative_score = scores["neg"]
    compound_score = scores["compound"]

    if compound_score >= 0.05:
        sentiment_label = "positive"
    elif compound_score <= -0.05:
        sentiment_label = "negative"
    else:
        sentiment_label = "neutral"

    return sentiment_label, positive_score, neutral_score, negative_score


# =====================================================
# STEP 8 - GENERATE SUMMARY AND SENTIMENT
# =====================================================
for productid, combined_reviews in review_rows:

    print(f"Processing productid: {productid}")

    abstractive_summary = summarize_text(combined_reviews)

    sentiment_label, positive_score, neutral_score, negative_score = analyze_sentiment(
        combined_reviews
    )

    cursor.execute(
        """
        INSERT INTO product_review_summary
        (
            productid,
            abstractive_summary,
            sentiment_label,
            positive_score,
            neutral_score,
            negative_score
        )
        VALUES
        (
            %s,
            %s,
            %s,
            %s,
            %s,
            %s
        )
        ON CONFLICT (productid)
        DO UPDATE SET
            abstractive_summary = EXCLUDED.abstractive_summary,
            sentiment_label = EXCLUDED.sentiment_label,
            positive_score = EXCLUDED.positive_score,
            neutral_score = EXCLUDED.neutral_score,
            negative_score = EXCLUDED.negative_score
        """,
        (
            productid,
            abstractive_summary,
            sentiment_label,
            positive_score,
            neutral_score,
            negative_score
        )
    )


# =====================================================
# STEP 9 - COMMIT CHANGES
# =====================================================
conn.commit()

print("Product review summaries and sentiment scores saved successfully.")


# =====================================================
# STEP 10 - CLEAN UP
# =====================================================
cursor.close()
conn.close()
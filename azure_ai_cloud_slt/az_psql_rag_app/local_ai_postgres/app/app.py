from datetime import datetime
from typing import Any, Dict, List, Optional

import pandas as pd
import streamlit as st

from azPostgresqlConnection import PostgresClient
from similarity_search_function import load_embedding_model, find_similar_products
from product_review_summary_function import load_pii_engines, get_product_review_summary


# =====================================================
# PAGE CONFIG
# =====================================================
st.set_page_config(
    page_title="Local AI Product Intelligence",
    page_icon="🧠",
    layout="wide"
)


# =====================================================
# CUSTOM CSS
# =====================================================
st.markdown(
    """
    <style>
        .main-title {
            font-size: 2.4rem;
            font-weight: 800;
            color: #1f4e79;
            margin-bottom: 0.2rem;
        }

        .sub-title {
            font-size: 1.05rem;
            color: #555;
            margin-bottom: 1.5rem;
        }

        .metric-card {
            padding: 1rem;
            border-radius: 14px;
            background: linear-gradient(135deg, #f8fbff, #eef5ff);
            border: 1px solid #dce9f9;
            margin-bottom: 1rem;
        }

        .section-card {
            padding: 1.2rem;
            border-radius: 16px;
            background-color: #ffffff;
            border: 1px solid #e5e7eb;
            box-shadow: 0 2px 8px rgba(0,0,0,0.03);
        }

        .small-muted {
            color: #666;
            font-size: 0.9rem;
        }
    </style>
    """,
    unsafe_allow_html=True
)


# =====================================================
# HEADER
# =====================================================
st.markdown(
    "<div class='main-title'>🧠 Local AI Product Intelligence</div>",
    unsafe_allow_html=True
)

st.markdown(
    """
    <div class='sub-title'>
        Search similar products, review product feedback, inspect sentiment, and protect privacy using local Python AI workflows with PostgreSQL and pgvector.
    </div>
    """,
    unsafe_allow_html=True
)


# =====================================================
# SESSION STATE
# =====================================================
if "history" not in st.session_state:
    st.session_state.history: List[Dict[str, Any]] = []

if "last_results" not in st.session_state:
    st.session_state.last_results: Optional[Any] = None

if "last_action" not in st.session_state:
    st.session_state.last_action = None

if "last_query" not in st.session_state:
    st.session_state.last_query = ""


# =====================================================
# CACHE RESOURCES
# =====================================================
@st.cache_resource(show_spinner=False)
def get_client():
    return PostgresClient()


@st.cache_resource(show_spinner=True)
def get_embedding_model():
    return load_embedding_model()


@st.cache_resource(show_spinner=False)
def get_pii_engines():
    return load_pii_engines()


# =====================================================
# PRESETS
# =====================================================
FUNCTION_PRESETS = [
    {
        "label": "Find Similar Products",
        "description": "Uses local BGE embeddings and pgvector similarity search.",
        "placeholder": "e.g., premium sound quality",
        "default_query": "premium sound quality",
        "mode": "similarity"
    },
    {
        "label": "Get Product Review Summary",
        "description": "Retrieves product summary, sentiment, and locally redacts PII.",
        "placeholder": "e.g., EchoBuds Pro",
        "default_query": "EchoBuds Pro",
        "mode": "review_summary"
    },
    {
        "label": "Find Accessories by Device",
        "description": "Uses semantic search to discover related accessories.",
        "placeholder": "e.g., iPhone 15 Pro Max cases",
        "default_query": "iPhone 15 Pro Max cases",
        "mode": "similarity"
    },
    {
        "label": "Query by SKU or ID",
        "description": "Uses semantic search when SKU or product details are embedded.",
        "placeholder": "e.g., SKU-ABC-12345",
        "default_query": "",
        "mode": "similarity"
    }
]

PRESETS_BY_LABEL = {
    preset["label"]: preset
    for preset in FUNCTION_PRESETS
}


# =====================================================
# HELPERS
# =====================================================
def to_dataframe(results):
    if not results:
        return pd.DataFrame()

    if "rows" not in results or "columns" not in results:
        return pd.DataFrame()

    return pd.DataFrame(
        results["rows"],
        columns=results["columns"]
    )


def append_history(action_label: str, query_text: str, results: Any):
    df = to_dataframe(results)

    record = {
        "ts": datetime.now().isoformat(timespec="seconds"),
        "action": action_label,
        "query": query_text,
        "row_count": int(len(df)),
        "results": results
    }

    st.session_state.history.append(record)


def run_selected_action(selected_preset: dict, query_text: str, top_k: int):
    client = get_client()

    if selected_preset["mode"] == "similarity":
        model = get_embedding_model()

        return find_similar_products(
            client=client,
            model=model,
            search_text=query_text,
            top_k=top_k
        )

    if selected_preset["mode"] == "review_summary":
        pii_engines = get_pii_engines()

        return get_product_review_summary(
            client=client,
            product_name=query_text,
            pii_engines=pii_engines
        )

    return {
        "columns": ["error"],
        "rows": [("Unsupported action.",)]
    }


# =====================================================
# SIDEBAR
# =====================================================
with st.sidebar:
    st.markdown("## ⚙️ App Settings")

    top_k = st.slider(
        "Number of similar products",
        min_value=3,
        max_value=20,
        value=5,
        step=1
    )

    st.markdown("---")

    st.markdown("## 💡 Tips")
    st.write(
        "- Use **Find Similar Products** for semantic product discovery.\n"
        "- Use **Get Product Review Summary** for exact product review feedback.\n"
        "- Embeddings run locally with **BAAI/bge-small-en-v1.5**.\n"
        "- PII redaction runs locally using Presidio when available, otherwise regex fallback.\n"
        "- PostgreSQL functions are no longer required."
    )

    st.markdown("---")

    if st.button("🧹 Clear History", use_container_width=True):
        st.session_state.history.clear()
        st.session_state.last_results = None
        st.session_state.last_action = None
        st.session_state.last_query = ""
        st.success("History cleared.")
        st.rerun()


# =====================================================
# TOP METRICS
# =====================================================
m1, m2, m3 = st.columns(3)

with m1:
    st.markdown(
        """
        <div class='metric-card'>
            <b>Embedding Model</b><br>
            <span class='small-muted'>BAAI/bge-small-en-v1.5</span>
        </div>
        """,
        unsafe_allow_html=True
    )

with m2:
    st.markdown(
        """
        <div class='metric-card'>
            <b>Search Engine</b><br>
            <span class='small-muted'>PostgreSQL + pgvector</span>
        </div>
        """,
        unsafe_allow_html=True
    )

with m3:
    st.markdown(
        """
        <div class='metric-card'>
            <b>Execution Mode</b><br>
            <span class='small-muted'>Local Python functions</span>
        </div>
        """,
        unsafe_allow_html=True
    )


# =====================================================
# MAIN INPUT PANEL
# =====================================================
st.markdown("## 🔎 What would you like to do?")

input_col1, input_col2, input_col3 = st.columns([1.5, 2.5, 0.8])

with input_col1:
    selected_label = st.selectbox(
        "Choose an Action",
        options=[preset["label"] for preset in FUNCTION_PRESETS],
        index=0
    )

selected_preset = PRESETS_BY_LABEL[selected_label]

with input_col2:
    query_text = st.text_input(
        "Enter your search or product name",
        value=selected_preset["default_query"],
        placeholder=selected_preset["placeholder"],
        help=selected_preset["description"]
    )

with input_col3:
    st.write("")
    st.write("")
    run_button = st.button(
        "Run",
        type="primary",
        use_container_width=True
    )


# =====================================================
# RUN HANDLER
# =====================================================
if run_button:
    if not query_text or query_text.strip() == "":
        st.warning("Please enter a query or product name.")
        st.stop()

    with st.spinner("Running local AI workflow..."):
        results = run_selected_action(
            selected_preset=selected_preset,
            query_text=query_text,
            top_k=top_k
        )

    st.session_state.last_results = results
    st.session_state.last_action = selected_label
    st.session_state.last_query = query_text

    append_history(
        action_label=selected_label,
        query_text=query_text,
        results=results
    )

    st.success("Done.")
    st.rerun()


# =====================================================
# LATEST RESULTS
# =====================================================
if st.session_state.last_results is not None:

    st.markdown("## ✅ Latest Results")

    st.caption(
        f"Action: {st.session_state.last_action} | "
        f"Query: {st.session_state.last_query}"
    )

    latest_df = to_dataframe(
        st.session_state.last_results
    )

    if latest_df.empty:

        st.warning(
            "No results found."
        )

    else:

        # =================================================
        # PRODUCT REVIEW SUMMARY VIEW
        # =================================================
        if (
            st.session_state.last_action
            == "Get Product Review Summary"
        ):

            row = latest_df.iloc[0]

            st.subheader(
                row["product_name"]
            )

            c1, c2, c3, c4 = st.columns(4)

            with c1:

                sentiment = str(
                    row["sentiment_label"]
                ).lower()

                if sentiment == "positive":

                    st.success(
                        f"😊 {row['sentiment_label']}"
                    )

                elif sentiment == "negative":

                    st.error(
                        f"😞 {row['sentiment_label']}"
                    )

                else:

                    st.warning(
                        f"😐 {row['sentiment_label']}"
                    )

            with c2:

                st.metric(
                    "Positive",
                    f"{float(row['positive_score']):.2f}"
                )

            with c3:

                st.metric(
                    "Neutral",
                    f"{float(row['neutral_score']):.2f}"
                )

            with c4:

                st.metric(
                    "Negative",
                    f"{float(row['negative_score']):.2f}"
                )

            st.markdown("---")

            st.markdown(
                "### 📝 AI Generated Summary"
            )

            st.info(
                row[
                    "product_summary_feedback"
                ]
            )

            st.markdown("---")

            st.markdown(
                "### 🔒 Redacted Customer Reviews"
            )

            with st.expander(
                "View Redacted Customer Reviews",
                expanded=True
            ):

                st.text_area(
                    label="",
                    value=row["review_details"],
                    height=350,
                    disabled=True
                )

        # =================================================
        # SIMILARITY SEARCH VIEW
        # =================================================
        else:

            st.dataframe(
                latest_df,
                use_container_width=True,
                hide_index=True
            )

        # =================================================
        # DOWNLOAD RESULTS
        # =================================================
        csv_data = latest_df.to_csv(
            index=False
        ).encode("utf-8")

        st.download_button(
            label="📥 Download Results as CSV",
            data=csv_data,
            file_name="local_ai_product_results.csv",
            mime="text/csv"
        )

    # =====================================================
    # RAW OUTPUT
    # =====================================================
    with st.expander(
        "View Raw Output"
    ):
        st.write(
            st.session_state.last_results
        )


# =====================================================
# HISTORY PANEL
# =====================================================
st.markdown("---")
st.markdown("## 📜 Transaction History")

if len(st.session_state.history) == 0:
    st.info("No history yet. Run a query to populate this panel.")
else:
    for index, record in enumerate(
        reversed(st.session_state.history),
        start=1
    ):
        header = (
            f"{record['ts']} | {record['action']} | "
            f"{record['query']} | rows: {record['row_count']}"
        )

        with st.expander(header, expanded=False):
            hist_df = to_dataframe(record["results"])

            if hist_df.empty:
                st.write("No rows returned.")
            else:
                st.dataframe(
                    hist_df,
                    use_container_width=True,
                    hide_index=True
                )
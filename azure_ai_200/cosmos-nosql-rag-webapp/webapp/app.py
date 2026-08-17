"""
Cosmos RAG Explorer -- a small Flask front end for the same retrieval +
generation pipeline as query_rag.py in the CLI demo, with a live, step-by-step
visualization and per-stage timing.

It reuses the exact same environment variables as load_and_embed.py and
query_rag.py -- if those already work in your shell, this will too.

Run with:
    python3 app.py
Then open http://127.0.0.1:5000
"""
import json
import os
import time

from dotenv import load_dotenv

from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential
from flask import Flask, Response, render_template, request
from openai import AzureOpenAI

# ---------------------------------------------------------------------------
# Configuration -- read once at startup. .strip() guards against hidden
# whitespace/CRLF characters some shells/CLIs can leave in captured values.
# ---------------------------------------------------------------------------
loaded = load_dotenv()

print(f"Loaded: {loaded}")

COSMOS_ENDPOINT = os.environ["COSMOS_ENDPOINT"].strip()
COSMOS_DATABASE = os.environ["COSMOS_DATABASE"].strip()
COSMOS_CONTAINER = os.environ["COSMOS_CONTAINER"].strip()

AOAI_ENDPOINT = os.environ["AOAI_ENDPOINT"].strip()
AOAI_KEY = os.environ["AOAI_KEY"].strip()
AOAI_EMBED_DEPLOYMENT = os.environ["AOAI_EMBED_DEPLOYMENT"].strip()
AOAI_CHAT_DEPLOYMENT = os.environ["AOAI_CHAT_DEPLOYMENT"].strip()
EMBED_DIMENSIONS = int(os.environ.get("EMBED_DIMENSIONS", "256"))

app = Flask(__name__)

# Clients are created once at startup and reused across requests -- creating
# a new client per request would work too, but is slower and unnecessary.
_cosmos_client = CosmosClient(url=COSMOS_ENDPOINT, credential=DefaultAzureCredential())
_container = (
    _cosmos_client.get_database_client(COSMOS_DATABASE).get_container_client(COSMOS_CONTAINER)
)
_aoai_client = AzureOpenAI(azure_endpoint=AOAI_ENDPOINT, api_key=AOAI_KEY, api_version="2024-06-01")


def sse(payload: dict) -> str:
    """Format a dict as one Server-Sent Events message."""
    return f"data: {json.dumps(payload)}\n\n"


def embed_text(text: str):
    response = _aoai_client.embeddings.create(
        input=text, model=AOAI_EMBED_DEPLOYMENT, dimensions=EMBED_DIMENSIONS
    )
    return response.data[0].embedding


def vector_search(query_vector, top_k: int):
    # TOP N is required alongside VectorDistance to keep RU cost and latency
    # bounded -- see the CLI demo's query_rag.py for the same pattern.
    query = (
        f"SELECT TOP {top_k} c.transactionId, c.productName, c.category, "
        "c.reviewRating, c.reviewText, c.transactionDate, "
        "VectorDistance(c.reviewTextVector, @qv) AS SimilarityScore "
        "FROM c ORDER BY VectorDistance(c.reviewTextVector, @qv)"
    )
    params = [{"name": "@qv", "value": query_vector}]
    return list(
        _container.query_items(query=query, parameters=params, enable_cross_partition_query=True)
    )


def build_answer(question: str, retrieved: list):
    context = "\n".join(
        f"- [{r['transactionId']}] {r['productName']} ({r['category']}), "
        f"rating {r['reviewRating']}/5: \"{r['reviewText']}\""
        for r in retrieved
    )
    system_prompt = (
        "You are a retail analytics assistant. Answer the question using ONLY "
        "the sales transaction context provided. Cite transaction IDs in your "
        "answer. If the context doesn't contain the answer, say so."
    )
    user_prompt = f"Context:\n{context}\n\nQuestion: {question}"

    # No explicit 'temperature' override on purpose: some newer models (e.g.
    # gpt-5-nano) only support the default and reject overrides outright.
    response = _aoai_client.chat.completions.create(
        model=AOAI_CHAT_DEPLOYMENT,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
    )
    return response.choices[0].message.content


@app.route("/")
def index():
    return render_template(
        "index.html",
        embed_deployment=AOAI_EMBED_DEPLOYMENT,
        chat_deployment=AOAI_CHAT_DEPLOYMENT,
        dimensions=EMBED_DIMENSIONS,
        database=COSMOS_DATABASE,
        container=COSMOS_CONTAINER,
    )


@app.route("/api/query")
def api_query():
    """
    Streams the pipeline as Server-Sent Events so the browser can render each
    stage live. Uses GET + query params (rather than POST) specifically so
    the browser's built-in EventSource can consume it without extra JS.
    """
    question = (request.args.get("question") or "").strip()
    try:
        top_k = int(request.args.get("top_k", 5))
    except ValueError:
        top_k = 5
    top_k = max(1, min(top_k, 10))

    if not question:
        def empty_stream():
            yield sse({"step": "error", "stage": "input", "message": "Type a question first."})

        return Response(empty_stream(), mimetype="text/event-stream")

    def generate():
        pipeline_start = time.perf_counter()
        yield sse({"step": "start", "question": question, "top_k": top_k})

        # 1. Embed the question
        yield sse({"step": "embedding_start"})
        t0 = time.perf_counter()
        try:
            query_vector = embed_text(question)
        except Exception as exc:  # noqa: BLE001 -- surface any failure to the UI
            yield sse({"step": "error", "stage": "embedding", "message": str(exc)})
            return
        embedding_ms = round((time.perf_counter() - t0) * 1000)
        yield sse(
            {
                "step": "embedding_done",
                "duration_ms": embedding_ms,
                "dimensions": len(query_vector),
                "vector_preview": [round(v, 4) for v in query_vector[:8]],
            }
        )

        # 2. Vector similarity search in Cosmos DB
        yield sse({"step": "retrieval_start"})
        t0 = time.perf_counter()
        try:
            retrieved = vector_search(query_vector, top_k)
        except Exception as exc:  # noqa: BLE001
            yield sse({"step": "error", "stage": "retrieval", "message": str(exc)})
            return
        retrieval_ms = round((time.perf_counter() - t0) * 1000)
        yield sse({"step": "retrieval_done", "duration_ms": retrieval_ms, "results": retrieved})

        # 3. Generate a grounded answer from the retrieved reviews
        yield sse({"step": "generation_start"})
        t0 = time.perf_counter()
        try:
            answer = build_answer(question, retrieved)
        except Exception as exc:  # noqa: BLE001
            yield sse({"step": "error", "stage": "generation", "message": str(exc)})
            return
        generation_ms = round((time.perf_counter() - t0) * 1000)
        yield sse({"step": "generation_done", "duration_ms": generation_ms, "answer": answer})

        total_ms = round((time.perf_counter() - pipeline_start) * 1000)
        yield sse(
            {
                "step": "complete",
                "total_ms": total_ms,
                "embedding_ms": embedding_ms,
                "retrieval_ms": retrieval_ms,
                "generation_ms": generation_ms,
            }
        )

    return Response(generate(), mimetype="text/event-stream")


if __name__ == "__main__":
    app.run(debug=True, port=5000)

# Cosmos RAG Explorer

A small Flask front end for the same retrieval-augmented pipeline as
`query_rag.py` in the CLI demo — type a question, and watch it get embedded,
matched against Cosmos DB with vector search, and answered, with a live
step-by-step view and per-stage timing.

It reuses the **same environment variables and virtual environment** as the
`cosmos-rag-demo/` CLI scripts. If `load_and_embed.py` and `query_rag.py`
already work for you, this will too — no new Azure resources needed.

## How it works

- `app.py` runs the exact same three steps as `query_rag.py` (embed →
  Cosmos DB vector search → chat completion), but streams each stage to the
  browser as it happens using **Server-Sent Events**, with `time.perf_counter()`
  timing around each stage.
- The browser renders three things live as the stream arrives:
  1. A 3-step pipeline tracker (vectorize → search → answer) with per-step
     timing badges.
  2. A **vector-space plot** — your question as a center point, the
     retrieved reviews arranged around it, closer = more similar. This is a
     literal picture of what "vector similarity search" is doing.
  3. A receipt-style evidence list of the matched transactions, and the
     final grounded answer with `[TXN-####]` citations highlighted.

## Setup

1. Put this folder next to (or inside) your existing `cosmos-rag-demo/`
   folder, and reuse the same virtual environment:

   ```bash
   source ../cosmos-rag-demo/.venv/bin/activate   # adjust path as needed
   pip install -r requirements.txt
   ```

2. Make sure these are exported in the same shell (same ones `query_rag.py`
   needs):

   ```
   COSMOS_ENDPOINT
   COSMOS_DATABASE
   COSMOS_CONTAINER
   AOAI_ENDPOINT
   AOAI_KEY
   AOAI_EMBED_DEPLOYMENT
   AOAI_CHAT_DEPLOYMENT
   EMBED_DIMENSIONS   (optional, defaults to 256)
   ```

3. Run it:

   ```bash
   python3 app.py
   ```

4. Open **http://127.0.0.1:5000** in your browser.

## Notes

- The `/api/query` endpoint uses `GET` (not `POST`) specifically so the
  browser's built-in `EventSource` can consume the stream without any extra
  JS libraries — a deliberate simplification for a teaching demo.
- Recent questions are remembered per-browser via `localStorage` — nothing
  is stored server-side beyond what already lives in Cosmos DB.
- Errors from any stage (bad credentials, expired token, deployment not
  found, etc.) are caught and shown inline in the pipeline UI rather than
  crashing the page — check the Flask terminal output for the full
  traceback if you need more detail than the on-page message.

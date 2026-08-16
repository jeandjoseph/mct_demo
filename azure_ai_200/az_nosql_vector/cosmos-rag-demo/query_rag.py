"""
A minimal end-to-end RAG query:
  1. Embed the user's question with the same embedding model/dimensions
     used to embed the data.
  2. Retrieve the most similar transactions from Cosmos DB using the
     VectorDistance system function (vector search / retrieval step).
  3. Feed the retrieved reviews to a chat model as grounding context and
     ask it to answer the question, citing transaction IDs (generation step).
"""
import os
import sys
 
from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential
from openai import AzureOpenAI
 
# .strip() guards against hidden \r/\n/space characters picked up from CLI
# output capture (see the comment in load_and_embed.py for why).
COSMOS_ENDPOINT = os.environ["COSMOS_ENDPOINT"].strip()
DATABASE_NAME = os.environ["COSMOS_DATABASE"].strip()
CONTAINER_NAME = os.environ["COSMOS_CONTAINER"].strip()
 
AOAI_ENDPOINT = os.environ["AOAI_ENDPOINT"].strip()
AOAI_KEY = os.environ["AOAI_KEY"].strip()
AOAI_EMBED_DEPLOYMENT = os.environ["AOAI_EMBED_DEPLOYMENT"].strip()
AOAI_CHAT_DEPLOYMENT = os.environ["AOAI_CHAT_DEPLOYMENT"].strip()
EMBED_DIMENSIONS = int(os.environ.get("EMBED_DIMENSIONS", "256"))
TOP_K = int(os.environ.get("TOP_K", "5"))
 
 
def embed_query(client, text):
    response = client.embeddings.create(input=text, model=AOAI_EMBED_DEPLOYMENT, dimensions=EMBED_DIMENSIONS)
    return response.data[0].embedding
 
 
def retrieve(container, query_vector, top_k):
    # TOP N must always be used with VectorDistance queries per Microsoft's
    # guidance, to keep RU cost and latency bounded.
    query = (
        f"SELECT TOP {top_k} c.transactionId, c.productName, c.category, "
        "c.reviewRating, c.reviewText, c.transactionDate, "
        "VectorDistance(c.reviewTextVector, @qv) AS SimilarityScore "
        "FROM c ORDER BY VectorDistance(c.reviewTextVector, @qv)"
    )
    params = [{"name": "@qv", "value": query_vector}]
    return list(container.query_items(query=query, parameters=params, enable_cross_partition_query=True))
 
 
def generate_answer(client, question, retrieved):
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
 
    # No explicit 'temperature' override here on purpose: some newer models
    # (e.g. the GPT-5 reasoning-family models like gpt-5-nano) only support
    # the default value and reject any override with a 400 error. Omitting
    # it keeps this script working across model families without branching.
    response = client.chat.completions.create(
        model=AOAI_CHAT_DEPLOYMENT,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
    )
    return response.choices[0].message.content
 
 
def main():
    question = " ".join(sys.argv[1:]) or "Which products had complaints about durability or battery life?"
 
    cosmos_client = CosmosClient(url=COSMOS_ENDPOINT, credential=DefaultAzureCredential())
    container = cosmos_client.get_database_client(DATABASE_NAME).get_container_client(CONTAINER_NAME)
    aoai_client = AzureOpenAI(azure_endpoint=AOAI_ENDPOINT, api_key=AOAI_KEY, api_version="2024-06-01")
 
    print(f"Question: {question}\n")
 
    query_vector = embed_query(aoai_client, question)
    retrieved = retrieve(container, query_vector, TOP_K)
 
    print(f"Retrieved {len(retrieved)} similar transactions:")
    for r in retrieved:
        print(f"  [{r['transactionId']}] score={r['SimilarityScore']:.4f} - {r['productName']}")
    print()
 
    answer = generate_answer(aoai_client, question, retrieved)
    print("Answer:\n" + answer)
 
 
if __name__ == "__main__":
    main()

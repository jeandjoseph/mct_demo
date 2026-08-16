"""
Reads saleshistory.json, calls Azure OpenAI to create a vector embedding for
each transaction's review text, and upserts every item (original data +
embedding) into the Cosmos DB container. The source JSON file itself never
contains embeddings -- they only exist once written into Cosmos DB.
"""
import json
import os

from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential
from openai import AzureOpenAI

COSMOS_ENDPOINT = os.environ["COSMOS_ENDPOINT"].strip().strip()
DATABASE_NAME = os.environ["COSMOS_DATABASE"]
CONTAINER_NAME = os.environ["COSMOS_CONTAINER"]

AOAI_ENDPOINT = os.environ["AOAI_ENDPOINT"].strip().strip()
AOAI_KEY = os.environ["AOAI_KEY"].strip().strip()
AOAI_EMBED_DEPLOYMENT = os.environ["AOAI_EMBED_DEPLOYMENT"]
EMBED_DIMENSIONS = int(os.environ.get("EMBED_DIMENSIONS", "256"))

DATA_FILE = os.environ.get("SALES_DATA_FILE", "saleshistory.json")


def main():
    # Cosmos DB: authenticate with Azure AD, using the RBAC role the
    # deploy script already assigned to your signed-in user -- no keys.
    cosmos_client = CosmosClient(url=COSMOS_ENDPOINT, credential=DefaultAzureCredential())
    container = cosmos_client.get_database_client(DATABASE_NAME).get_container_client(CONTAINER_NAME)

    aoai_client = AzureOpenAI(
        azure_endpoint=AOAI_ENDPOINT,
        api_key=AOAI_KEY,
        api_version="2024-06-01",
    )

    with open(DATA_FILE, "r", encoding="utf-8") as f:
        transactions = json.load(f)

    print(f"Loaded {len(transactions)} transactions from {DATA_FILE}")

    for i, txn in enumerate(transactions, start=1):
        embed_source = (
            f"Product: {txn['productName']}. "
            f"Category: {txn['category']}. "
            f"Customer rating: {txn['reviewRating']} out of 5. "
            f"Review: {txn['reviewText']}"
        )

        response = aoai_client.embeddings.create(
            input=embed_source,
            model=AOAI_EMBED_DEPLOYMENT,
            dimensions=EMBED_DIMENSIONS,
        )
        vector = response.data[0].embedding

        item = dict(txn)
        item["reviewTextVector"] = vector

        container.upsert_item(item)
        print(f"[{i}/{len(transactions)}] Upserted {txn['transactionId']} ({txn['productName']})")

    print("Done. All transactions embedded and stored in Cosmos DB.")


if __name__ == "__main__":
    main()

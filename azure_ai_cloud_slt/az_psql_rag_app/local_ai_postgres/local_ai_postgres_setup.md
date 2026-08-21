## Prerequisites
### Upgrade pip first

```powershell
python -m pip install --upgrade pip
```
### 1. Install Application Dependencies

```
# create python virtual environment
python -m venv py_env

# activate python virtual environment
**py_venv\Scripts\Activate.ps1

# install dependencies
pip install -r dependencies.txt
```


### 2 Setting up Local AI Product Intelligence: Setup Guide

End to end setup for running the local Streamlit app with **PostgreSQL + pgvector** in Docker, local **BGE embeddings**, local **sentiment**, and local **PII redaction** with Presidio.

---

### Launch Postgresql Docker Container

- **Docker Desktop** installed and running
- **Python 3.10+** installed
- Project folder: `C:\demo_poc\az-postgresql\container`

```powershell
cd C:\demo_poc\postgresql\local_ai_postgres\container
```

---

## 2. Docker: Build and Manage the PostgreSQL Container

### 2.1 Build and start the container

- Two sql script files will be  copied and executed

```powershell
# Build with the corrected Compose file and start in detached mode
docker compose up -d --build
```

### 2.2 Verify the container is healthy

```powershell
# Check container status
docker ps -a

# View container logs
docker logs local_postgresql
```

### 2.3 Connect to PostgreSQL inside the container

```powershell
# Open psql session inside the container
docker exec -it local_postgresql psql -U admin -d demo_db
```

### 2.4 Inspect database objects from the psql prompt

```sql
-- List tables created by your first script
\dt

-- List functions created by your second script
\df
```

### 2.5 Exit psql

```text
q     -- Exit a paged view (\dt, \df output) and return to the psql prompt
\q    -- Quit psql and return to the shell
```

---
### 3 generate vector embedings

```python
python C:\demo_poc\postgresql\local_ai_postgres\embedings\generate_products_vector.py
```
### generate products review sentiment analysis

```python
python C:\demo_poc\postgresql\local_ai_postgres\embedings\perform_sentiment_analysis.py
```

---

## 4. Run the Streamlit App

From the project root:

```powershell
streamlit run app.py
```

The app will open at `http://localhost:8501`.

---



### 2.6 Tear down when needed

```powershell
# Stop and delete the container plus its volumes (destroys data)
docker compose down -v
```


## 5. Notes

- **Container name**: The commands assume the PostgreSQL container is named `local_postgresql`. Adjust if your Compose file uses a different `container_name`.
- **Database and user**: `demo_db` and `admin` must match the values in your `docker-compose.yml`.
- **Embedding model**: `BAAI/bge-small-en-v1.5` produces **384 dimensional** vectors. Make sure your `products_vector.embedding` column is defined as `VECTOR(384)`.
- **PII redaction fallback**: The app uses **Presidio** when available and falls back to a **regex based redactor** when Presidio or spaCy models are missing.
- **spaCy model choice**: `en_core_web_lg` gives the best entity recognition. Use `en_core_web_sm` if you need a lighter footprint.
- **`docker compose down -v` is destructive**: The `-v` flag deletes named volumes and permanently removes all database data. Use `docker compose down` without `-v` to keep your data.
- **Environment variables**: Store your Postgres connection string in a `.env` file at the project root:

  ```env
  POSTGRES_CONNECT_STRING=postgresql://admin:yourpassword@localhost:5432/demo_db
  ```

- **Duplicated installs removed**: `sentence-transformers`, `psycopg2-binary`, `presidio-analyzer`, and `presidio-anonymizer` are installed once each in the section where they logically belong.

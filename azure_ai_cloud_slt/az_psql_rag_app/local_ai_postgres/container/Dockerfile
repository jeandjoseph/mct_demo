FROM ankane/pgvector:latest

# Set environment variables for PostgreSQL
ENV POSTGRES_USER=admin
ENV POSTGRES_PASSWORD=AdminPass123!
ENV POSTGRES_DB=demo_db

# Copy SQL scripts into the automatic initialization folder
# PostgreSQL will execute them in alphabetical order
COPY sql_scripts/*.sql /docker-entrypoint-initdb.d/

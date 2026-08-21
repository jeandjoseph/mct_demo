import os
import psycopg2
from dotenv import load_dotenv


class PostgresClient:
    def __init__(self, env_var: str = "POSTGRES_CONNECT_STRING"):
        load_dotenv()

        self.connect_string = os.getenv(env_var)

        if not self.connect_string:
            raise ValueError(
                f"Environment variable '{env_var}' was not found or is empty."
            )

    def run_query(self, sql_query: str, params: tuple = None) -> dict:
        try:
            with psycopg2.connect(self.connect_string) as conn:
                with conn.cursor() as cursor:
                    cursor.execute(sql_query, params)

                    if cursor.description is None:
                        conn.commit()
                        return {
                            "columns": [],
                            "rows": []
                        }

                    rows = cursor.fetchall()
                    columns = [desc[0] for desc in cursor.description]

                    return {
                        "columns": columns,
                        "rows": rows
                    }

        except Exception as e:
            return {
                "columns": ["error"],
                "rows": [(str(e),)]
            }
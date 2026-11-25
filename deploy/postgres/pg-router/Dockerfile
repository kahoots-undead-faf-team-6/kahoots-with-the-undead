# mituvladlen/pg-router: the router + failover in front of a replicated PostgreSQL (deploy/postgres/README.md)
FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY pgrouter ./pgrouter
COPY VERSION .

# Not root; /var/log/kahoots is the shared logs volume (LOG_DIR)
RUN useradd --system --uid 10001 pgrouter && mkdir -p /var/log/kahoots && chown pgrouter /var/log/kahoots
USER pgrouter

# 5432 writes (primary), 5433 reads (standbys), 8008 /status /metrics /health
EXPOSE 5432 5433 8008
CMD ["python", "-m", "pgrouter"]

FROM python:3.12-slim
LABEL org.opencontainers.image.source="https://github.com/anindyar/memsvc" \
      org.opencontainers.image.description="Multi-tenant memory for AI agents as an MCP server (Postgres + pgvector)" \
      org.opencontainers.image.licenses="Apache-2.0"
RUN pip install --no-cache-dir "mcp[cli]==1.*" "psycopg[binary]==3.*" httpx \
 && useradd -u 10001 -m memsvc && mkdir -p /srv/memory && chown 10001:10001 /srv/memory
COPY memsvc.py /app/memsvc.py
USER 10001
EXPOSE 8041
CMD ["python", "/app/memsvc.py"]

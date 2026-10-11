#!/usr/bin/env bash
# Bring up the whole team-kit stack on this host. Safe to re-run.
set -e
cd "$(dirname "$0")"
# Storage mode per team: md = markdown files + pgvector index, pg = pgvector only.
MEM_MODES=${MEM_MODES:-alpha=md,beta=pg}
# 1. Postgres + pgvector (memory store/index + gateway request logs). Temporary: ./down.sh removes it.
docker start agwkit-pgvector 2>/dev/null || \
  docker run -d --name agwkit-pgvector -e POSTGRES_PASSWORD=pgkit -p 127.0.0.1:5441:5432 pgvector/pgvector:pg17
until docker exec agwkit-pgvector pg_isready -U postgres -q; do sleep 1; done
docker exec -i agwkit-pgvector psql -U postgres -q -v ON_ERROR_STOP=1 < schema.sql
docker exec agwkit-pgvector psql -U postgres -tAc "select 1 from pg_database where datname='agwlogs'" | grep -q 1 || \
  docker exec agwkit-pgvector psql -U postgres -qc "create database agwlogs"
# 2. embedding model in the local Ollama (any OpenAI-compatible embedder works, see config.yaml)
curl -s http://127.0.0.1:11434/api/pull -d '{"name":"nomic-embed-text","stream":false}' >/dev/null
# 3. memory MCP service (markdown files for md-mode teams live in ./memory)
mkdir -p memory
docker build -q -t agwkit-memsvc . >/dev/null
docker rm -f agwkit-memsvc >/dev/null 2>&1 || true
docker run -d --name agwkit-memsvc --network host --user "$(id -u):$(id -g)" -v "$PWD/memory:/srv/memory" \
  -e PORT=8041 -e MEM_MODES="$MEM_MODES" \
  -e MEM_DB=postgresql://memsvc:memsvc@127.0.0.1:5441/postgres \
  -e MEM_GATEWAY=http://127.0.0.1:8031 -e MEM_GATEWAY_KEY=sk-memsvc-demo agwkit-memsvc >/dev/null
# 4. agentgateway on :8031
agentgateway -f config.yaml --validate-only
[ -f gateway.pid ] && kill "$(cat gateway.pid)" 2>/dev/null && sleep 1 || true
setsid nohup agentgateway -f config.yaml > gateway.log 2>&1 < /dev/null & echo $! > gateway.pid
until curl -sf http://127.0.0.1:15221/healthz/ready >/dev/null; do sleep 1; done
echo "up: gateway on :8031, UI at http://<this-host>:8031/ui, memory modes: $MEM_MODES"

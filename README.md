# memsvc: multi-tenant memory for AI agents, as an MCP server

memsvc is a small (~180 lines) MCP server that gives AI agents and dev teams long-term memory, using Postgres + pgvector. It is built to sit behind an API gateway (the reference setup uses [agentgateway](https://github.com/agentgateway/agentgateway)). **The tenant comes from the caller's API key, not from anything the client sends.**

- **5 MCP tools:** `memory_write`, `memory_search`, `memory_get`, `memory_forget`, `memory_reindex`
- **2 storage modes behind the same tools,** chosen per tenant:
  - `md`: markdown files are the source of truth and pgvector is a rebuildable search index. Humans and agents edit the same files, and changes can be reviewed in git.
  - `pg`: pure pgvector. Each memory is a row with tags, and there are no files.
- **Tenant isolation is enforced twice:** the gateway stamps the tenant from the API key, and Postgres row-level security filters every query.
- **Any OpenAI-compatible embedder** (Ollama, vLLM, TEI, a cloud API), reached through the same gateway.

## Why this exists

Popular open-source memory servers let **the client choose the tenant**:

| Project | How the tenant is selected | What goes wrong on a shared platform |
|---|---|---|
| [Graphiti MCP](https://github.com/getzep/graphiti/tree/main/mcp_server) (Zep) | `group_id` / `group_ids` **tool arguments**. The server flag `--group-id` only sets the default (`main`) | In `src/graphiti_mcp_server.py` every tool uses `group_id or config.graphiti.group_id`, and nothing in the server ties a caller to a group. A client can pass another team's `group_id` and read or delete that team's episodes and facts. A client that leaves it out writes into the shared default group. It also needs a second database (FalkorDB or Neo4j) |
| [mem0](https://github.com/mem0ai/mem0) (self-hosted server) | `user_id` / `agent_id` / `run_id` **request fields** | In `server/main.py` the auth dependency (`_auth=Depends(verify_auth)`) only checks that the key is valid, and its result is not used. Search and list use whatever `user_id` the request carries. `GET`/`PUT`/`DELETE /memories/{id}` act on any memory id with no owner check. Any valid key can reach every team's memory. The official MCP endpoint is for the hosted service, so self-hosted MCP also needs a community adapter |

Checked against Graphiti `0a3b171` (2026-10-11) and mem0 `b7ad69a` (2026-10-07).

Both are good products for one team or one application. On a platform that many teams share, isolation that depends on every client sending the right id is not isolation. The workarounds are to run one instance per team, or to write a proxy that rewrites the id. You then own the proxy, and every team gets its own deployment to operate.

memsvc removes the argument. No tool takes a tenant parameter. The tenant is read from the `X-Team` header, which the gateway sets from the authenticated API key and overwrites if the client sent one. Postgres row-level security then applies to every statement, so even a bug in memsvc cannot return another tenant's rows.

## Architecture

```
client ──(team API key)──▶ agentgateway ──(sets X-Team from the key)──▶ memsvc :8041/mcp ──▶ Postgres + pgvector
         MCP over HTTP      checks the key,                              5 memory_* tools      RLS: tenant = app.tenant
                            per-tool allowlist (mcpAuthorization)            │
                                                                             └─▶ embeddings via the gateway (own key)
```

**Trust boundary.** memsvc trusts the `X-Team` header, so **only the gateway may be able to reach it.** The reference setup binds it to `127.0.0.1`. On Kubernetes, use a ClusterIP Service and a NetworkPolicy that admits only the gateway pods.

## Quick start (single host, reference setup)

Requirements: Docker, [agentgateway](https://github.com/agentgateway/agentgateway) 1.5+ on `PATH`, an OpenAI-compatible embedding server (the example uses Ollama with `nomic-embed-text`, 768-dim), and OpenAI-compatible chat backends if you want to run the inference checks.

```bash
git clone https://github.com/anindyar/memsvc && cd memsvc
# point the models: section of config.yaml at your backends
./up.sh          # pgvector, embed model, memsvc, gateway on :8031
./reset.sh       # clean memory
./e2e_test.sh    # 27 checks: identity, model scoping, tool scoping, both memory modes, isolation, delete path
./down.sh        # remove everything
```

Try it as a client:

```bash
docker run --rm --network host -v $PWD/mcp_client.py:/c.py agwkit-memsvc python /c.py sk-alpha-demo list
docker run --rm --network host -v $PWD/mcp_client.py:/c.py agwkit-memsvc \
  python /c.py sk-alpha-demo call memory_write '{"text":"Staging is patched every Sunday 02:00-04:00 UTC"}'
```

## Files

| File | Purpose |
|---|---|
| `memsvc.py` | the MCP server |
| `Dockerfile` | python:3.12-slim + `mcp`, `psycopg`, `httpx` |
| `schema.sql` | `memory` table for both modes, HNSW index, `memsvc` role, RLS policy |
| `config.yaml` | example agentgateway config: team keys, model aliases, MCP target, `X-Team` stamping, per-tool rules |
| `up.sh` / `down.sh` / `reset.sh` | start / remove / wipe the reference stack |
| `e2e_test.sh` + `mcp_client.py` | end-to-end checks and a tiny MCP client |

## Configuration (environment)

| Variable | Default | Meaning |
|---|---|---|
| `MEM_DB` | required | Postgres DSN. Use a **non-owner** role so RLS applies (`schema.sql` creates `memsvc`) |
| `MEM_GATEWAY` | required | gateway base URL, used for `/v1/embeddings` |
| `MEM_GATEWAY_KEY` | required | memsvc's own key. Allow it only the embedding model |
| `MEM_EMBED_MODEL` | `embed` | embedding model name or alias at the gateway |
| `MEM_ROOT` | `/srv/memory` | where md-mode markdown lives (`<root>/<tenant>/*.md`) |
| `MEM_MODES` | empty | per-tenant mode, e.g. `alpha=md,beta=pg` |
| `MEM_DEFAULT_MODE` | `pg` | mode for tenants not listed |
| `HOST` / `PORT` | `127.0.0.1` / `8041` | listen address |

The gateway side needs three things, all in `config.yaml`: API keys with a `team` metadata field, a request transformation `x-team: apiKey.team` on the MCP route, and `mcpAuthorization` rules if some tenants should get fewer tools.

## Tools

| Tool | md mode | pg mode |
|---|---|---|
| `memory_write(text, tags?, file?)` | appends a dated line to `<tenant>/<file>` (default `MEMORY.md`) and reindexes that file | inserts a row with tags |
| `memory_search(query, k?)` | semantic search over the tenant's rows. Hits carry `id`, `source`, and `path`/`line` for md | same |
| `memory_get(id?, file?)` | one item by id, or the whole markdown file | one item by id, or the 20 newest |
| `memory_forget(id)` | removes the line from the file and reindexes it. Refuses if the file changed since indexing | deletes the row |
| `memory_reindex()` | rebuilds the index from the files (after hand edits) | re-embeds every row (after an embedding-model change) |

## Known limits

This is a working reference, not a hardened product. Contributions are welcome on any of these:

- The embedding dimension is fixed at 768 in `schema.sql`. Change it to match your model.
- md mode stores one chunk per non-heading line, and concurrent writers to the same file are not locked.
- Each tool call opens a new database connection (no pool).
- The demo credentials (`sk-*-demo` keys, `memsvc`/`pgkit` passwords) are placeholders. Use a secret manager for real deployments.
- No hybrid (keyword + vector) search, no reranking, and no LLM fact extraction. Writes are stored as given.

## Contributing

Issues and pull requests are welcome. Keep the core properties: **no tool takes a tenant argument**, RLS stays on, and `./e2e_test.sh` passes. Add a check to `e2e_test.sh` for any new behaviour.

## License

[Apache-2.0](LICENSE)

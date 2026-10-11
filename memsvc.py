"""Memory Context Service, exposed as an MCP server behind agentgateway.

Two storage modes behind the same tools, chosen per team:
  md  markdown files are the source of truth; pgvector is a derived search index (rebuildable)
  pg  pgvector is the store; each memory is a row, no files
The gateway injects the caller's team in X-Team; Postgres row-level security isolates teams."""
import os, re, glob, datetime
import httpx, psycopg
from mcp.server.fastmcp import FastMCP, Context

DB = os.environ["MEM_DB"]                      # postgres DSN for the non-owner role memsvc
GW = os.environ["MEM_GATEWAY"]                 # agentgateway base URL
GW_KEY = os.environ["MEM_GATEWAY_KEY"]         # service key, allowed only the embed model
EMBED_MODEL = os.environ.get("MEM_EMBED_MODEL", "embed")
ROOT = os.environ.get("MEM_ROOT", "/srv/memory")
# Per-team storage mode, e.g. "alpha=md,beta=pg". Teams not listed get MEM_DEFAULT_MODE.
MODES = dict(p.split("=") for p in os.environ.get("MEM_MODES", "").split(",") if "=" in p)
DEFAULT_MODE = os.environ.get("MEM_DEFAULT_MODE", "pg")

mcp = FastMCP("memory", host=os.environ.get("HOST", "127.0.0.1"), port=int(os.environ.get("PORT", "8041")))


def team(ctx: Context) -> str:
    # Set by the gateway from the caller's API key; clients cannot choose it.
    t = ctx.request_context.request.headers.get("x-team", "")
    if not t or not t.isalnum():
        raise ValueError("no team identity on request (call through the gateway)")
    return t


def mode(t: str) -> str:
    return MODES.get(t, DEFAULT_MODE)


def embed(texts: list[str]) -> list[list[float]]:
    r = httpx.post(f"{GW}/v1/embeddings", headers={"Authorization": f"Bearer {GW_KEY}"},
                   json={"model": EMBED_MODEL, "input": texts}, timeout=60)
    r.raise_for_status()
    return [d["embedding"] for d in r.json()["data"]]


def conn(tenant: str):
    c = psycopg.connect(DB)
    c.execute("select set_config('app.tenant', %s, false)", (tenant,))  # drives row-level security
    return c


# ---- md mode helpers -------------------------------------------------------

def chunks(path: str):
    """One chunk per non-empty line that is not a heading."""
    with open(path) as f:
        for n, line in enumerate(f, 1):
            s = line.strip()
            if s and not s.startswith("#"):
                yield n, s.lstrip("- ").strip()


def index_file(c, tenant: str, path: str):
    rel = os.path.relpath(path, ROOT)
    c.execute("delete from memory where source = 'md' and path = %s", (rel,))
    rows = list(chunks(path))
    if rows:
        vecs = embed([t for _, t in rows])
        for (n, t), v in zip(rows, vecs):
            c.execute("insert into memory(tenant, source, path, line, content, embedding) "
                      "values (%s, 'md', %s, %s, %s, %s::vector)", (tenant, rel, n, t, str(v)))


def team_file(t: str, file: str) -> str:
    name = os.path.basename(file)
    if not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9_.-]*\.md", name):
        raise ValueError("file must be a plain .md file name, e.g. MEMORY.md")
    return f"{ROOT}/{t}/{name}"


# ---- tools -----------------------------------------------------------------

@mcp.tool()
def memory_write(text: str, ctx: Context, tags: list[str] | None = None, file: str = "MEMORY.md") -> str:
    """Remember a fact for the team. md mode appends it to a markdown file; pg mode stores it as a row."""
    t = team(ctx)
    if mode(t) == "md":
        os.makedirs(f"{ROOT}/{t}", exist_ok=True)
        path = team_file(t, file)
        if not os.path.exists(path):
            with open(path, "w") as f:
                f.write(f"# {t} memory\n\n")
        with open(path, "a") as f:
            f.write(f"- {datetime.date.today()}: {text}\n")
        with conn(t) as c:
            index_file(c, t, path)
        return f"saved to {t}/{os.path.basename(file)} (md)"
    v = embed([text])[0]
    with conn(t) as c:
        i = c.execute("insert into memory(tenant, source, content, tags, embedding) "
                      "values (%s, 'pg', %s, %s, %s::vector) returning id",
                      (t, text, tags or [], str(v))).fetchone()[0]
    return f"saved as memory #{i} (pg)"


@mcp.tool()
def memory_search(query: str, ctx: Context, k: int = 5) -> list[dict]:
    """Semantic search over the team's memory. Each hit has an id, and file/line when it came from markdown."""
    t = team(ctx)
    v = embed([query])[0]
    with conn(t) as c:
        rows = c.execute("select id, source, path, line, content, 1 - (embedding <=> %s::vector) "
                         "from memory order by embedding <=> %s::vector limit %s",
                         (str(v), str(v), k)).fetchall()
    return [{"id": i, "source": s, "path": p, "line": l, "text": x, "score": round(sc, 3)}
            for i, s, p, l, x, sc in rows]


@mcp.tool()
def memory_get(ctx: Context, id: int | None = None, file: str = "MEMORY.md") -> str:
    """Read memory: one item by id, otherwise the team's markdown file (md) or its 20 newest items (pg)."""
    t = team(ctx)
    with conn(t) as c:
        if id is not None:
            r = c.execute("select source, path, line, content, created from memory where id = %s", (id,)).fetchone()
            return f"#{id} [{r[0]}{' ' + r[1] + ':' + str(r[2]) if r[1] else ''}] {r[3]}" if r else f"no memory #{id}"
        if mode(t) == "pg":
            rows = c.execute("select id, content, tags from memory where source = 'pg' "
                             "order by id desc limit 20").fetchall()
            return "\n".join(f"#{i} {x}" + (f"  {tg}" if tg else "") for i, x, tg in rows) or f"(no memory for team {t} yet)"
    path = team_file(t, file)
    if not os.path.exists(path):
        return f"(no {file} for team {t} yet)"
    with open(path) as f:
        return f.read()


@mcp.tool()
def memory_forget(id: int, ctx: Context) -> str:
    """Delete one memory by id. In md mode the line is also removed from its markdown file."""
    t = team(ctx)
    with conn(t) as c:
        r = c.execute("select source, path, line, content from memory where id = %s", (id,)).fetchone()
        if not r:
            return f"no memory #{id}"
        src, rel, line, content = r
        if src == "md":
            path = os.path.join(ROOT, rel)
            with open(path) as f:
                lines = f.readlines()
            # The file may have been hand-edited since it was indexed; never delete the wrong line.
            if line > len(lines) or lines[line - 1].strip().lstrip("- ").strip() != content:
                raise ValueError(f"{rel} changed since it was indexed; run memory_reindex and search again")
            del lines[line - 1]
            with open(path, "w") as f:
                f.writelines(lines)
            index_file(c, t, path)                  # line numbers shift, so reindex the whole file
            return f"forgot #{id}: removed {rel}:{line}"
        c.execute("delete from memory where id = %s", (id,))
    return f"forgot #{id}"


@mcp.tool()
def memory_reindex(ctx: Context) -> str:
    """md mode: rebuild the index from the markdown files (after hand edits).
    pg mode: re-embed every stored memory (after changing the embedding model)."""
    t = team(ctx)
    with conn(t) as c:
        if mode(t) == "md":
            c.execute("delete from memory where source = 'md'")      # RLS limits this to the caller's team
            files = sorted(glob.glob(f"{ROOT}/{t}/*.md"))
            for p in files:
                index_file(c, t, p)
            n = c.execute("select count(*) from memory where source = 'md'").fetchone()[0]
            return f"reindexed {len(files)} file(s), {n} chunk(s) for team {t}"
        rows = c.execute("select id, content from memory where source = 'pg'").fetchall()
        for (i, _), v in zip(rows, embed([x for _, x in rows]) if rows else []):
            c.execute("update memory set embedding = %s::vector where id = %s", (str(v), i))
    return f"re-embedded {len(rows)} memories for team {t}"


if __name__ == "__main__":
    mcp.run(transport="streamable-http")

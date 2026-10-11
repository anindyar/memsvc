"""Tiny MCP client for the team kit.
usage: python mcp_client.py <team-key> list
       python mcp_client.py <team-key> call <tool> '<json-args>'"""
import sys, json, asyncio, logging, os
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

GATEWAY = os.environ.get("GATEWAY_URL", "http://127.0.0.1:8031") + "/mcp"
logging.disable(logging.WARNING)


async def main(key, cmd, *rest):
    async with streamablehttp_client(GATEWAY, headers={"Authorization": f"Bearer {key}"}) as (r, w, _):
        async with ClientSession(r, w) as s:
            await s.initialize()
            if cmd == "list":
                return "\n".join(t.name for t in (await s.list_tools()).tools), 0
            res = await s.call_tool(rest[0], json.loads(rest[1]) if len(rest) > 1 else {})
            return "\n".join(getattr(c, "text", str(c)) for c in res.content), int(res.isError)


def first_error(e):
    while isinstance(e, BaseExceptionGroup):
        e = e.exceptions[0]
    return e


try:
    out, code = asyncio.run(main(*sys.argv[1:]))
    print(out)
except BaseException as e:
    e = first_error(e)
    resp = getattr(e, "response", None)
    print(f"DENIED by gateway: HTTP {resp.status_code}" if resp is not None else f"ERROR: {e}")
    code = 1
sys.exit(code)

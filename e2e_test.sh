#!/usr/bin/env bash
# End-to-end test of the team kit through agentgateway. Prints PASS/FAIL per check.
# Expects a clean start (./reset.sh) and the default modes alpha=md, beta=pg.
set -u
G=${GATEWAY_URL:-http://127.0.0.1:8031}
DIR=$(cd "$(dirname "$0")" && pwd)
MCP="docker run --rm --network host -e GATEWAY_URL=$G -v $DIR/mcp_client.py:/c.py agwkit-memsvc python /c.py"
pass=0; fail=0
result() { if [ "$1" = ok ]; then echo "PASS  $2"; pass=$((pass+1)); else echo "FAIL  $2"; echo "      got: $(head -c 300 <<<"$3")"; fail=$((fail+1)); fi; }
check()  { local n=$1 w=$2; shift 2; local o; o=$("$@" 2>&1); grep -qF -- "$w" <<<"$o" && result ok "$n" || result no "$n" "$o"; }   # output contains
absent() { local n=$1 w=$2; shift 2; local o; o=$("$@" 2>&1); grep -qF -- "$w" <<<"$o" && result no "$n" "$o" || result ok "$n"; }   # output does not contain
chat()  { curl -s -w ' HTTP %{http_code}' "$G/v1/chat/completions" -H "Authorization: Bearer $1" -H 'content-type: application/json' \
          -d "{\"model\":\"$2\",\"max_tokens\":40,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the word ok\"}]}"; }
embed() { curl -s -w ' HTTP %{http_code}' "$G/v1/embeddings" -H "Authorization: Bearer $1" -H 'content-type: application/json' -d '{"model":"embed","input":"test"}'; }
models() { curl -s "$G/v1/models" -H "Authorization: Bearer $1"; }
sql()   { docker exec agwkit-pgvector psql -U postgres -tAc "$1"; }
# Raw MCP call with an extra header, to prove a client cannot pick its own team.
mcp_raw() {  # mcp_raw <key> <extra-header> <tool> <json-args>
  local h=(-H 'accept: application/json, text/event-stream' -H 'content-type: application/json' -H "Authorization: Bearer $1" -H "$2")
  local sid; sid=$(curl -s -D - -o /dev/null -X POST "$G/mcp" "${h[@]}" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}' \
    | awk 'tolower($1)=="mcp-session-id:"{print $2}' | tr -d '\r')
  curl -s -o /dev/null -X POST "$G/mcp" "${h[@]}" -H "mcp-session-id: $sid" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  curl -s -X POST "$G/mcp" "${h[@]}" -H "mcp-session-id: $sid" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$3\",\"arguments\":$4}}"
}

echo "== 1. Identity"
check  "no key -> 401"                         "HTTP 401"       curl -s -w ' HTTP %{http_code}' "$G/v1/models"
check  "unknown key -> 401 on MCP"             "HTTP 401"       $MCP sk-nope list

echo "== 2. Inference plane"
check  "alpha model list has chat-general"     '"chat-general"' models sk-alpha-demo
absent "alpha model list hides chat-vision"    "chat-vision"    models sk-alpha-demo
check  "alpha -> chat-general allowed"         "HTTP 200"       chat sk-alpha-demo chat-general
check  "alpha -> chat-vision denied"           "HTTP 403"       chat sk-alpha-demo chat-vision
check  "beta  -> chat-vision allowed"          "HTTP 200"       chat sk-beta-demo chat-vision
check  "beta  -> chat-general denied"          "HTTP 403"       chat sk-beta-demo chat-general
check  "embeddings allowed for both teams"     "HTTP 200"       embed sk-beta-demo

echo "== 3. Tool plane (MCP)"
check  "alpha sees memory_forget"              "memory_forget"  $MCP sk-alpha-demo list
absent "beta does not see memory_forget"       "memory_forget"  $MCP sk-beta-demo list
check  "beta call memory_forget denied"        "DENIED"         $MCP sk-beta-demo call memory_forget '{"id":1}'

echo "== 4. Memory, md mode (alpha): markdown is the source of truth"
check  "alpha writes a memory"                 "saved to alpha/MEMORY.md (md)" \
       $MCP sk-alpha-demo call memory_write '{"text":"The staging cluster is patched every Sunday 02:00-04:00 UTC; expect API downtime"}'
check  "alpha finds it by meaning"             "staging cluster" \
       $MCP sk-alpha-demo call memory_search '{"query":"when is the maintenance window for staging?","k":1}'
check  "it is a line in alpha/MEMORY.md"       "staging cluster" cat "$DIR/memory/alpha/MEMORY.md"
echo "- On-call handover is every Monday at 09:00 in the #ops-oncall channel" >> "$DIR/memory/alpha/MEMORY.md"
check  "hand edit + memory_reindex"            "reindexed"      $MCP sk-alpha-demo call memory_reindex '{}'
check  "hand-edited fact is searchable"        "handover"       $MCP sk-alpha-demo call memory_search '{"query":"what time is the on-call handover","k":1}'

echo "== 5. Memory, pg mode (beta): pgvector is the store, no files"
check  "beta writes a memory"                  "(pg)" \
       $MCP sk-beta-demo call memory_write '{"text":"Purchase orders above 50,000 USD need CFO approval before release","tags":["finance","policy"]}'
check  "beta finds it by meaning"              "CFO approval" \
       $MCP sk-beta-demo call memory_search '{"query":"who signs off on large purchases?","k":1}'
check  "no markdown file exists for beta"      "none"           bash -c "ls $DIR/memory/beta 2>/dev/null || echo none"
check  "it is a row in pgvector (source=pg)"   "beta|pg|"       sql "select tenant, source, coalesce(path,'') from memory where content like 'Purchase orders%'"

echo "== 6. Isolation between teams"
absent "beta cannot find alpha's memory"       "staging"        $MCP sk-beta-demo  call memory_search '{"query":"staging maintenance window","k":5}'
absent "alpha cannot find beta's memory"       "CFO"            $MCP sk-alpha-demo call memory_search '{"query":"purchase approval","k":5}'
absent "beta spoofing X-Team: alpha gets nothing of alpha's" "staging" \
       mcp_raw sk-beta-demo 'x-team: alpha' memory_search '{"query":"staging maintenance window"}'

echo "== 7. Delete path (alpha, md mode)"
ID=$($MCP sk-alpha-demo call memory_search '{"query":"staging maintenance window","k":1}' | grep -o '"id": *[0-9]*' | head -1 | grep -o '[0-9]*$')
check  "memory_forget removes the line"        "removed alpha/MEMORY.md" $MCP sk-alpha-demo call memory_forget "{\"id\":${ID:-0}}"
absent "line is gone from the markdown file"   "staging cluster" cat "$DIR/memory/alpha/MEMORY.md"
absent "and from the index"                    "staging cluster" sql "select content from memory where tenant='alpha'"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

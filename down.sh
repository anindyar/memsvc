#!/usr/bin/env bash
# Remove everything up.sh started. Other services on the host are not touched.
cd "$(dirname "$0")"
[ -f gateway.pid ] && kill "$(cat gateway.pid)" 2>/dev/null; rm -f gateway.pid
docker rm -f agwkit-memsvc agwkit-pgvector 2>/dev/null
echo "down (memory/*.md kept; delete the folder to remove them)"

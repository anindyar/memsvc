#!/usr/bin/env bash
# Wipe all memory (markdown files + database rows) so the test starts clean.
cd "$(dirname "$0")"
docker run --rm -v "$PWD/memory:/m" alpine sh -c 'rm -rf /m/*'
docker exec agwkit-pgvector psql -U postgres -qc "truncate memory"

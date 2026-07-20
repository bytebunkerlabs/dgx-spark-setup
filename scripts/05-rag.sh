#!/usr/bin/env bash
# 05-rag.sh — stand up the RAG vector store (Postgres + pgvector).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_dgx

COMPOSE="docker compose -f ${REPO_ROOT}/compose/rag.yml --env-file ${REPO_ROOT}/.env"

step "RAG store (pgvector) for RAG"

[[ "${PG_PASSWORD}" == "change-me-strong" ]] && \
  warn "PG_PASSWORD is still the default — change it in .env before exposing anything."

$COMPOSE pull
$COMPOSE up -d

log "Waiting for Postgres…"
for i in $(seq 1 20); do
  if docker compose -f "${REPO_ROOT}/compose/rag.yml" --env-file "${REPO_ROOT}/.env" \
        exec -T pgvector pg_isready -U "${PG_USER}" -d "${PG_DB}" >/dev/null 2>&1; then
    ok "Postgres ready"
    break
  fi
  sleep 3
done

# Confirm the extension + schema landed. (psql -c takes ONE command; SQL and a
# backslash meta-command like \dt can't share a single -c, so pass two.)
log "Verifying pgvector + schema…"
docker compose -f "${REPO_ROOT}/compose/rag.yml" --env-file "${REPO_ROOT}/.env" \
  exec -T pgvector psql -U "${PG_USER}" -d "${PG_DB}" \
  -c "SELECT extname, extversion FROM pg_extension WHERE extname='vector';" \
  -c "\dt documents" \
  2>/dev/null | sed 's/^/    /' || warn "verification query failed"

echo
ok "RAG store up."
cat <<EOF

  Connection string for the RAG app:
    postgresql://${PG_USER}:<password>@127.0.0.1:${PG_PORT}/${PG_DB}

  Embeddings are served through the LiteLLM gateway as 'nomic-embed-text'
  (768-dim — matches the VECTOR(768) column). Embed with:

    curl http://127.0.0.1:${LITELLM_PORT}/v1/embeddings \\
      -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \\
      -H "Content-Type: application/json" \\
      -d '{"model":"nomic-embed-text","input":"hello world"}'

  Stop: $COMPOSE down     (add -v to also wipe the data volume)
EOF
log "Next: dgxsetup finetune   or   dgxsetup monitoring"

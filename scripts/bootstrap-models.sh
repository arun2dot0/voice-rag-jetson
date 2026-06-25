#!/usr/bin/env bash
# Pull the chat + embedding models into the running ollama container.
# Run after `docker compose up -d ollama` and before ingesting / querying.
#
# If Docker needs root on your machine, run this whole script with sudo:
#   sudo ./scripts/bootstrap-models.sh
# or point it at a different compose command:
#   DC="sudo docker compose" ./scripts/bootstrap-models.sh
set -euo pipefail

DC="${DC:-docker compose}"
CHAT_MODEL="${CHAT_MODEL:-qwen2.5:3b}"
EMBEDDING_MODEL="${EMBEDDING_MODEL:-nomic-embed-text}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-60}"   # ~2 min at 2s each

echo "Waiting for ollama to be ready (using: ${DC})..."
attempt=0
until $DC exec -T ollama ollama list >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    echo "ERROR: ollama still not reachable after ${MAX_ATTEMPTS} attempts." >&2
    echo "Last error from '$DC exec -T ollama ollama list':" >&2
    $DC exec -T ollama ollama list || true   # show the real error this time
    echo "Hint: if Docker needs root, run: sudo ./scripts/bootstrap-models.sh" >&2
    exit 1
  fi
  sleep 2
done

echo "Pulling embedding model: ${EMBEDDING_MODEL}"
$DC exec -T ollama ollama pull "${EMBEDDING_MODEL}"

echo "Pulling chat model: ${CHAT_MODEL}"
$DC exec -T ollama ollama pull "${CHAT_MODEL}"

echo "Done. Models available:"
$DC exec -T ollama ollama list

#!/usr/bin/env bash
# Warm up the voice stack on the Jetson Orin Nano (8GB unified memory).
#
# Why this exists: cudaMalloc draws from *genuinely free* RAM and will not
# reclaim page cache. After a reboot (or once the cache fills) the LLM and
# whisper cold-loads can OOM with "unable to allocate CUDA0 buffer" /
# "CUDA failed with error out of memory" even though `free -h` shows GB
# "available". This script frees the page cache, then forces both models to
# load and allocate their GPU scratch while memory is free. Once resident
# (OLLAMA_KEEP_ALIVE=-1 for the LLM, CTranslate2's pool for whisper) they stay
# put, so on-demand requests no longer need a big fresh allocation.
#
# See FINDINGS.md §7. Run after `docker compose up -d`, and again after reboots.
#
# Usage:  scripts/warmup.sh
set -euo pipefail

OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
STT_URL="${STT_URL:-http://localhost:8001}"
TTS_URL="${TTS_URL:-http://localhost:8002}"
CHAT_MODEL="${CHAT_MODEL:-qwen2.5:1.5b}"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# --- 1. free page cache so cudaMalloc has room (needs root) -----------------
say "Freeing page cache (drop_caches)"
if [ "$(id -u)" -eq 0 ]; then
  sync; echo 3 > /proc/sys/vm/drop_caches
  echo "done."
elif sudo -n true 2>/dev/null; then
  sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
  echo "done."
else
  echo "  (skipped — needs root). Run this yourself, then re-run warmup:"
  echo "      sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'"
fi
free -h | awk 'NR<=2{print "  "$0}'

# --- 2. wait for services to answer healthz ---------------------------------
wait_health() {  # name url
  local name="$1" url="$2" i
  printf '  waiting for %s' "$name"
  for i in $(seq 1 60); do
    if curl -sf "$url/healthz" >/dev/null 2>&1; then echo " ok"; return 0; fi
    printf '.'; sleep 2
  done
  echo " TIMEOUT"; return 1
}
say "Waiting for services"
wait_health stt "$STT_URL"
wait_health tts "$TTS_URL"
# ollama has no /healthz; check its version endpoint
printf '  waiting for ollama'
for i in $(seq 1 60); do
  curl -sf "$OLLAMA_URL/api/version" >/dev/null 2>&1 && { echo " ok"; break; }
  printf '.'; sleep 2
done

# --- 3. warm the LLM (loads + pins resident) --------------------------------
say "Warming LLM ($CHAT_MODEL) — first load can take ~20s"
curl -s --max-time 180 "$OLLAMA_URL/api/generate" \
  -d "{\"model\":\"$CHAT_MODEL\",\"prompt\":\"hi\",\"stream\":false,\"keep_alive\":-1}" \
  | python3 -c "import sys,json; print('  LLM ready:', json.load(sys.stdin).get('response','')[:50])" \
  || { echo "  LLM warmup FAILED — likely OOM; ensure cache was dropped / close heavy apps"; exit 1; }

# --- 4. warm whisper (allocates + holds GPU scratch) ------------------------
say "Warming STT (whisper) — synthesizing a clip via TTS, then transcribing"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -s --max-time 60 -X POST "$TTS_URL/tts" -H 'content-type: application/json' \
  -d '{"text":"warm up."}' -o "$TMP/warm.wav"
if curl -sf --max-time 90 -X POST "$STT_URL/v1/audio/transcriptions" \
     -F "file=@$TMP/warm.wav" >/dev/null; then
  echo "  STT ready (scratch allocated and held)."
else
  echo "  STT warmup FAILED — likely OOM; ensure cache was dropped / close heavy apps"; exit 1
fi

# --- 5. report resident models ----------------------------------------------
say "Resident models"
curl -s "$OLLAMA_URL/api/ps" \
  | python3 -c "import sys,json;[print('  ',m['name'],m.get('size_vram',m.get('size',0))//(1024*1024),'MB',m.get('size_vram') and '(GPU)') for m in json.load(sys.stdin).get('models',[])]" 2>/dev/null \
  || true
echo
echo "Warmup complete. The voice stack is ready:  scripts/demo.sh \"your question\""

#!/usr/bin/env bash
# Quick end-to-end smoke test of the orchestrator.
set -euo pipefail

HOST="${HOST:-http://localhost:8080}"
QUERY="${1:-What is this blog about?}"

# ALSA devices, by card name so they survive reboots/replugs. Override if your
# hardware differs:  arecord -l / aplay -l to list.  (fifine USB mic + A40 USB
# headset on this box.)
MIC_DEV="${MIC_DEV:-plughw:CARD=Microphone,DEV=0}"
SPK_DEV="${SPK_DEV:-plughw:CARD=A40,DEV=0}"

echo "== text query =="
curl -s -X POST "${HOST}/ask-text" \
  -H 'content-type: application/json' \
  -d "{\"query\": \"${QUERY}\"}" | python3 -m json.tool

echo
echo "== voice query (record 4s from mic, get spoken answer) =="
echo "Recording 4 seconds... speak now."
arecord -q -D "$MIC_DEV" -f S16_LE -r 16000 -c 1 -d 4 /tmp/question.wav

curl -s -X POST "${HOST}/ask" \
  -F "file=@/tmp/question.wav" \
  -D /tmp/answer.headers \
  -o /tmp/answer.wav

echo "Transcript : $(grep -i '^X-Transcript:' /tmp/answer.headers | cut -d' ' -f2- | python3 -c 'import sys,urllib.parse;print(urllib.parse.unquote(sys.stdin.read().strip()))')"
echo "Answer     : $(grep -i '^X-Answer:' /tmp/answer.headers | cut -d' ' -f2- | python3 -c 'import sys,urllib.parse;print(urllib.parse.unquote(sys.stdin.read().strip()))')"
echo "Playing spoken answer..."
aplay -q -D "$SPK_DEV" /tmp/answer.wav

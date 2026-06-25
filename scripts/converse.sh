#!/usr/bin/env bash
# Live, hands-free voice conversation with the assistant.
#
# Loops forever: listens on the mic, auto-detects when you start and stop
# talking (voice-activity detection via sox), sends the clip to the orchestrator
# /ask endpoint, prints the transcript + answer, and plays the spoken reply.
# Just talk, pause, and it responds. Ctrl-C to quit.
#
# Requires sox (rec/play). Devices default to a USB mic + USB headset by card
# name; override MIC_DEV / SPK_DEV if yours differ (arecord -l / aplay -l).
#
# Usage:   scripts/converse.sh
# Tuning:  VAD_SILENCE=1.2  VAD_THRESHOLD=3%  scripts/converse.sh
set -uo pipefail

HOST="${HOST:-http://localhost:8080}"
# Audio devices. On Linux/Jetson, default to USB mic + headset by ALSA card name.
# On macOS, sox uses the default CoreAudio device, so leave them empty.
if [ "$(uname)" = "Darwin" ]; then
  MIC_DEV="${MIC_DEV-}"
  SPK_DEV="${SPK_DEV-}"
else
  MIC_DEV="${MIC_DEV:-plughw:CARD=Microphone,DEV=0}"
  SPK_DEV="${SPK_DEV:-plughw:CARD=A40,DEV=0}"
fi
VAD_SILENCE="${VAD_SILENCE:-1.5}"     # seconds of silence that ends a turn
VAD_THRESHOLD="${VAD_THRESHOLD:-3%}"  # below this = "silence" (raise if noisy room)

# Run sox rec/play, selecting the device only when one is set (empty = default).
_rec()  { if [ -n "$MIC_DEV" ]; then AUDIODEV="$MIC_DEV" rec "$@"; else rec "$@"; fi; }
_play() { if [ -n "$SPK_DEV" ]; then AUDIODEV="$SPK_DEV" play "$@"; else play "$@"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; echo; echo "bye."; exit 0' EXIT INT

# unquote a percent-encoded header value (X-Transcript / X-Answer)
unquote() { python3 -c 'import sys,urllib.parse;print(urllib.parse.unquote(sys.stdin.read().strip()))'; }

# fail fast if the stack isn't reachable
if ! curl -sf "$HOST/healthz" >/dev/null; then
  echo "orchestrator not reachable at $HOST — is the stack up? (docker compose ps)"; exit 1
fi

echo "🎙️  Live voice assistant — just speak. Pause ${VAD_SILENCE}s to send. Ctrl-C to quit."
echo "    mic=$MIC_DEV  spk=$SPK_DEV"

while true; do
  echo; echo "── listening… (speak now)"
  # Record from speech onset, stop after VAD_SILENCE of quiet. The leading
  # "silence 1 0.1 ..." trims the wait-for-speech; trailing ends the turn.
  _rec -q -c 1 -r 16000 -b 16 "$TMP/q.wav" \
      silence 1 0.1 "$VAD_THRESHOLD" 1 "$VAD_SILENCE" "$VAD_THRESHOLD" 2>/dev/null

  # Skip empties (background noise / no speech captured)
  dur=$(soxi -D "$TMP/q.wav" 2>/dev/null || echo 0)
  if awk "BEGIN{exit !($dur < 0.4)}"; then
    echo "   (nothing heard — ignoring)"; continue
  fi

  echo "   thinking…"
  code=$(curl -s -o "$TMP/a.wav" -D "$TMP/h" -w '%{http_code}' \
         --max-time 180 -X POST "$HOST/ask" -F "file=@$TMP/q.wav")
  if [ "$code" != "200" ]; then
    echo "   ⚠️  /ask returned HTTP $code: $(head -c 200 "$TMP/a.wav")"; continue
  fi

  transcript=$(grep -i '^X-Transcript:' "$TMP/h" | cut -d' ' -f2- | unquote)
  answer=$(grep -i '^X-Answer:' "$TMP/h" | cut -d' ' -f2- | unquote)
  echo "🗣️  You: $transcript"
  echo "🤖 Bot: $answer"
  _play -q "$TMP/a.wav" 2>/dev/null
done

#!/usr/bin/env python3
"""Thin HTTP wrapper around faster-whisper (the jetson-containers image ships
the library, not a server). Exposes an OpenAI-ish transcription endpoint."""
import os
import tempfile
import threading

from flask import Flask, request, jsonify
from faster_whisper import WhisperModel

MODEL = os.environ.get("WHISPER_MODEL", "small.en")
DEVICE = os.environ.get("WHISPER_DEVICE", "cuda")
COMPUTE_TYPE = os.environ.get("WHISPER_COMPUTE_TYPE", "int8_float16")
BEAM_SIZE = int(os.environ.get("WHISPER_BEAM_SIZE", "5"))
PORT = int(os.environ.get("PORT", "8001"))

# Load once at startup; CTranslate2 models are not guaranteed thread-safe, so
# serialize inference behind a lock (fine for a single-user voice demo).
model = WhisperModel(MODEL, device=DEVICE, compute_type=COMPUTE_TYPE)
_lock = threading.Lock()

app = Flask(__name__)


@app.get("/healthz")
def healthz():
    return jsonify(status="ok", model=MODEL, device=DEVICE)


@app.post("/v1/audio/transcriptions")
def transcriptions():
    if "file" not in request.files:
        return jsonify(error="missing multipart 'file'"), 400
    upload = request.files["file"]
    suffix = os.path.splitext(upload.filename or "")[1] or ".wav"
    with tempfile.NamedTemporaryFile(suffix=suffix) as tmp:
        upload.save(tmp.name)
        with _lock:
            segments, info = model.transcribe(tmp.name, beam_size=BEAM_SIZE)
            text = " ".join(s.text.strip() for s in segments).strip()
    return jsonify(text=text, language=info.language)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT, threaded=True)

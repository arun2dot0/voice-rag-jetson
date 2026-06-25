#!/usr/bin/env python3
"""Thin HTTP wrapper around piper1-tts (the jetson-containers image ships the
library + flask, but no server). POST {"text": ...} -> audio/wav."""
import io
import os
import threading
import wave
from pathlib import Path

from flask import Flask, request, jsonify, Response
from piper import PiperVoice, SynthesisConfig
from piper.download_voices import download_voice

CACHE = os.environ.get("PIPER_CACHE", "/data/models/piper")
VOICE = os.environ.get("PIPER_VOICE", "en_US-lessac-high")
USE_CUDA = os.environ.get("PIPER_USE_CUDA", "1") == "1"
PORT = int(os.environ.get("PORT", "8002"))

Path(CACHE).mkdir(parents=True, exist_ok=True)
_model_path = Path(CACHE) / f"{VOICE}.onnx"
if not _model_path.exists():
    download_voice(VOICE, Path(CACHE))

voice = PiperVoice.load(str(_model_path), use_cuda=USE_CUDA)
_lock = threading.Lock()

app = Flask(__name__)


def synthesize_wav(text: str) -> bytes:
    syn_config = SynthesisConfig()
    buf = io.BytesIO()
    wav_file: wave.Wave_write = wave.open(buf, "wb")
    params_set = False
    with wav_file:
        for chunk in voice.synthesize(text, syn_config):
            if not params_set:
                wav_file.setframerate(chunk.sample_rate)
                wav_file.setsampwidth(chunk.sample_width)
                wav_file.setnchannels(chunk.sample_channels)
                params_set = True
            wav_file.writeframes(chunk.audio_int16_bytes)
    return buf.getvalue()


@app.get("/healthz")
def healthz():
    return jsonify(status="ok", voice=VOICE, cuda=USE_CUDA)


@app.post("/tts")
def tts():
    data = request.get_json(force=True, silent=True) or {}
    text = (data.get("text") or "").strip()
    if not text:
        return jsonify(error="missing 'text'"), 400
    with _lock:
        audio = synthesize_wav(text)
    return Response(audio, mimetype="audio/wav")


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT, threaded=True)

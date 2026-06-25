# Piper TTS, CPU-only — no jetson-containers base image needed.
#
# The piper-tts PyPI package IS the "piper1" rewrite our server.py targets
# (PiperVoice, SynthesisConfig, piper.download_voices). Its only runtime dep is
# onnxruntime, which ships prebuilt aarch64 (CPU) wheels — so nothing compiles
# here and there's no OOM build. Piper runs comfortably in real time on the
# Orin Nano CPU; set PIPER_USE_CUDA=0 (the compose default).
FROM python:3.11-slim-bookworm

RUN python3 -m pip install --no-cache-dir piper-tts flask

COPY server.py /opt/tts/server.py

ENV PORT=8002 \
    PIPER_CACHE=/data/models/piper \
    PIPER_USE_CUDA=0

EXPOSE 8002
CMD ["python3", "/opt/tts/server.py"]

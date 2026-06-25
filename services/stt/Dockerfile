# Builds on the jetson-containers faster-whisper image (CUDA + ctranslate2).
# Pass the tag autotag picks for your L4T, e.g.:
#   docker build --build-arg BASE_IMAGE=$(autotag faster-whisper) -t voice-rag/stt services/stt
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# The dustynv base pins pip to the Jetson wheel index (pypi.jetson-ai-lab.dev),
# which doesn't carry flask and currently doesn't even resolve. flask is pure
# Python, so pull it from the real PyPI instead.
RUN python3 -m pip install --no-cache-dir --index-url https://pypi.org/simple flask

COPY server.py /opt/stt/server.py

ENV PORT=8001 \
    HF_HOME=/data/models/huggingface

EXPOSE 8001
CMD ["python3", "/opt/stt/server.py"]

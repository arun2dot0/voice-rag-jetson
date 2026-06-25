# voice-rag-jetson

A **fully-local voice assistant over your blog corpus**, built for the Jetson
Orin Nano. Ask a question out loud → get a spoken answer grounded in your
indexed blog posts. Nothing leaves the device.

```
🎙️  mic
     │  audio
     ▼
┌──────────────┐   text    ┌──────────────────────────┐
│ stt          │──────────▶│ orchestrator             │
│ faster-whisper│           │  1. transcribe (stt)     │
└──────────────┘           │  2. /search (rag-rss)    │──┐ HTTP /search
                           │  3. generate (ollama)    │  │
┌──────────────┐   wav     │  4. speak (tts)          │  ▼
│ tts          │◀──────────│                          │ ┌──────────────┐
│ piper1-tts   │           └──────────────────────────┘ │ rag-rss-search│
└──────┬───────┘                     │                   │  + pgvector   │
       │ audio                       │ /v1 (OpenAI API)  └──────┬───────┘
       ▼                             ▼                          │ embeddings
   🔊 speaker                 ┌──────────────┐                  │
                              │ ollama       │◀─────────────────┘
                              │ chat + embed │
                              └──────────────┘
```

This repo owns **only the voice + LLM layer**. Retrieval is a separate, external
service: your [`rag-rss-search`](https://github.com/arun2dot0/rag-rss-search) app
running at `RAG_URL`. That project owns its own database, storage mode
(`pg` vs in-memory), embedding backend, and ingestion — this project doesn't
touch any of it. The only coupling is the HTTP `/search` contract.

## Why these choices

| Component | Image | Device | Role | Owned here? |
|---|---|---|---|---|
| `stt` | prebuilt `dustynv/faster-whisper` + thin Flask wrapper | **GPU** | speech → text | ✅ |
| `tts` | `python:3.11-slim` + `pip install piper-tts` | **CPU** | text → speech | ✅ |
| `ollama` | `dustynv/ollama` | GPU | chat model (answer generation), OpenAI-compatible API | ✅ |
| `orchestrator` | plain `python:3.12-slim` | CPU | glues the pipeline together | ✅ |
| RAG search | your `rag-rss-search` (`:9000`) | — | retrieval over its own DB | ❌ external |

`faster-whisper` ships as a **library** in the prebuilt jetson-containers image,
so `services/stt` adds the minimal Flask server. **`tts` needs no jetson image**:
the PyPI `piper-tts` package *is* the "piper1" rewrite, depends only on
`onnxruntime` (prebuilt aarch64 CPU wheels), and runs fine on CPU — so it builds
`FROM python:3.11-slim`. STT must run on the **GPU**: this CTranslate2 build is
CUDA-only (no CPU GEMM backend). See [`FINDINGS.md`](FINDINGS.md) for the full
bring-up story (every error and fix).

## Prerequisites

**Do NOT run `jetson-containers build`** — compiling CTranslate2 / onnxruntime
on-device OOM-crashes the Orin Nano (see [`FINDINGS.md`](FINDINGS.md) §1). This
stack avoids it entirely:

- **STT** pulls the prebuilt `STT_BASE_IMAGE` (`dustynv/faster-whisper:...`) —
  Docker pulls it, nothing compiles. Match the tag to your L4T (the
  `.env.example` default is `r36.4.0-cu128-24.04` for JetPack 6.x).
- **TTS** needs no base image — it `pip install piper-tts`s from PyPI at build.

So the only prep is copying `.env` and confirming the prebuilt tag exists:

```bash
docker manifest inspect "$(grep STT_BASE_IMAGE .env.example | cut -d= -f2)" >/dev/null \
  && echo "STT base image available"
```

> If Docker requires root on your device, prefix every `docker`/`docker compose`
> command below with `sudo`, or run `sudo usermod -aG docker $USER` once and
> **re-login** (a fresh shell — group changes don't apply to existing sessions)
> so the scripts work without sudo.

## The RAG backend (external dependency)

This project does **not** run the RAG search service or its database. Bring up
`rag-rss-search` from its own project — it owns its DB, storage mode, embedder,
and ingestion — and make sure it's reachable at `RAG_URL` (default
`http://host.docker.internal:9000`, i.e. published on the host). Confirm it
answers before starting the voice layer:

```bash
curl -s "http://localhost:9000/search?query=test" | python3 -m json.tool
# expect: [{"text": ..., "url": ...}, ...]
```

> One cross-project constraint: whatever embedder `rag-rss-search` used to ingest
> must produce the **same vector dimension** it queries with. If it embeds via
> this project's `ollama` (`nomic-embed-text`, 768-dim), ingest with that too —
> data embedded via OpenAI (1536-dim) won't match. That's configured in
> `rag-rss-search`, not here.

## Run the demo

```bash
cp .env.example .env        # set STT_BASE_IMAGE for your L4T, and RAG_URL if
                            # rag-rss-search isn't on the host

# 1. start ollama and pull the chat + embedding models
docker compose up -d ollama
./scripts/bootstrap-models.sh

# 2. build + start the voice layer (stt, tts, orchestrator)
docker compose up -d --build

# 3. warm up — free page cache + load both models while memory is free.
#    REQUIRED on the 8GB Orin Nano (and after every reboot); see Model sizing.
./scripts/warmup.sh

# 4. ask — text first, then voice  (rag-rss-search must already be running)
curl -s -X POST localhost:8080/ask-text \
  -H 'content-type: application/json' \
  -d '{"query":"What does the security blog say about phishing?"}' | python3 -m json.tool

./scripts/demo.sh "what is this blog about"   # records mic, plays spoken answer
```

> The voice demo records from `MIC_DEV` and plays to `SPK_DEV` (defaults target a
> USB mic + USB headset by card name). List devices with `arecord -l` / `aplay -l`
> and override if yours differ:
> `MIC_DEV=plughw:CARD=Yourmic,DEV=0 SPK_DEV=plughw:CARD=Yourspk,DEV=0 ./scripts/demo.sh`

### Live, hands-free conversation

`demo.sh` does one fixed-length recording. For a continuous back-and-forth, use
the conversation loop — it listens, auto-detects when you start/stop speaking
(voice-activity detection), answers out loud, and repeats. Just talk; Ctrl-C to
quit. Requires `sox`.

```bash
./scripts/converse.sh
# tune for a noisy room or longer pauses:
VAD_THRESHOLD=5% VAD_SILENCE=2.0 ./scripts/converse.sh
```

Per-turn latency is roughly STT + LLM + TTS (a few seconds on the Orin Nano);
keep both models warm (`scripts/warmup.sh`) so no turn pays a cold-load.

## Endpoints (orchestrator, :8080)

- `POST /ask-text`  `{"query": "..."}` → `{transcript?, answer, citations[]}` (easiest to test)
- `POST /ask`  multipart `file=@question.wav` → `audio/wav` (spoken answer; transcript+answer in `X-Transcript`/`X-Answer` headers). Add `?format=json` to get JSON instead of audio.
- `GET  /healthz`

## Model sizing (Orin Nano 8GB)

The 8GB is **unified** (CPU + GPU share one pool), so the whole stack plus the
desktop has to fit in it. Validated defaults:

| Setting (`.env` / compose) | Value | Why |
|---|---|---|
| `CHAT_MODEL` | `qwen2.5:1.5b` | `3b` won't cold-load alongside whisper + desktop (CUDA OOM) |
| `WHISPER_MODEL` | `base.en` | `small.en` OOMs on inference scratch; `base.en` is smaller |
| `WHISPER_DEVICE` / type | `cuda` / `int8_float16` | CTranslate2 build is **CUDA-only** (no CPU backend) |
| `PIPER_VOICE` / `PIPER_USE_CUDA` | `en_US-lessac-high` / `0` | piper runs on **CPU**; real-time on the Orin |
| `OLLAMA_KEEP_ALIVE` | `-1` | pin the LLM resident so the cold-load happens once |

**The cache trap (read this):** `cudaMalloc` allocates from *genuinely free* RAM
and will **not** reclaim page cache — so `free -h` showing GB "available" is
misleading, and model loads can OOM with `unable to allocate CUDA0 buffer` /
`CUDA failed with error out of memory` even when "available" looks fine. That's
why **`scripts/warmup.sh` is required** after `docker compose up` and after every
reboot: it drops the cache, then loads both models while memory is actually free
(they then stay resident). Keeping Chrome / heavy GUI apps closed gives more
permanent headroom. Full details in [`FINDINGS.md`](FINDINGS.md).

Want better answers? You can bump `CHAT_MODEL` to `qwen2.5:3b` (or larger) **only
if** you free memory first — run headless (stop the desktop) or close GUI apps,
then re-run `warmup.sh`.

> This project is **docker-compose only** — no Kubernetes dependency. If you
> want to run it on k3s (and operate it by voice), the k3s manifests for this
> stack live in the sibling [`voice-kubectl-jetson`](../voice-kubectl-jetson)
> project under `deploy/k3s/workloads/`.

## The one required patch to rag-rss-search

`PgVectorStore.__init__` now reads `DATABASE_URL`, `EMBEDDING_MODEL`, and
`EMBEDDING_DIM` from env (defaults unchanged, so OpenAI mode still works). The
OpenAI SDK already reads `OPENAI_BASE_URL`/`OPENAI_API_KEY` from env, so pointing
it at ollama needs no further code change. Local embedders aren't 1536-dim, which
is why `EMBEDDING_DIM` had to become configurable (it's baked into the table DDL).

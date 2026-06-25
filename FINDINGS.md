# Findings — bringing the voice stack up on Jetson Orin Nano (8GB)

Hardware: **Jetson Orin Nano Engineering Reference Dev Kit (Super)**, JetPack 6.2
/ L4T **R36.4.7**, **8GB unified memory** (CPU + GPU share one physical pool),
16GB swap. Docker 29.x.

The single fact that drove almost every decision below: **memory is unified.**
"Free up the GPU" and "free up the CPU" are the same thing, and `cudaMalloc`
draws from *genuinely free* RAM — it will **not** reclaim page cache. So the
constraint is not total RAM, it's how much is free in one piece at the moment a
model loads.

---

## 1. `jetson-containers build` OOM-crashes

**Symptom:** `jetson-containers build faster-whisper` / `piper1-tts` crash the
device even with raised RAM/swap limits.

**Cause:** those commands *compile from source* on-device — CTranslate2 (CUDA)
for faster-whisper, onnxruntime-gpu for piper. A single `nvcc`/`g++` job exceeds
the memory budget; more swap doesn't help.

**Fix:** don't build. Use prebuilt artifacts.
- **STT:** prebuilt `dustynv/faster-whisper:r36.4.0-cu128-24.04` (CUDA, pulled
  not compiled). Confirmed on Docker Hub.
- **TTS:** there is **no** prebuilt `piper1-tts` image — but it doesn't need one.
  The PyPI package `piper-tts` (v1.4.x) *is* the "piper1" rewrite the server
  uses (`PiperVoice`, `SynthesisConfig`, `piper.download_voices`), and its only
  runtime dep is `onnxruntime` (prebuilt aarch64 CPU wheels). So TTS now builds
  `FROM python:3.11-slim` + `pip install piper-tts flask` and runs on CPU.

---

## 2. STT build fails: pip can't find `flask`

**Symptom:**
```
Looking in indexes: https://pypi.jetson-ai-lab.dev/jp6/cu128
... Name or service not known
ERROR: No matching distribution found for flask
```

**Cause:** the dustynv image pins pip to the Jetson wheel index
(`pypi.jetson-ai-lab.dev`), which is the *only* configured index. That host no
longer resolves, and it wouldn't carry `flask` anyway.

**Fix:** install pure-Python `flask` from real PyPI explicitly:
```dockerfile
RUN python3 -m pip install --no-cache-dir --index-url https://pypi.org/simple flask
```

---

## 3. RAG unreachable from the orchestrator container

**Symptom:** orchestrator `/ask-text` → `httpx.ConnectError: All connection
attempts failed` (later `Connection refused`).

**Cause:** the external `rag-rss-search` (uvicorn) was bound to **127.0.0.1**.
The orchestrator runs in a container and reaches the host via
`host.docker.internal` (the docker bridge gateway, ~172.x); a loopback-only
listener refuses that.

**Fix:** start RAG on all interfaces:
```bash
uvicorn app:app --reload --host 0.0.0.0 --port 9000
```
(Also: RAG's `/search` was 500ing separately because `OPENAI_API_KEY` wasn't
exported in its shell — unrelated to this stack, fixed on the RAG side.)

---

## 4. LLM load fails: `unable to allocate CUDA0 buffer`

**Symptom:** ollama → `llama runner process has terminated: error loading model:
unable to allocate CUDA0 buffer`.

**Causes (compounding):**
- `qwen2.5:3b` (~2.5GB) + whisper on GPU + desktop (GNOME + Xorg + Chrome ~1.5GB)
  exceeds 8GB.
- Even after shrinking, only ~300–700MB was *genuinely free* — the rest was
  page cache `cudaMalloc` won't reclaim.
- Failed load attempts **leaked** memory: ollama idle RSS sat at 2.1GB until
  restarted (dropped to 55MB).

**Fixes:**
- Chat model **`qwen2.5:3b` → `qwen2.5:1.5b`** (~1.1GB; fits with desktop up).
- `OLLAMA_KEEP_ALIVE=-1` + `OLLAMA_MAX_LOADED_MODELS=1` — once loaded the model
  stays resident, so the expensive cold-load happens once.
- Free page cache right before loading (see §7), then warm up.

---

## 5. STT can't run on CPU at all

We first tried moving whisper to CPU to leave the GPU for the LLM. Two dead ends:
- `WHISPER_COMPUTE_TYPE=int8` → `ValueError: Requested int8 compute type, but
  the target device or backend do not support efficient int8 computation.`
  (this CTranslate2 build has no aarch64-CPU int8 kernels).
- `WHISPER_COMPUTE_TYPE=float32` → loads, then at inference:
  `RuntimeError: No SGEMM backend on CPU`.

**Conclusion:** the dustynv CTranslate2 is **CUDA-only** — no CPU GEMM backend.
Whisper **must** run on the GPU here. (And because memory is unified, moving it
to CPU wouldn't have saved memory anyway — fp32 used *more*.)

---

## 6. Whisper inference OOM (even after loading)

**Symptom:** `/healthz` ok (weights loaded), but transcription →
`RuntimeError: CUDA failed with error out of memory` during `encode`.

**Cause:** whisper allocates **inference scratch** on first transcription. With
the LLM resident and only ~300MB free, that allocation OOMs.

**Fixes:**
- Whisper model **`small.en` → `base.en`** — smaller weights *and* scratch.
- **Warm up once** after freeing cache: CTranslate2 keeps its GPU scratch pool
  allocated between calls, so the first successful transcription makes STT
  memory-resident (like the LLM). On-demand requests then reuse it.

Note: `base.en` is slightly less accurate (e.g. transcribes "backpropagation"
as "back propagation") but the LLM/RAG handle it fine.

---

## 7. The unified-memory cache trap (root cause behind §4 and §6)

`free -h` showing several GB "available" is misleading: `cudaMalloc` needs
**free** pages and won't reclaim page cache. `tegrastats` made it visible:
`RAM 3625/7620MB (lfb 28x4MB)` — only 4MB largest-free-block.

**Recovery (needs root):**
```bash
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
```
…then immediately warm both models so they grab and hold their allocations.
This is what `scripts/warmup.sh` automates. **Required after each reboot**
(cache refills over time), or just keep heavy desktop apps (Chrome) closed.

---

## Final working configuration

| Service | Image / base | Device | Notes |
|---|---|---|---|
| `ollama` | `dustynv/ollama:r36.4.0` | GPU | `qwen2.5:1.5b`, `KEEP_ALIVE=-1` |
| `stt` | `dustynv/faster-whisper:r36.4.0-cu128-24.04` | **GPU** | `base.en`, `int8_float16` (CUDA-only build) |
| `tts` | `python:3.11-slim` + `pip install piper-tts` | **CPU** | `en_US-lessac-high`, onnxruntime CPU |
| `orchestrator` | `python:3.12-slim` | CPU | glue only |
| RAG | external `rag-rss-search` `:9000` | — | must bind `0.0.0.0` |

**Memory budget (steady state, both models resident):** LLM ~2.0GB + whisper
~0.9GB + TTS/orchestrator/RAG ~0.6GB + desktop ~1.5GB ≈ 5GB of 8GB. It fits —
but only if the cold-loads happen against *free* memory (§7).

Validated end-to-end: spoken question → STT → RAG (5 citations) → LLM grounded
answer → TTS WAV out.

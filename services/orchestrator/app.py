#!/usr/bin/env python3
"""Voice RAG orchestrator.

Pipeline:  audio --(STT)--> text --(/search on rag-rss-search)--> chunks
           --(LLM generation via ollama)--> answer --(TTS)--> audio

This is the only bespoke component; STT/TTS/LLM/retrieval are existing services.
"""
import asyncio
import os
from urllib.parse import quote

import httpx
from fastapi import FastAPI, File, Query, UploadFile
from fastapi.responses import Response
from openai import OpenAI
from pydantic import BaseModel

STT_URL = os.environ.get("STT_URL", "http://stt:8001")
TTS_URL = os.environ.get("TTS_URL", "http://tts:8002")
RAG_URL = os.environ.get("RAG_URL", "http://rag:9000")
LLM_BASE_URL = os.environ.get("LLM_BASE_URL", "http://ollama:11434/v1")
LLM_API_KEY = os.environ.get("LLM_API_KEY", "ollama")  # ignored by ollama
CHAT_MODEL = os.environ.get("CHAT_MODEL", "qwen2.5:3b")
MAX_CONTEXT_CHARS = int(os.environ.get("MAX_CONTEXT_CHARS", "6000"))
HTTP_TIMEOUT = float(os.environ.get("HTTP_TIMEOUT", "120"))

SYSTEM_PROMPT = (
    "You are a helpful voice assistant answering questions about a collection "
    "of blog posts. Use ONLY the provided context to answer. If the context "
    "does not contain the answer, say you don't know. Keep answers concise and "
    "conversational since they will be read aloud. Do not read out URLs."
)

llm = OpenAI(base_url=LLM_BASE_URL, api_key=LLM_API_KEY)
app = FastAPI(title="Voice RAG Orchestrator")


async def transcribe(content: bytes, filename: str, client: httpx.AsyncClient) -> str:
    files = {"file": (filename or "audio.wav", content, "application/octet-stream")}
    r = await client.post(f"{STT_URL}/v1/audio/transcriptions", files=files)
    r.raise_for_status()
    return r.json().get("text", "").strip()


async def retrieve(query: str, client: httpx.AsyncClient) -> list[dict]:
    r = await client.get(f"{RAG_URL}/search", params={"query": query})
    r.raise_for_status()
    results = r.json()
    # /search echoes {"response": ...} for empty queries; keep only real hits.
    return [c for c in results if "text" in c]


def generate(query: str, contexts: list[dict]) -> str:
    if not contexts:
        return "I couldn't find anything about that in the blog posts."
    blocks = []
    for i, c in enumerate(contexts, 1):
        blocks.append(f"[{i}] {c.get('text', '')}\nSource: {c.get('url', '')}")
    context = "\n\n".join(blocks)[:MAX_CONTEXT_CHARS]
    resp = llm.chat.completions.create(
        model=CHAT_MODEL,
        temperature=0.2,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {
                "role": "user",
                "content": f"Context:\n{context}\n\nQuestion: {query}\n\nAnswer:",
            },
        ],
    )
    return resp.choices[0].message.content.strip()


async def speak(text: str, client: httpx.AsyncClient) -> bytes:
    r = await client.post(f"{TTS_URL}/tts", json={"text": text})
    r.raise_for_status()
    return r.content


@app.get("/healthz")
async def healthz():
    return {"status": "ok", "chat_model": CHAT_MODEL}


class AskText(BaseModel):
    query: str


@app.post("/ask-text")
async def ask_text(body: AskText):
    """Text in, JSON out. Easiest path for curl / debugging."""
    async with httpx.AsyncClient(timeout=HTTP_TIMEOUT) as client:
        contexts = await retrieve(body.query, client)
    answer = await asyncio.to_thread(generate, body.query, contexts)
    return {
        "query": body.query,
        "answer": answer,
        "citations": [c.get("url", "") for c in contexts],
    }


@app.post("/ask")
async def ask(
    file: UploadFile = File(...),
    format: str = Query("audio", description="'audio' (wav) or 'json'"),
):
    """Audio in. Returns spoken answer (wav) or JSON with transcript+answer."""
    content = await file.read()
    async with httpx.AsyncClient(timeout=HTTP_TIMEOUT) as client:
        transcript = await transcribe(content, file.filename, client)
        contexts = await retrieve(transcript, client)
        answer = await asyncio.to_thread(generate, transcript, contexts)
        if format == "json":
            return {
                "transcript": transcript,
                "answer": answer,
                "citations": [c.get("url", "") for c in contexts],
            }
        audio = await speak(answer, client)
    return Response(
        content=audio,
        media_type="audio/wav",
        headers={
            "X-Transcript": quote(transcript),
            "X-Answer": quote(answer),
        },
    )

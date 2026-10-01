from __future__ import annotations

import asyncio
import hmac
import time
import uuid
from typing import Protocol

import numpy as np
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse


MAX_AUDIO_BYTES = 5 * 16000 * 4
QUALITY_WARNING = "Experimental translation. Models can misunderstand Tashelhit; confirm the meaning with the speaker."


class TranslationEngine(Protocol):
    model_description: str

    def translate(self, samples: np.ndarray) -> str: ...


def create_app(token: str, engine: TranslationEngine | None, *, inference_deadline: float = 15, upload_deadline: float = 5) -> FastAPI:
    if len(token) < 24 or any(character.isspace() for character in token):
        raise ValueError("Use a randomly generated bearer token of at least 24 characters.")
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    # A cancelled HTTP request must not free the slot while its worker still runs.
    active_job: asyncio.Task | None = None
    busy = False
    faulted = False

    def authorize(request: Request) -> None:
        supplied = request.headers.get("authorization", "")
        if not hmac.compare_digest(supplied.encode(), f"Bearer {token}".encode()):
            raise HTTPException(401, "Server token missing or invalid.", headers={"WWW-Authenticate": "Bearer"})

    def require_engine() -> TranslationEngine:
        if faulted:
            raise HTTPException(503, "Inference timed out. Restart the bridge before retrying.")
        if engine is None:
            raise HTTPException(503, "Translation models are not loaded.")
        return engine

    @app.middleware("http")
    async def no_store(request, call_next):
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        return response

    @app.exception_handler(HTTPException)
    async def controlled_error(request, error):
        return JSONResponse(status_code=error.status_code, content={"message": str(error.detail)}, headers=error.headers)

    @app.get("/capabilities")
    async def capabilities(request: Request):
        authorize(request)
        loaded = require_engine()
        return {
            "model": loaded.model_description,
            "source_languages": ["shi"], "target_languages": ["en"],
            "tasks": ["translate"], "audio_formats": ["f32le"],
            "sample_rates": [16000], "channels": [1],
            "quality_status": "experimental", "quality_warning": QUALITY_WARNING,
        }

    @app.post("/inference")
    async def inference(request: Request):
        nonlocal active_job, busy, faulted
        authorize(request)
        loaded = require_engine()
        expected = {
            "x-language": "shi", "x-source-language": "shi", "x-target-language": "en",
            "x-task": "translate", "x-sample-rate": "16000", "x-channels": "1",
            "x-audio-format": "f32le",
        }
        for header, value in expected.items():
            if request.headers.get(header) != value:
                raise HTTPException(422, f"Expected {header}: {value}.")
        if request.headers.get("content-type", "").split(";")[0].strip().lower() != "application/octet-stream":
            raise HTTPException(400, "Expected raw PCM with application/octet-stream content type.")
        chunk_id = request.headers.get("x-chunk-id", "")
        try:
            uuid.UUID(chunk_id)
        except ValueError:
            raise HTTPException(400, "X-Chunk-ID must be a UUID.") from None
        if busy:
            raise HTTPException(429, "The mini is translating another phrase. Retry shortly.", headers={"Retry-After": "1"})
        busy = True
        launched = False

        def release_slot(job):
            nonlocal busy
            busy = False
            if not job.cancelled():
                job.exception()  # Retrieve cancelled-request errors without recording content.

        try:
            declared = request.headers.get("content-length")
            if declared is not None:
                try:
                    size = int(declared)
                except ValueError:
                    raise HTTPException(400, "Invalid Content-Length.") from None
                if size < 0:
                    raise HTTPException(400, "Invalid Content-Length.")
                if size > MAX_AUDIO_BYTES:
                    raise HTTPException(413, "Audio exceeds the five-second phrase limit.")
            body = bytearray()
            try:
                async with asyncio.timeout(upload_deadline):
                    async for part in request.stream():
                        if len(body) + len(part) > MAX_AUDIO_BYTES:
                            raise HTTPException(413, "Audio exceeds the five-second phrase limit.")
                        body.extend(part)
            except asyncio.TimeoutError:
                raise HTTPException(408, "Audio upload timed out. Retry with a stable connection.") from None
            if len(body) < 160 * 4 or len(body) % 4:
                raise HTTPException(400, "Audio must contain at least 10 ms of complete Float32 samples.")
            samples = np.frombuffer(body, dtype="<f4").copy()
            if not np.isfinite(samples).all() or np.any(np.abs(samples) > 1):
                raise HTTPException(400, "PCM samples must be finite and normalized between -1 and 1.")
            started = time.perf_counter()
            text = ""
            if np.max(np.abs(samples)) > 0.00001:
                active_job = asyncio.create_task(asyncio.to_thread(loaded.translate, samples))
                active_job.add_done_callback(release_slot)
                launched = True
                try:
                    text = await asyncio.wait_for(asyncio.shield(active_job), timeout=inference_deadline)
                except asyncio.TimeoutError:
                    faulted = True
                    raise HTTPException(503, "Inference timed out. Restart the bridge before retrying.") from None
                except asyncio.CancelledError:
                    raise
                except Exception:
                    raise HTTPException(503, "Model inference failed. Retry the phrase or restart the bridge.") from None
            return {
                "text": text.strip(), "source_language": "shi", "target_language": "en",
                "task": "translate", "chunk_id": chunk_id,
                "inference_ms": (time.perf_counter() - started) * 1000,
            }
        finally:
            if not launched:
                busy = False

    return app

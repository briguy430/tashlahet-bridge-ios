import asyncio
import uuid

import httpx
import numpy as np
import pytest
from fastapi.testclient import TestClient

from tashbridge.app import create_app


TOKEN = "test-private-token-for-protocol-only"


class StubEngine:
    model_description = "controlled test double, no language-quality evidence"

    def __init__(self):
        self.calls = 0

    def translate(self, samples):
        self.calls += 1
        return "Controlled English result"


def headers(**changes):
    values = {
        "Authorization": f"Bearer {TOKEN}",
        "Content-Type": "application/octet-stream",
        "X-Language": "shi",
        "X-Source-Language": "shi",
        "X-Target-Language": "en",
        "X-Task": "translate",
        "X-Sample-Rate": "16000",
        "X-Channels": "1",
        "X-Audio-Format": "f32le",
        "X-Chunk-ID": str(uuid.uuid4()),
    }
    values.update(changes)
    return values


def pcm(seconds=0.2):
    return np.full(int(seconds * 16000), 0.1, dtype="<f4").tobytes()


def test_auth_is_required_before_reading_or_inference():
    engine = StubEngine()
    with TestClient(create_app(TOKEN, engine)) as client:
        assert client.get("/capabilities").status_code == 401
        assert client.post("/inference", content=pcm()).status_code == 401
        assert engine.calls == 0


def test_capabilities_identify_the_loaded_engine():
    engine = StubEngine()
    with TestClient(create_app(TOKEN, engine)) as client:
        response = client.get("/capabilities", headers=headers())
        assert response.status_code == 200
        assert response.json()["model"] == engine.model_description
        assert response.json()["source_languages"] == ["shi"]
        assert response.json()["quality_status"] == "experimental"
        assert response.headers["cache-control"] == "no-store"


def test_unloaded_engine_does_not_advertise_support():
    with TestClient(create_app(TOKEN, None)) as client:
        assert client.get("/capabilities", headers=headers()).status_code == 503
        assert client.post("/inference", headers=headers(), content=pcm()).status_code == 503


def test_result_echoes_exact_chunk_id_and_language_pair():
    engine = StubEngine()
    request_headers = headers()
    with TestClient(create_app(TOKEN, engine)) as client:
        response = client.post("/inference", headers=request_headers, content=pcm())
        assert response.status_code == 200
        result = response.json()
        assert result["chunk_id"] == request_headers["X-Chunk-ID"]
        assert result["source_language"] == "shi"
        assert result["target_language"] == "en"
        assert result["task"] == "translate"
        assert result["text"] == "Controlled English result"
        assert result["inference_ms"] >= 0
        assert engine.calls == 1


@pytest.mark.parametrize("body", [b"", b"abc", np.array([np.nan] * 3200, dtype="<f4").tobytes(), np.array([np.inf] * 3200, dtype="<f4").tobytes(), np.array([2.0] * 3200, dtype="<f4").tobytes()])
def test_bad_pcm_never_reaches_model(body):
    engine = StubEngine()
    with TestClient(create_app(TOKEN, engine)) as client:
        assert client.post("/inference", headers=headers(), content=body).status_code == 400
        assert engine.calls == 0


def test_five_second_limit_is_enforced():
    engine = StubEngine()
    with TestClient(create_app(TOKEN, engine)) as client:
        assert client.post("/inference", headers=headers(), content=pcm(5.01)).status_code == 413
        assert engine.calls == 0


@pytest.mark.parametrize("changes", [{"X-Task": "transcribe"}, {"X-Source-Language": "ar"}, {"X-Audio-Format": "wav"}, {"X-Sample-Rate": "48000"}, {"X-Channels": "2"}, {"X-Chunk-ID": "not-a-uuid"}])
def test_wrong_contract_is_rejected(changes):
    engine = StubEngine()
    with TestClient(create_app(TOKEN, engine)) as client:
        assert client.post("/inference", headers=headers(**changes), content=pcm()).status_code in (400, 422)
        assert engine.calls == 0


def test_silence_returns_empty_without_model_hallucination():
    engine = StubEngine()
    with TestClient(create_app(TOKEN, engine)) as client:
        response = client.post("/inference", headers=headers(), content=np.zeros(3200, dtype="<f4").tobytes())
        assert response.json()["text"] == ""
        assert engine.calls == 0


def test_only_one_model_job_can_run_and_cancel_does_not_release_it_early():
    import threading

    started, release = threading.Event(), threading.Event()

    class SlowEngine(StubEngine):
        def translate(self, samples):
            started.set()
            release.wait(3)
            return super().translate(samples)

    async def run():
        engine = SlowEngine()
        app = create_app(TOKEN, engine)
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
            first = asyncio.create_task(client.post("/inference", headers=headers(), content=pcm()))
            assert await asyncio.to_thread(started.wait, 2)
            first.cancel()
            with pytest.raises(asyncio.CancelledError):
                await first
            second = await client.post("/inference", headers=headers(), content=pcm())
            assert second.status_code == 429
            release.set()
            await asyncio.sleep(0.05)
            third = await client.post("/inference", headers=headers(), content=pcm())
            assert third.status_code == 200

    asyncio.run(run())


def test_slow_upload_reserves_the_only_audio_slot():
    async def run():
        began, release = asyncio.Event(), asyncio.Event()

        async def upload():
            began.set()
            yield pcm(0.1)
            await release.wait()
            yield pcm(0.1)

        engine = StubEngine()
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=create_app(TOKEN, engine)), base_url="http://test") as client:
            first = asyncio.create_task(client.post("/inference", headers=headers(), content=upload()))
            await began.wait()
            second = await client.post("/inference", headers=headers(), content=pcm())
            assert second.status_code == 429
            release.set()
            assert (await first).status_code == 200

    asyncio.run(run())


def test_timeout_quarantines_engine_until_restart():
    import threading

    release = threading.Event()

    class SlowEngine(StubEngine):
        def translate(self, samples):
            release.wait(2)
            return "Late result"

    with TestClient(create_app(TOKEN, SlowEngine(), inference_deadline=0.02)) as client:
        try:
            response = client.post("/inference", headers=headers(), content=pcm())
            assert response.status_code == 503
            assert "restart" in response.json()["message"].lower()
            assert client.get("/capabilities", headers=headers()).status_code == 503
        finally:
            release.set()


def test_stalled_upload_times_out_and_releases_slot():
    async def run():
        async def upload():
            yield pcm(0.1)
            await asyncio.Event().wait()

        engine = StubEngine()
        app = create_app(TOKEN, engine, upload_deadline=0.02)
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
            first = await client.post("/inference", headers=headers(), content=upload())
            assert first.status_code == 408
            assert engine.calls == 0
            assert (await client.post("/inference", headers=headers(), content=pcm())).status_code == 200

    asyncio.run(run())

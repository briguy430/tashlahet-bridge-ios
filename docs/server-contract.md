# Tashelhit translation server contract

This is the app's custom protocol. It is not the stock whisper.cpp server API. No trained model or backend is included in this repository.

## Capability check

Before microphone capture, the client sends `GET /capabilities` next to the configured `/inference` path. For `https://host/api/inference`, it checks `https://host/api/capabilities`.

A compatible backend returns HTTP 200 and JSON:

```json
{
  "model": "the actual loaded Tashelhit translation model and revision",
  "source_languages": ["shi"],
  "tasks": ["translate"],
  "target_languages": ["en"],
  "audio_formats": ["f32le"],
  "sample_rates": [16000],
  "channels": [1]
}
```

These fields are a server declaration. Advertising support does not prove accuracy. A real backend should only advertise a language/task when its loaded model and runtime support it, and should be evaluated with native speakers before use as a conversation aid. Do not advertise `shi` for stock Whisper or return a fabricated translation.

## Audio request

`POST /inference` with a body of raw little-endian 32-bit floating point audio samples, 16,000 samples/second, one channel. There is no WAV header or multipart form. The client sends at most five seconds per automatically segmented phrase.

| Header | Value |
| --- | --- |
| `Content-Type` | `application/octet-stream` |
| `Accept` | `application/json` |
| `X-Language` | `shi` |
| `X-Source-Language` | `shi` |
| `X-Target-Language` | `en` |
| `X-Task` | `translate` |
| `X-Sample-Rate` | `16000` |
| `X-Channels` | `1` |
| `X-Audio-Format` | `f32le` |
| `X-Chunk-ID` | UUID for this phrase |

The server validates the body length, finite sample values, declared format, and loaded model. Translation must return English text, not a Tashelhit transcription relabeled as English.

## Translation response

Return HTTP 200 with JSON, echoing the exact request chunk ID:

```json
{
  "text": "English translation produced by the model",
  "source_language": "shi",
  "target_language": "en",
  "task": "translate",
  "chunk_id": "the request's X-Chunk-ID",
  "inference_ms": 250
}
```

`task` and nonnegative `inference_ms` are optional; all other fields are required. Empty `text` is permitted for a chunk the backend identifies as non-speech. The UI reports elapsed client request time; it does not measure phrase-end-to-result latency.

For failures, use a non-2xx status and JSON `{"message":"specific reason"}` or `{"error":"specific reason"}`. Examples: 400 invalid audio/parameters, 422 unsupported language/task, 503 model unavailable. The app does not follow redirects or automatically retry audio. The user can retry failed phrases explicitly.

## Deployment limits

The iPhone app has no authentication-token UI. Use a trusted LAN backend or implement authentication before deploying a remotely reachable backend. TLS certificates must be trusted by iOS. No credentials or microphone audio should be sent in redirect hops.

The capability endpoint is a protocol check, not a language validation or safety guarantee. Real speech samples, reference translations, native-speaker review, measured latency, and known failure cases are the remaining acceptance requirements for a working conversation bridge.

# Tashelhit translation server contract

This is the app's custom protocol. It is not the stock whisper.cpp server API. The repository includes an experimental Mac backend; weights download separately. Its current English stage failed everyday translation evaluation. See [backend setup](backend-setup.md) and [model evidence](model-backend-options.md).

## Capability check

Before microphone capture, the client sends `GET /capabilities` next to the configured `/inference` path. For `https://host/api/inference`, it checks `https://host/api/capabilities`.

When configured, the client sends `Authorization: Bearer <token>` on both requests. Tokens require HTTPS and are stored in the iPhone Keychain. The included backend always requires a token, including on loopback; it returns 401 for missing or invalid credentials.

A compatible backend returns HTTP 200 and JSON:

```json
{
  "model": "the actual loaded Tashelhit translation model and revision",
  "source_languages": ["shi"],
  "tasks": ["translate"],
  "target_languages": ["en"],
  "audio_formats": ["f32le"],
  "sample_rates": [16000],
  "channels": [1],
  "quality_status": "experimental",
  "quality_warning": "Experimental translation. Models can misunderstand Tashelhit; confirm the meaning with the speaker."
}
```

These fields are a server declaration. Advertising support does not prove accuracy. A real backend should only advertise a language/task when its loaded model and runtime support it, and should be evaluated with native speakers before use as a conversation aid. Do not advertise `shi` for stock Whisper or return a fabricated translation.

The optional quality fields display a visible warning in setup and conversation. Omitting them preserves compatibility with existing servers; it does not establish validation. Unloaded or quarantined models return 503 rather than advertise support.

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

The included server accepts 10 ms through five seconds of normalized finite samples in [-1, 1], reserves one upload/inference slot, and rejects extra simultaneous phrases with 429. Uploads have a five-second deadline and a 320,000-byte limit. Model inference has a 15-second deadline; a timeout quarantines the model until process restart. Translation must return English text, not a Tashelhit transcription relabeled as English.

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

Use the iPhone's masked token field with a trusted HTTPS endpoint. The included backend binds only to 127.0.0.1 and requires a TLS reverse proxy such as private Tailscale Serve for an iPhone connection. The mini must remain powered on and both devices connected to the same tailnet for that configuration. TLS certificates must be trusted by iOS. Redirects are rejected for both requests.

The capability endpoint is a protocol check, not a language validation or safety guarantee. Real speech samples, reference translations, native-speaker review, measured latency, and known failure cases are the remaining acceptance requirements for a working conversation bridge.

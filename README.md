# Tashlahet Bridge for iPhone

A native iPhone conversation bridge that captures short phrases of microphone audio and displays English returned by a compatible Tashelhit translation server.

**Current status:** the iPhone app builds and its automated tests pass. No translation model or server is bundled. Actual Tashelhit-to-English translation accuracy and latency have not been validated. The app checks server capabilities before opening the microphone.

## Open and build

Open `TashlahetBridge.xcodeproj` in Xcode, choose the `TashlahetBridge` scheme, then select an iPhone simulator or your iPhone. For a physical iPhone, select your development team under Signing & Capabilities. Deployment target: iOS 18 or later. The checked-in project is ready to open; XcodeGen is only needed to regenerate it after editing `project.yml`.

```sh
xcodebuild test -project TashlahetBridge.xcodeproj \
  -scheme TashlahetBridge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO
```

## Connect a server

1. Run a backend that implements [the server contract](docs/server-contract.md) with a model trained and evaluated for Tashelhit (`shi`) to English.
2. Put the iPhone and server on the same Wi-Fi network, or use a trusted HTTPS server.
3. Tap **Set up translation server**, enter its `/inference` URL, and tap **Test Connection**.
4. Allow Local Network and microphone access when iOS asks. Tap **Start Live Feed**, speak, and pause naturally between phrases.

On a physical iPhone, `localhost` is the phone. Use the Mac's LAN address or local hostname, for example `http://your-mac.local:8080/inference`. Local HTTP is supported by the app's local-network transport exception; remote servers should use HTTPS. Credentials in URLs and redirects are rejected.

Stock Whisper and stock whisper.cpp are not compatible with this custom raw PCM API. Setting `shi` in a request header does not add language support to a model. The backend must supply the language capability, not merely echo a successful capability response.

## Behavior and privacy

- AVAudioEngine captures input Bus 0. A serial worker converts to 16 kHz mono Float32 and segments phrases using audio energy.
- Speech segmentation includes 200 ms pre-roll, a 400 ms closing pause, and a five-second maximum chunk. Energy detection indicates audio activity; it does not identify the language.
- Requests use raw little-endian Float32 PCM and specify source `shi`, target `en`, task `translate`. Responses must match the audio chunk ID and language pair.
- Stop releases the microphone immediately, flushes the final speech tail, and finishes the accepted translation queue. In-flight requests can take up to the configured server timeout.
- A slow backend stops recording with an explicit error rather than silently dropping speech. Failed phrases can be retried while their audio remains available.
- The app keeps at most four pending phrases, eight failed audio chunks for retry, and 200 transcript entries. Audio and transcripts remain in memory and are released on clearing the conversation or app termination. Only the selected server address is persisted.
- Calls, microphone route changes, and backgrounding stop microphone capture. Translations may finish while the app still has execution time; there is no background recording mode.
- Audio is sent to the server you select. That server controls its own logging and retention. Local HTTP is unencrypted on the LAN.

## Verification

See [the local continuation report](verification/LOCAL_CONTINUATION.md) for build/test evidence and remaining limitations. Tests use synthetic PCM and controlled network responses; they do not establish real conversation translation quality.

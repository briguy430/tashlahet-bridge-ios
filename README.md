# Tashlahet Bridge for iPhone

A native iPhone app that captures short Tashelhit phrases and displays English returned by a translation server.

**Status:** the iPhone client and a private experimental Mac backend are implemented. Released MMS `shi` ASR and Helsinki English translation weights run on the mini. The tested English model makes major meaning errors on everyday sentences, so this is an evaluation prototype. It is not yet a validated conversation translator. The app checks server capabilities before opening the microphone and shows experimental accuracy warnings.

## Build the iPhone app

Open `TashlahetBridge.xcodeproj`, choose the `TashlahetBridge` scheme, and select a simulator or your iPhone. For physical installation, choose your development team under Signing & Capabilities. Deployment target: iOS 18 or later. XcodeGen is needed only to regenerate the project after source/project changes.

```sh
xcodebuild test -project TashlahetBridge.xcodeproj \
  -scheme TashlahetBridge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO
```

## Model and server setup

See [the model research and measured results](docs/model-backend-options.md) and [backend setup](docs/backend-setup.md). The backend downloads pinned model weights separately and requires an explicit experimental launch flag. It implements [the raw PCM server contract](docs/server-contract.md).

The intended away-from-home route is **iPhone → private HTTPS/Tailscale → Mac mini models**. The phone needs internet and Tailscale; the mini and backend must remain on. Models do not run on the iPhone. A TLS reverse proxy is required because the backend binds to localhost and the app sends tokens only over HTTPS.

In the app, tap **Set up translation server**, enter the HTTPS `/inference` URL and access token, then tap **Test Connection**. The token is stored in the iPhone Keychain. Allow microphone/local-network access when prompted. For an evaluation, tap **Start Live Feed**, speak, and pause between phrases.

Standard Whisper has no `shi` language entry. A Tashelhit fine-tune would be a different model; changing headers does not train it. Stock whisper.cpp also uses a different audio request format.

## Behavior and privacy

- AVAudioEngine converts input to 16 kHz mono Float32. Energy segmentation uses 200 ms pre-roll, a 400 ms closing pause, and a five-second maximum chunk. Energy detection does not identify a language.
- Responses must match the phrase ID and language pair. Stop releases the microphone, flushes the last speech tail, and drains accepted requests.
- A slow server stops recording with a visible error. Failed phrases can be retried while their audio is retained.
- Memory is bounded to four pending phrases, eight failed audio chunks, and 200 transcript entries. Clearing the conversation or terminating the app releases audio/transcripts.
- The server URL is persisted in UserDefaults; the access token is stored only in Keychain. Network responses are bounded and redirects are rejected.
- Calls, route changes, and backgrounding stop microphone capture. There is no background recording mode.
- Audio goes to the chosen server. The included backend disables access logging and does not save audio/transcripts. Other servers control their own retention.

## Verification

See [local verification](verification/LOCAL_CONTINUATION.md). Automated audio, client, and protocol tests establish implementation behavior. Actual model probes establish that inference executes. Native-speaker checks are still required to establish translated meaning.

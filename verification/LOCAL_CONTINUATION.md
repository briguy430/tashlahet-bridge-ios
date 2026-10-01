# Local continuation verification

Observed on October 1, 2026 on the local Apple silicon Mac mini:

| Check | Result |
| --- | --- |
| Cloud repo access | Cloned `briguy430/tashlahet-bridge-ios`; initial commit `1048c54` contained only a README |
| Saved work recovery | Five Swift drafts recovered from interrupted cloud workers' saved GitHub tool arguments |
| Local Apple toolchain | Xcode 27.0, Swift 6.4, iOS 27 SDK, installed iOS 26.5 simulator runtime |
| Simulator build and XCTest | Passed 44 tests, zero failures; `build/FinalAuthenticatedTests.xcresult` |
| Unsigned iPhone build | `xcodebuild build ... -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO` succeeded |
| Simulator installation and launch | App installed and launched on the iPhone 17 Pro simulator |
| Portrait UI | Screenshot visually inspected at `verification/iphone-portrait.png` (local, ignored in Git) |
| Authenticated client | Bearer headers on both requests, HTTPS enforcement, Keychain persistence and actionable errors passed regression tests |
| Signed iPhone build | Automatic signing with the existing development team succeeded for the paired physical iPhone |
| Physical iPhone installation and launch | `devicectl` installed and launched the signed app successfully; metadata in `build/iphone-final-install.json` and `build/iphone-launch.json` |
| Backend protocol | 25 pytest tests passed: auth, loaded capabilities, PCM/size limits, concurrent uploads, cancellation ownership, upload/model deadlines and token-file protections |
| Actual local model inference | Downloaded MMS `shi`, Marian English and stock Whisper large-v3 ran on real public audio; model pins and results in `docs/model-backend-options.md` |
| Translation acceptance | Failed/unresolved: everyday text translation has major meaning errors; no native-speaker speech review |

Tests cover real 48 kHz stereo conversion to 16 kHz mono and EOS drain, first audio-failure retention, terminal errors during Stop, the raw PCM network request, capability rejection, wrong language/chunk responses, invalid audio/server URLs, HTTP errors and oversized bodies, VAD boundaries, final speech flushing, stale callbacks, cancelled connection startup, endpoint invalidation, and retry/expiry behavior. Controlled network responses and synthetic audio are test fixtures, not language-model output.

The first test cycle caught oversized numeric ports that Foundation does not expose as a parsed integer. This was fixed, then the integrated suite passed. Xcode's automatic diagnostic collection after the intentionally failing test cycle was stopped once its complete failure results were recorded. The subsequent passing test run completed normally.

Independent code review identified dropped audio-drain errors, stale connection status after address edits, dead retry actions after audio expiry, and unbounded response buffering. These were corrected and covered by regression tests. The reviewer rechecked the fixes and reported no remaining concrete defect in those paths. This review does not replace physical-device or language validation.

The follow-up added a pinned MMS → Marian evaluation backend, HTTPS bearer authentication and Keychain storage in the client, and visible experimental quality warnings. Independent review prompted reserving the single slot before body streaming, adding upload/inference deadlines, and reading token files through a checked no-follow descriptor. Keychain tests caught unwanted persistence during initial load; initialization now preserves credentials when reads fail.

Current limitations:

- Weights are downloaded separately; no production or always-on backend is installed. The experimental launcher requires an explicit evaluation flag.
- Actual model-generated English and local request latency were measured, but their meaning has not passed validation. A successful API response is not acceptance.
- The remote HTTPS/Tailscale route and away-from-home physical iPhone requests have not been validated. Setup instructions are prepared in `docs/backend-setup.md`.
- Physical microphone capture, interruption behavior, route changes, and LAN permission behavior require device replay.
- The signed app builds successfully; physical-device installation/launch evidence is recorded separately below. Live microphone and real-network conversation behavior remain unverified.
- The app's energy detector does not identify Tashelhit.
- Simulator screenshot inspection covers the initial portrait view; larger text and landscape have not been validated.

Open the checked-in Xcode project to reproduce the build. The simulator app is at `build/DerivedData/Build/Products/Debug-iphonesimulator/TashlahetBridge.app`; the signed device build is at `build/SignedDevice/Build/Products/Debug-iphoneos/TashlahetBridge.app`. Build outputs, install metadata, and detailed `.xcresult` files stay local and are excluded from Git.

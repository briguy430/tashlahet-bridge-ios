# Local continuation verification

Observed on October 1, 2026 on the local Apple silicon Mac mini:

| Check | Result |
| --- | --- |
| Cloud repo access | Cloned `briguy430/tashlahet-bridge-ios`; initial commit `1048c54` contained only a README |
| Saved work recovery | Five Swift drafts recovered from interrupted cloud workers' saved GitHub tool arguments |
| Local Apple toolchain | Xcode 27.0, Swift 6.4, iOS 27 SDK, installed iOS 26.5 simulator runtime |
| Simulator build and XCTest | Passed 31 tests, zero failures; `build/FinalReviewedTests.xcresult` |
| Unsigned iPhone build | `xcodebuild build ... -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO` succeeded |
| Simulator installation and launch | App installed and launched on the iPhone 17 Pro simulator |
| Portrait UI | Screenshot visually inspected at `verification/iphone-portrait.png` (local, ignored in Git) |

Tests cover real 48 kHz stereo conversion to 16 kHz mono and EOS drain, first audio-failure retention, terminal errors during Stop, the raw PCM network request, capability rejection, wrong language/chunk responses, invalid audio/server URLs, HTTP errors and oversized bodies, VAD boundaries, final speech flushing, stale callbacks, cancelled connection startup, endpoint invalidation, and retry/expiry behavior. Controlled network responses and synthetic audio are test fixtures, not language-model output.

The first test cycle caught oversized numeric ports that Foundation does not expose as a parsed integer. This was fixed, then the integrated suite passed. Xcode's automatic diagnostic collection after the intentionally failing test cycle was stopped once its complete failure results were recorded. The subsequent passing test run completed normally.

Independent code review identified dropped audio-drain errors, stale connection status after address edits, dead retry actions after audio expiry, and unbounded response buffering. These were corrected and covered by regression tests. The reviewer rechecked the fixes and reported no remaining concrete defect in those paths. This review does not replace physical-device or language validation.

Current limitations:

- No model or server is bundled or configured; Brian confirmed that none exists yet.
- No actual Tashelhit-to-English translation, native-speaker accuracy evaluation, or real latency measurement has occurred.
- Physical microphone capture, interruption behavior, route changes, and LAN permission behavior require device replay.
- The physical-device build is unsigned; it is not an installable signed IPA and was not installed on Brian's iPhone.
- The app's energy detector does not identify Tashelhit.
- Simulator screenshot inspection covers the initial portrait view; larger text and landscape have not been validated.

Open the checked-in Xcode project to reproduce the build. The simulator app is at `build/DerivedData/Build/Products/Debug-iphonesimulator/TashlahetBridge.app`; the unsigned device build is at `build/Device/Build/Products/Debug-iphoneos/TashlahetBridge.app`. These build outputs and detailed `.xcresult` files stay local and are excluded from Git.

# Murmur - HANDOFF

Local-first Wispr Flow recreation: a native macOS menu-bar dictation app.
Hold a key, speak, and polished text is inserted wherever your cursor is - all speech-to-text on-device.

Status as of 2026-07-07: **working end-to-end, verified by the user** (fn-hold dictation inserts text into the focused app).
Build is clean, 16/16 unit tests pass.
2026-07-12: fixed "holding fn does nothing" - hotkey event tap moved to a dedicated thread with a watchdog, active-tap fallback for the silent Input Monitoring rejection, and the audio engine restart moved off the main thread (details in Architecture + the permissions gotchas).
2026-07-12: added the Wispr-Flow-style dashboard window (Home stats, History, Scratchpad, Dictionary, Snippets, Settings), screenshot-verified; opening the app now shows it.
2026-07-23: added **eye control v1** (⌃⌥E): look where you want the cursor, blink to click, 9-point calibration overlay, snap-to-window/Dock targets.
2026-07-23 v1.2 (after live user feedback): any blink or wink clicks instantly (no hold requirement), and cursor jitter cut with a median prefilter + steadier One Euro tuning.
Built + 29/29 tests green.

## Run it

```
zsh app/launch.sh            # build (if needed) + launch
zsh app/launch.sh --rebuild  # force rebuild first
zsh app/build.sh release     # just build the .app bundle
swift test                   # unit tests (rules cleaner, dictionary, history, LLM sanity, categories)
```

The app is a menu-bar item (waveform icon, `LSUIElement`, no Dock icon while the dashboard is closed).
Use it: click into any text field, **hold fn** and speak, release to insert.
**Quick-tap fn** for hands-free (tap again or go silent to stop).
Say **"scratch that"** to cancel a dictation.
**Opening the app** (manual launch, or double-clicking Murmur.app while it runs) shows the Wispr-Flow-style dashboard window: Home (stats + recent dictations), History, Scratchpad, Dictionary, Snippets, Settings.
The Dock icon appears while the dashboard is open and disappears when it closes; login-item launches stay quiet (no window).

## Architecture

Pipeline: hotkey → record → transcribe → clean → insert → history.

- `AppController` - central coordinator; owns state machine (idle/recording/finishing) and the pipeline.
- `HotkeyMonitor` - **CGEventTap** on the fn / right-⌘ / right-⌥ key, on a **dedicated thread** (never the main run loop).
  NSEvent global monitors do NOT receive fn; the event tap is required.
  macOS disables a tap whose host run loop stalls past ~1s, and main-thread stalls (audio engine spin-up, model warm-up) were killing the tap at exactly the moment the user pressed fn - so the tap lives on its own thread with a 2s watchdog that re-creates a missing tap (Accessibility granted late), re-enables a disabled one, and resyncs `isDown` from real hardware state so a missed release can't eat the next hold.
  Tap mode: tries listen-only first (needs Input Monitoring), falls back to an **active pass-through tap** which is authorized by Accessibility alone - macOS silently rejects *enabling* a listen-only keyboard tap without Input Monitoring (creation succeeds, `tapIsEnabled` stays false; see the permissions gotcha below).
- `HotkeyCenter` - single owner of all **Carbon RegisterEventHotKey** registrations (gaze ⌃⌥E + the user-recorded dictation-toggle shortcut), dispatching by hotkey ID.
  Carbon delivers every hot-key event to every installed handler, so per-feature `InstallEventHandler` calls cross-fire the moment a second hotkey exists - always register through the center.
  `ToggleShortcut` (same file) is the recorded keybind model: requires ⌘/⌥/⌃ or a function key, persists as JSON, renders "⌃⌥⇧⌘X" via UCKeyTranslate.
- `AudioDevices` - CoreAudio enumeration of input-capable devices (UID + name; UIDs are the stable identity).
  The preferred mic (Settings → General) is applied in `AudioRecorder.prepare()` by setting `kAudioOutputUnitProperty_CurrentDevice` on the input node's audio unit; changing it tears down and reinstalls the tap because the input format can change, and waits for any in-flight dictation to finish. A disconnected preferred mic falls back to the system default with a log warning.
- `AudioRecorder` - `AVAudioEngine` input tap, **pre-warmed at launch and kept alive** (defends against the VoiceInk empty-short-utterance race). Emits 16 kHz mono `[Float]` (the Sendable currency the transcriber actor needs). RMS-based voice detection drives hands-free silence auto-stop.
- `Transcriber` (actor) - wraps FluidAudio `UnifiedAsrManager` (Parakeet Unified 0.6B, int8, ANE). Downloads ~600 MB models on first run to `~/Library/Application Support/FluidAudio/Models`, then warms the ANE graph. ~0.2s to transcribe 10s of audio locally.
- `RulesCleaner` - deterministic zero-latency pass: filler removal, "scratch that" cancel, trailing "new line"/"new paragraph", whitespace/capitalization repair. Pure functions, unit-tested.
- `LLMCleaner` - optional on-device Apple FoundationModels pass (macOS 26). Collapses self-corrections, per-app tone. Constrained prompt ("input is dictation, never a question"), with a sanity check that rejects ballooning output (guards against the model answering instead of cleaning). Off by default.
- `DictionaryStore` - personal dictionary (alias → canonical, whole-word regex) + snippets (whole-utterance trigger → expansion). JSON in Application Support.
- `HistoryStore` - every dictation saved (raw + final + target app + outcome). Scratchpad note. The "nothing is ever lost" guarantee: on insertion failure the text is also left on the clipboard.
- `InsertionEngine` - three-tier insertion:
  1. **AX direct** - set `kAXSelectedText` on the focused element, *verified* by re-reading the value (so a silent AX failure can't double-insert with the paste fallback).
  2. **Clipboard + Cmd+V** - snapshot the full pasteboard, paste, restore after a delay. Marks the write with `org.nspasteboard.ConcealedType` so clipboard managers ignore it.
  3. **AppleScript keystroke** - types directly via System Events.
  Refuses secure input fields (`IsSecureEventInputEnabled`).
- `HUD` - floating non-activating `NSPanel` pill at the bottom of the screen; live mic-level bars + streaming partial text + result toast.
- `MainWindowController` + `MainWindowView` - the Wispr-Flow-style dashboard (AppKit-hosted window; menu-bar apps can't reliably open SwiftUI Window scenes from the app delegate).
  Sidebar: Home (stat tiles + recent dictations + hands-free button), History (search/copy/clear), Scratchpad, Dictionary, Snippets, Settings (General + Cleanup stacked).
  Owns the Dock-icon dance: `.regular` activation policy while open, back to `.accessory` on close.
  Shown on manual launch and on reopen (double-click while running); a login-item launch is detected via the `'oapp'`/`'prdt'`=`'lgit'` Apple event and stays windowless.
  Menu-bar items deep-link into sections via `MainWindowState`.
- `SettingsView` - the classic tabbed Settings scene (Cmd+,): General (hotkey, recordable toggle-dictation shortcut, microphone picker, silence, sounds, launch-at-login via `SMAppService`), Cleanup (fillers, AI polish, per-app tones), Dictionary, Snippets.
  The shortcut recorder suspends the registered Carbon hotkey while capturing (a registered combo never reaches local NSEvent monitors, so re-recording the same combo would otherwise be impossible).
  The dashboard reuses the same `GeneralSettings`/`CleanupSettings`/`DictionarySettings`/`SnippetSettings` views.
- `MurmurCLI` (`swift run murmur-cli file.wav`) - headless harness that runs the exact same STT stack; used for latency/pipeline verification without the GUI.

## Eye control (v1, 2026-07-23)

Press **⌃⌥E** to toggle an eye-control session: the cursor follows your gaze, and **any blink or wink clicks** (v1.2, 2026-07-23: the session detector runs minHold 0 on `min(earL, earR)`, so a quick natural blink or a one-eyed wink fires on reopen; only closures past 2s are ignored as resting).
First session shows a fullscreen 9-point calibration overlay (esc cancels); the calibration persists in UserDefaults.
Calibration is **user-paced and blink-confirmed** (2026-07-23 v1.1): each dot buffers gaze samples, then waits for a blink and captures the samples from just before the eyelids moved - nothing advances until the user blinks, and the flow doubles as blink-click practice. Dot capture keeps a small 0.15s minimum hold so a stray natural blink doesn't grab a dot early.
The median open-eye EAR (of the narrower eye, matching the session's min-EAR signal) measured during calibration is stored (`GazeCalibration.openEAR`) and seeds the session `BlinkDetector`, so blink-to-click works from the first blink even for narrow or wide eye shapes.
Recalibrate from the dashboard **Home page card** (Start/Stop + Recalibrate buttons), the menu-bar "Recalibrate Eye Control…", or Settings → Eye.
Clicks snap to the nearest window title bar or Dock icon within a configurable radius (Settings → Eye), which is what makes coarse webcam gaze reliable for app switching.

One-time setup: `zsh app/setup_gaze.sh` installs a Python venv with MediaPipe (~600 MB) into `~/Library/Application Support/Murmur/gaze-env` plus the `face_landmarker.task` model next to it.
Already done on this Mac (2026-07-23, anaconda python 3.12).

Architecture (all new code in `Sources/Murmur/Gaze/`):

- **Murmur owns the camera** (`GazeCamera`, AVCaptureSession 640x480 BGRA @15fps) so the Camera TCC grant, the `com.apple.security.device.camera` entitlement, and the green light all belong to Murmur.app - the same hardened-runtime recipe as the mic (see below).
- `app/gaze_helper.py` (bundled into Resources) is a **pure stdin→stdout child**: raw BGRA frames in, one JSON line of features out (iris-in-eye-box offsets, head pose matrix angles + translation, eye aspect ratios). No camera, no network, no TCC of its own. MediaPipe's legacy `solutions` API is GONE in 0.10.35 - it uses the Tasks `FaceLandmarker` (VIDEO mode, needs the `.task` model path as argv).
- `GazeHelperProcess` spawns the venv python, drops frames when >2 are in flight (backpressure), drains stderr (glog chatter would otherwise fill the pipe and hang the child).
- `GazeMapper` - ridge regression from the 10-dim features (+ quadratic iris terms) to normalized screen coords; features are standardized per-column first (iris ~0.1 vs head translation ~tens of cm). Fitted from the 9-point calibration, persisted via `GazeCalibration` (mapper + target screen rect in CG coords).
- Cursor smoothing is a **median-of-3 prefilter** (kills single-frame landmark spikes) into `OneEuroFilter` (v1.2 tuning: minCutoff 0.3, beta 0.5 - much steadier at fixation than the original 0.8/1.5); `BlinkDetector` turns EAR into click events with an adaptive open-eye baseline + hysteresis; clicks land where the user looked ~120ms *before* the eyelids started moving (positions ring buffer).
- `GazeController` - session state machine, Carbon `RegisterEventHotKey` for ⌃⌥E (system-wide, consumes the key, no event tap → can't interfere with the dictation tap), calibration driving, cursor posting via CGEvents, snap-target discovery (CGWindowList title bars + Dock icons via AX).

Known v1 limits: single screen (the one calibrated on); recalibrate if you move your laptop or slouch differently; Continuity Camera iPhones may be picked over the built-in camera if active; physical mouse use during a session fights the gaze cursor (stop the session to mouse normally).

## Signing & permissions (IMPORTANT)

The app is signed with a **stable self-signed identity "Murmur Dev Signing"** (in the login keychain).
This is what makes TCC permission grants (Accessibility, Microphone) **survive rebuilds** - ad-hoc signing (`-`) changes the identity every build and silently invalidates grants.
`app/build.sh` requires the identity and **fails hard if it is missing** (`ALLOW_ADHOC=1` to override for a throwaway build); it also verifies the final bundle carries the identity.
It used to silently fall back to ad-hoc, which caused the 2026-07-23 "asks for Accessibility on every restart" bug: a build shipped with only the linker's ad-hoc signature, so the TCC Accessibility grant (pinned to the cert leaf) stopped matching, `AXIsProcessTrusted()` read false at every launch, and the hotkey tap ran degraded on the 2s watchdog.

Third gotcha (2026-07-23, `codesign` fails with `errSecInternalComponent`): the signing key's keychain **partition list** only contained `apple-tool:` (the `security` CLI), so `codesign` (partition `apple:`) was blocked instantly - this is what silently broke the signing step and produced the ad-hoc build above.
`security set-key-partition-list` could not fix it: the key's label contained a trailing NUL (unmatchable from the CLI, later relabeled to "Murmur Dev Signing Key" via `SecItemUpdate`) and `SecKeychainItemSetAccessWithPassword` rejected the correct login password.
Fix that worked: replace the key's access object via `SecAccessCreate` + `SecKeychainItemSetAccess` from a small Swift script, trusting `/usr/bin/codesign` and `/usr/bin/security`; the new access carries no `partition_id` ACL entry, so the partition check no longer applies.
If signing ever breaks again with `errSecInternalComponent`, re-run that approach (scratch script pattern: query key by `kSecAttrApplicationLabel` = public-key hash `21CA411F...`).
Also: launch-time permission misreads no longer nag - `MurmurApp` defers onboarding ~30s at login when onboarding was already completed, and skips it if the permission poll recovers.

It is signed with the **hardened runtime** (`--options runtime`) plus `app/Murmur.entitlements`.
The entitlements are **mandatory, not optional**: under the hardened runtime, microphone access requires `com.apple.security.device.audio-input`. Without it macOS denies the mic *at the runtime layer* and **never shows the permission prompt at all** - `requestAccess` returns immediately, recording captures pure silence, and the app never appears in System Settings → Privacy → Microphone. (We also grant `com.apple.security.automation.apple-events` for the AppleScript-keystroke insertion fallback.) Verified via `tccd` logs: with the entitlement, `tccd` reaches `AUTHREQ_PROMPTING` for `kTCCServiceMicrophone`; without it, it never does.

Because the project lives under iCloud-synced `~/Desktop/Claude`, iCloud leaves `* 2.app` duplicate bundles and re-stamps `com.apple.FinderInfo` xattrs that break `codesign --strict`. `build.sh` now sweeps the duplicates and runs `xattr -cr` before signing.

Required permissions:
- **Accessibility** - the real gate. Needed for the CGEventTap (hotkey) AND for AX/paste insertion. Onboarding blocks "Done" only on this.
- **Microphone** - needed to record. Audio never leaves the device.

Gotcha we hit (and the real root cause of "mic never prompts / not in the list"): the missing `audio-input` entitlement above. It was *misdiagnosed* earlier as a Terminal-attribution artifact (launching from a terminal can make macOS credit the terminal's mic grant), but the actual cause was the hardened runtime blocking the mic with no entitlement. With the entitlement present, the prompt fires normally whether launched via `open Murmur.app` or double-click. Onboarding still gates "Done" on Accessibility only (the mic circle is also a manual override), but with the fix the real mic grant now works, so the override should not be needed.

Second gotcha (2026-07-12, the "holding fn does nothing" bug): a **listen-only** keyboard CGEventTap needs **Input Monitoring** (kTCCServiceListenEvent), which Murmur does not have - and macOS rejects it *silently*: `tapCreate` succeeds but `CGEvent.tapEnable` never sticks (`tapIsEnabled` returns false, no error anywhere).
It appeared to work before only via launch-context permission attribution (inheriting the launching terminal's grants), the same fragile mechanism as the old mic misdiagnosis above.
Fix shipped: `HotkeyMonitor` verifies `tapIsEnabled` after creation and falls back to an **active pass-through tap**, which is authorized by Accessibility (already required and granted in Murmur's own right).
Do not "simplify" the tap back to listen-only unless Input Monitoring is added to onboarding.

If a grant ever wedges during development:
```
tccutil reset Accessibility com.alessio.murmur
tccutil reset Microphone com.alessio.murmur
```

## Known follow-ups (not yet done)

- **Whisper-mode gain**: research flagged quiet/whispered dictation as a Wispr feature. Would apply an input-gain/AGC boost in `AudioRecorder.samples16k`. Deferred because it needs audible verification.
- **App icon**: currently uses the SF Symbol `waveform` for the menu bar; no custom `.icns` app icon yet.
- **Auto-learning dictionary**: the dictionary is manual; the plan's "suggest entries from words you re-correct in history" is not wired up.
- **Streaming partials** re-transcribe the whole buffer each tick (fine for short dictations; the offline 15s model is not a true streaming encoder). For very long hands-free sessions, switch to `StreamingUnifiedAsrManager`.
- The real Wispr Flow is cloud-STT-always; this is a deliberate local-first divergence (see `PLAN.md`).

## Files

```
Package.swift                    SwiftPM: Murmur (app), murmur-cli (harness), MurmurTests
app/Info.plist                   LSUIElement, mic + AppleEvents usage strings, bundle id com.alessio.murmur
app/build.sh                     build + assemble .app + sign with stable identity
app/launch.sh                    build-if-needed + relaunch
Sources/Murmur/*.swift           the app (see Architecture)
Sources/MurmurCLI/               headless STT harness
Tests/MurmurTests/               unit tests
PLAN.md                          research findings + original build plan
```

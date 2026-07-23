# Murmur - HANDOFF

Local-first Wispr Flow recreation: a native macOS menu-bar dictation app.
Hold a key, speak, and polished text is inserted wherever your cursor is - all speech-to-text on-device.

Status as of 2026-07-07: **working end-to-end, verified by the user** (fn-hold dictation inserts text into the focused app).
Build is clean, 16/16 unit tests pass.
2026-07-12: fixed "holding fn does nothing" - hotkey event tap moved to a dedicated thread with a watchdog, active-tap fallback for the silent Input Monitoring rejection, and the audio engine restart moved off the main thread (details in Architecture + the permissions gotchas).
2026-07-12: added the Wispr-Flow-style dashboard window (Home stats, History, Scratchpad, Dictionary, Snippets, Settings), screenshot-verified; opening the app now shows it.

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
- `SettingsView` - the classic tabbed Settings scene (Cmd+,): General (hotkey, silence, sounds, launch-at-login via `SMAppService`), Cleanup (fillers, AI polish, per-app tones), Dictionary, Snippets.
  The dashboard reuses the same `GeneralSettings`/`CleanupSettings`/`DictionarySettings`/`SnippetSettings` views.
- `MurmurCLI` (`swift run murmur-cli file.wav`) - headless harness that runs the exact same STT stack; used for latency/pipeline verification without the GUI.

## Signing & permissions (IMPORTANT)

The app is signed with a **stable self-signed identity "Murmur Dev Signing"** (in the login keychain).
This is what makes TCC permission grants (Accessibility, Microphone) **survive rebuilds** - ad-hoc signing (`-`) changes the identity every build and silently invalidates grants.
`app/build.sh` auto-detects the identity and uses it; falls back to ad-hoc if missing.

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

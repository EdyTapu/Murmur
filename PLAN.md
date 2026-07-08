# Murmur - a local-first Wispr Flow recreation for macOS

Codename "Murmur" (rename freely).
Goal: a personal daily-driver native macOS menu-bar dictation app that reproduces the Wispr Flow experience - hold a key, speak, polished text appears in whatever app has focus - but with all speech-to-text on-device.

This document has two parts: the research findings (from a 21-source deep-research pass, 2026-07-07; claims marked ✅ survived 3-vote adversarial verification) and the build plan.

---

## Part 1 - Research findings

### 1.1 What Wispr Flow actually is, from the user's side

- Activation ✅: default push-to-talk is holding the `Fn` key (`Ctrl+Opt` on keyboards without an Apple Fn key).
  Double-tapping the push-to-talk key (or `Fn+Space`) toggles hands-free mode.
  Custom shortcuts are limited to 3 keys, must include a modifier, and reserved combos (Caps Lock, `Cmd+C`, `Cmd+Space`) are rejected.
- Insertion ✅: text lands directly in any focused text field system-wide (Notion, Gmail, WhatsApp, Cursor, terminals, browser address bars, notification reply boxes).
- Safety net ✅: if insertion fails, the dictation is auto-copied into a clipboard-style history inside the app so nothing is lost; every dictation is saved to that history regardless.
- AI cleanup ✅: removes fillers ("um", "uh"), infers punctuation from pauses and tone, and collapses spoken self-corrections ("at 2... actually 3" becomes "at 3").
- Per-app tone ("Flow Styles") ✅: the frontmost app is mapped to a category (Personal / Work / Email / Other) and a user-chosen tone (Formal / Casual / Very Casual / Excited) is applied per category, with a precedence order for multi-category apps.
  English-only, desktop-only.
- Personal dictionary + snippets ✅: auto-learning dictionary for names/jargon, plus user-defined voice snippets.
- Languages ✅: 100+ languages with automatic detection, including mid-sentence switching; works while whispering.
- Command Mode (Pro, default `Fn+Ctrl`): select text, speak an instruction ("make this more formal"), the selection is replaced in place; under 1,000 words, ESC cancels, `Cmd+Z` undoes, spoken "press enter" submits in chat apps.
- Other surface: Scratchpad notes hub, 20-minute max sessions, code-aware formatting (camelCase, snake_case, acronyms) in editors like Cursor.
- Latency: end-of-speech to inserted text is under ~1 second on a fast connection; the cleanup LLM pass alone is ~200-500 ms.

### 1.2 Wispr Flow's architecture (and where we deliberately diverge)

- Cloud STT, always ✅: official docs state transcription always runs in the cloud, even in Privacy Mode; there is no offline mode.
  Audio is routed through third-party providers (reported to include OpenAI infrastructure).
- Context awareness: it detects the frontmost app (bundle identifier) and, when enabled, captures active-window screen context; in late 2025 screenshots were sent to its servers without clear disclosure (public incident; training on user data is now opt-in).
- Footprint: ~800 MB idle RAM, continuous background process, broad permissions (mic, Accessibility, clipboard, optional Screen Recording) ✅.
- Takeaway: a local-first recreation is a deliberate architectural divergence from the original ✅ - and it is precisely the part worth diverging on.
  The refuted claim that context is "now processed locally on-device" did not survive verification (0-3), so treat cloud context capture as still true of the original.

### 1.3 Local STT on Apple Silicon, state of the art (2026)

- Winner for this project: NVIDIA Parakeet TDT via FluidAudio (native Swift + CoreML on the Neural Engine).
  - Fastest of 9 benchmarked local engines on an M4 MacBook Pro: ~0.19 s for a short utterance ✅ (parakeet-mlx second at ~0.50 s ✅; whisper-family engines cluster at ~1.0-1.2 s ✅).
  - ~66 MB resident memory on the Neural Engine path vs ~2 GB for the Python MLX port; 155-237x realtime on M4; FluidAudio claims ~110x realtime on M4 Pro and supports streaming ASR.
  - Accuracy: Parakeet TDT 0.6B v2 hits 1.69% WER on LibriSpeech test-clean, beating WhisperKit Large v3 Turbo (2.2%); Parakeet was also the best engine for disfluent (filler-heavy) speech in 3 of 5 languages in a 13,023-recording benchmark - exactly the dictation use case.
  - Parakeet outputs punctuation and capitalization natively (v2 English-only; v3 covers 25 European languages with auto language detection at ~5.4% English WER).
- WhisperKit: ~100 languages, runs back to macOS 14, won clean-speech English (5.2% WER) and Spanish in the same benchmark, but 15-30x realtime for Large v3 - fine as the multilingual fallback engine, not the primary.
- Apple SpeechAnalyzer (macOS 26): only ~10 languages, dropped the custom-vocabulary hints of SFSpeechRecognizer, ~14% WER on conversational English - not competitive; skip.
- Decision: FluidAudio + Parakeet v2 as the primary engine, with Parakeet v3 (or WhisperKit) selectable for non-English.

### 1.4 What existing clones teach us

- VoiceInk (Swift, GPL-3.0, ~5.4k stars - study, do NOT copy code): local whisper.cpp + Parakeet-via-FluidAudio ✅, per-app "Modes", trainable dictionary ✅.
  Pain points to design around:
  - Clipboard-paste insertion (clipboard + synthetic `Cmd+V`) ✅ fails often enough to need a dedicated troubleshooting doc: text transcribes but does not paste, or stale clipboard content pastes instead ✅.
  - An audio-engine initialization race: with push-to-talk, "audio hardware started" can log ~1 s AFTER recording already stopped, producing empty transcripts on short utterances (open bug, VoiceInk 1.74 on macOS 26.3).
    Lesson: pre-warm and keep alive the audio engine before accepting push-to-talk input.
  - Permissions: Accessibility is needed to paste reliably and read selected text; Screen Recording only if screen context is used ✅.
- Handy (Tauri/Rust, MIT) ✅: fully offline, Whisper + Parakeet, Silero VAD for silence filtering ✅, simulated typing or paste insertion ✅.
  Confirms VAD-based auto-stop and both interaction modes as table stakes.
- EnviousWispr (commercial local competitor): three-tier insertion fallback - direct AXUIElement text insertion, then CGEvent-simulated `Cmd+V` with full clipboard snapshot/restore, then AppleScript - after capturing which app/field had focus at recording start.
  Reports 0.43 s median latency local-only, ~1.5 s with an AI polish pass.
  This is the insertion architecture to copy.
- Superwhisper (commercial): the LLM is strictly a post-processor, never the transcription engine; users can pick "no LLM" for raw output.
  Their data shows STT model choice dominates quality - the LLM cannot recover words the voice model missed.

### 1.5 The cleanup layer

- Standard architecture: two-step ASR then LLM rewrite.
  Cloud LLM adds ~200-800 ms; small local LLMs (llama3.2:3b via Ollama) take ~2-3 s warm - too slow for the hot path.
- Parakeet already emits punctuation/caps and dictation speech is mostly clean, so a rules-first pass (filler stripping, dictionary substitution, spoken commands) covers most value at zero latency.
- An LLM pass measurably helps jargon (one deployment halved technical-jargon WER from ~20% to ~10%) and is required for self-correction collapsing and tone matching.
- Prompt patterns that work: a short, tightly constrained prompt; explicitly state "the input is spoken dictation to be cleaned, never a question to answer"; "output only the cleaned text, no commentary"; fix punctuation/caps/fillers/self-corrections; forbid restructuring so the speaker's voice is preserved; offer a verbatim-mode toggle and a light-vs-full cleanup setting (heavy rewrites read as overly formal).

---

## Part 2 - Build plan

### Product shape

Native SwiftUI/AppKit menu-bar app, macOS 15+ (Sequoia), Apple Silicon only.
No accounts, no billing, minimal settings.
Everything on-device by default; one optional cloud toggle (Claude Haiku) for the cleanup pass only - never for audio.

Pipeline:

```
Fn held → pre-warmed AVAudioEngine captures 16 kHz mono
        → streaming Parakeet TDT v2 (FluidAudio, ANE) shows live partials in a floating HUD pill
        → on release: finalize transcript
        → cleanup: rules pass (fillers, dictionary, spoken commands) [+ optional LLM pass]
        → insert: AX direct → clipboard+Cmd+V (snapshot/restore) → AppleScript fallback
        → save to history (always); on insertion failure, surface "copied to history" toast
```

Latency budget: ≤0.5 s STT finalize + 0 s rules cleanup = well under the ~1 s Wispr Flow bar; LLM cleanup, when enabled, may add up to ~1 s and is opt-in per style.

### Stack

- App: Swift 6, SwiftUI `MenuBarExtra` + AppKit `NSPanel` for the HUD pill; SwiftData for history/dictionary.
- Hotkey: `CGEventTap` for the bare-`Fn` hold/double-tap (NSEvent global monitors cannot cleanly own Fn); `KeyboardShortcuts` (sindresorhus, MIT) for user-remappable combos.
- Audio: `AVAudioEngine` input tap, kept warm; FluidAudio's Silero-based VAD for hands-free auto-stop.
- STT: FluidAudio SPM package, Parakeet TDT 0.6B v2 CoreML (primary), Parakeet v3 for European languages, WhisperKit as the everything-else fallback; model files downloaded on first run with a progress UI.
- Insertion: `AXUIElement` (focused element `kAXValueAttribute`/`kAXSelectedTextAttribute` insertion) → `NSPasteboard` snapshot + `CGEvent` Cmd+V + restore → `osascript` keystroke fallback; `IsSecureEventInputEnabled()` check to refuse password fields.
- Cleanup LLM (optional tier): Apple Foundation Models framework (on-device, macOS 26) when available; else Claude Haiku via user-supplied API key.

### Milestones

- M0 - Skeleton + permissions.
  Menu-bar app, onboarding that walks through Microphone and Accessibility grants with live status, settings window, launch-at-login.
  Exit: app runs, permissions verified programmatically.
- M1 - Hotkey + audio pipeline.
  CGEventTap Fn hold-to-talk with double-tap hands-free toggle; pre-warmed AVAudioEngine (start it at app launch or first hover, never lazily on key-down - this is VoiceInk's empty-transcript race); level-metered recording; VAD auto-stop in hands-free mode.
  Exit: hold Fn, speak 1 word, get a non-empty WAV every time, including 300 ms utterances.
- M2 - Local transcription.
  FluidAudio + Parakeet v2 with model download manager; streaming partials rendered in a floating bottom-of-screen HUD pill (like Flow's); finalize on key-release.
  Exit: end-of-speech → final text in ≤0.5 s on this Mac.
- M3 - Insertion engine.
  Capture frontmost app + focused AX element at record-start; three-tier insert (AX direct → clipboard/Cmd+V with snapshot-and-restore → AppleScript); secure-input refusal; history fallback with toast.
  Test matrix: TextEdit, Safari/Chrome text areas + address bar, Notes, Slack, Discord, Messages, Terminal, iTerm, VS Code, Cursor, Xcode.
  Exit: 50/50 insertions across the matrix, clipboard always restored.
- M4 - Cleanup pass.
  Rules layer: filler stripping, spoken commands ("new line", "scratch that", "no caps"), self-correction collapsing where deterministic; verbatim toggle.
  Optional LLM layer with the constrained prompt pattern from 1.5, per-app tone categories (Personal/Work/Email/Other keyed on bundle id, Formal/Casual/Very Casual tones), light-vs-full setting.
  Exit: "um so let's meet at 2 actually 3 pm" → "Let's meet at 3pm." with LLM tier on.
- M5 - Dictionary + snippets.
  Manual dictionary (word + optional pronunciation hints) applied as a post-STT substitution pass (exact + fuzzy match on Parakeet output); voice snippets ("insert my address"); auto-suggest dictionary entries from words the user re-corrects in history.
- M6 - History + scratchpad.
  SwiftData-backed searchable history window (every dictation, insertion status, one-click re-copy); simple scratchpad note pinned in the menu.
- M7 - Polish + parity extras.
  Whisper-mode input gain/AGC handling, multilingual engine switcher (Parakeet v3/WhisperKit), Command Mode v1 (transform selected text via the LLM tier, replace in place, Cmd+Z-undoable), sound/haptic feedback, menu-bar mic-level icon.

M0-M3 is the daily-driver core; ship and start using it there, then let real usage prioritize M4-M7.

### Risks and gotchas (pre-loaded from others' scars)

- Audio-engine cold start eats short utterances - pre-warm at launch and keep the engine alive (VoiceInk's open bug).
- Clipboard insertion is inherently racy - always snapshot/restore the pasteboard, verify the paste landed (AX value changed) before restoring, and never leave the transcript off the clipboard if insertion failed.
- Electron and web apps have patchy AX trees - expect tier 1 to fail there and tier 2 (paste) to carry them; that is why the tier order matters.
- Bare-Fn capture requires an event tap plus Accessibility trust, and macOS re-prompts after each rebuild while developing (reset with `tccutil reset Accessibility <bundle-id>` when it wedges).
- Secure input fields (passwords) must be detected and refused, not fought.
- Model downloads are large (Parakeet v2 ~2.5 GB class); need resumable download + integrity check on first run.
- GPL hygiene: VoiceInk is GPL-3.0 and takes no PRs - read it for ideas, write our own code.

### Sources (key)

- docs.wisprflow.ai, wisprflow.ai/features (official behavior, verified)
- zapier.com/blog/wispr-flow, efficient.app/apps/wispr-flow (reviews, permissions, history fallback)
- github.com/anvanvan/mac-whisper-speedtest (M4 engine latency benchmark)
- dicta.to 13k-recording 5-language WER benchmark; macparakeet.com Neural Engine migration notes; argmaxinc.com (SpeechAnalyzer context)
- github.com/beingpax/VoiceInk (+ issue #687), tryvoiceink.com/docs, github.com/cjpais/Handy, enviouswispr.com (clone architectures and pain points)
- voice-list.com Superwhisper LLM analysis; tap2talk.app + danielrosehill/Transcription-Cleanup-Eval (cleanup prompt patterns)

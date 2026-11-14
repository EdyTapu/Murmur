# Murmur

Local-first dictation for macOS.
Hold a key, speak, and cleaned-up text is typed into whatever app has focus.
All speech-to-text runs on your Mac, so audio never leaves the device.
Inspired by Wispr Flow, built from scratch in Swift.

## Requirements

- An Apple Silicon Mac running macOS 26 or newer.
- Xcode 26 or newer (for the Swift 6 toolchain and the macOS 26 SDK).
- About 1 GB of free disk space, and an internet connection for the first launch.
  Murmur downloads the Parakeet speech model (roughly 600 MB) once, then works offline.

## Build and run

```
git clone https://github.com/EdyTapu/Murmur.git
cd Murmur
ALLOW_ADHOC=1 zsh app/launch.sh
```

The first build takes a few minutes because it compiles the speech engine.
The app lands in `build/Murmur.app` and shows up as a waveform icon in the menu bar.

`ALLOW_ADHOC=1` tells the build to use a throwaway signature instead of the author's signing certificate, which you do not have.
Without it the build stops with a "signing identity not found" error.
See [Stable signing](#stable-signing-optional) if you plan to rebuild often.

## First launch

1. Grant **Accessibility** when the onboarding window asks.
   Murmur needs it to see the dictation key and to type text into other apps.
2. Grant **Microphone** when macOS prompts.
3. Wait for the model download to finish (one time only).
4. If you use the fn key, set System Settings → Keyboard → "Press 🌐 key to" → "Do Nothing", so macOS does not also open the emoji picker.

## Using it

- **Hold fn** and speak, then release to insert the text.
- **Quick-tap fn** for hands-free dictation, and tap again or go silent to stop.
- Say **"scratch that"** to cancel a dictation.
- Open the app (or click the menu bar icon) for the dashboard: history, scratchpad, personal dictionary, snippets, and settings.
- The dictation key can be changed to right ⌘ or right ⌥ in Settings, and you can record a separate shortcut for hands-free mode.
- "AI polish" is an optional on-device cleanup pass that uses Apple Intelligence.
  It is off by default.

### Head control (experimental)

Press **⌃⌥E** to move the cursor by turning your head, and blink or pucker to click.
It uses the built-in camera and asks for Camera permission the first time.
Press ⌃⌥E again to stop.

## Privacy

Audio and video are processed on-device and are never uploaded.
The only network traffic is the one-time model download.
Your history, dictionary, and snippets are stored as plain JSON in `~/Library/Application Support/Murmur`.

## Stable signing (optional)

macOS ties permission grants to the app's code signature.
An ad-hoc build gets a new signature every time, so after each rebuild you have to remove Murmur from System Settings → Privacy & Security → Accessibility and grant it again.
To make grants survive rebuilds, create a signing certificate once:

1. Open Keychain Access → Certificate Assistant → Create a Certificate.
2. Name it exactly `Murmur Dev Signing`, with Identity Type "Self-Signed Root" and Certificate Type "Code Signing".
3. Build with `zsh app/launch.sh --rebuild` (no `ALLOW_ADHOC` needed).

## Troubleshooting

- **Holding the key does nothing:** Accessibility is not granted for this build.
  Remove Murmur from the Accessibility list, add it again, and relaunch.
- **Permissions seem stuck:** reset them and relaunch.
  ```
  tccutil reset Accessibility com.alessio.murmur
  tccutil reset Microphone com.alessio.murmur
  ```
- **Text does not appear in password fields:** this is deliberate, Murmur refuses secure input fields.

## Development

```
swift test                        # unit tests
swift run murmur-cli file.wav     # transcribe a file without the GUI
zsh app/build.sh release          # build the .app without launching
```

`HANDOFF.md` documents the architecture and the macOS permission pitfalls.
`PLAN.md` holds the original research and build plan.

## License

MIT, see [LICENSE](LICENSE).
Speech recognition is provided by [FluidAudio](https://github.com/FluidInference/FluidAudio) and the Parakeet model, which carry their own licenses.

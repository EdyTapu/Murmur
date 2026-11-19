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

## Download and install

There is no prebuilt download yet, so you build Murmur from source.
It is one command, and it needs no Xcode project or extra tools.

1. Install Xcode 26 or newer from the App Store, and open it once so it finishes installing its components.
2. Get the code.
   With git:
   ```
   git clone https://github.com/EdyTapu/Murmur.git
   cd Murmur
   ```
   Without git: on the [GitHub page](https://github.com/EdyTapu/Murmur) choose **Code → Download ZIP**, unzip it, then open Terminal and `cd` into the unzipped folder.
3. Build and launch:
   ```
   ALLOW_ADHOC=1 zsh app/launch.sh
   ```

The first build takes a few minutes because it compiles the speech engine.
The app lands in `build/Murmur.app` and shows up as a waveform icon in the menu bar.
To start it again later, run `open build/Murmur.app`, or turn on "Launch at login" in Murmur's settings.
To update, run `git pull` and then `ALLOW_ADHOC=1 zsh app/launch.sh --rebuild`.

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
- The text goes to whichever app is in front when you stop.
  The dictation bar shows that app's name and follows you if you switch apps while talking.
- Open the app (or click the menu bar icon) for the dashboard: history, scratchpad, personal dictionary, snippets, transforms, and settings.
- The dictation key can be changed to right ⌘ or right ⌥ in Settings, and you can record a separate shortcut for hands-free mode.

### More features

- **Cleanup levels:** None, Light, or Medium.
  Light removes filler words, keeps only your correction ("at 2, actually 3"), and turns spoken lists and punctuation into real ones.
  Medium adds an on-device rewrite pass.
- **Code words:** say "snake case user id" or "camel case get user name".
  Murmur also reads the names visible in the app you dictate into and spells them the same way.
- **Command Mode:** hold ⌃ with the dictation key and say what to do with the selected text ("make this more formal"), or "search for …" to open a web search.
- **Transforms:** saved rewrites that you apply to selected text from a shortcut.
- **Learning:** retype a word Murmur got wrong and it adds the fix to your dictionary.
- **Scratchpad:** tabbed notes that open from any app with ⌥S.
- **Microphones:** rank your microphones in Settings.
  Murmur never uses a Bluetooth headset's microphone unless you add it, so your headphones keep full audio quality.
- **Mute while dictating:** other audio is muted while you record.

Medium cleanup, Command Mode, and Transforms use Apple Intelligence, so they need a Mac that has it turned on.

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
- **Dictation hears nothing after connecting headphones:** choose "Refresh Microphone" in the menu bar menu or in Settings.
  Murmur reconnects to the microphone and tells you whether sound arrives.
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

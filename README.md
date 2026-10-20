# NotchCoach

A teleprompter that sits in your MacBook's notch, right under the camera, with AI help built in.

- **Auto-scroll** at a speed you set. Hover over the prompter to pause.
- **Follow my voice**: the script only moves as you speak, using Apple's on-device speech recognition. Words you've already said are dimmed.
- **AI writer**: turn rough notes into a spoken script, or polish an existing one.
- **Live call cues**: listens to the other people on a call and shows up to three short talking points under your script.
- **Choose your AI**: Gemma running on your Mac (free, private), Claude with your own API key (best quality), or Apple Intelligence (free, built into macOS 26).
- Hidden from screen sharing and screen recordings.

## Install

1. Open the [latest release](../../releases/latest) and download `NotchCoach.zip`.
2. Unzip it and drag `NotchCoach.app` into **Applications**.
3. The app isn't notarised by Apple, so the first launch is blocked. Open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**. Or run this in Terminal:
   ```
   xattr -dr com.apple.quarantine /Applications/NotchCoach.app
   ```
4. NotchCoach runs from the menu bar (speech-bubble icon). The script window opens on launch.

Needs an Apple-silicon Mac (M1 or later) with macOS 14 (Sonoma) or later. Works on Macs without a notch too: the prompter then sits at the top centre of the screen.

## Choose an AI engine

Pick one in **Settings → AI engine**. It powers both the AI writer and live cues.

| Engine | Cost | Privacy | Needs |
|---|---|---|---|
| **Gemma** (default) | Free | Everything stays on your Mac | A one-time model download of a few GB, and a few GB of free memory while it runs |
| **Claude** | Pay per use with your own key | Text and call transcripts go to Anthropic | An API key from [console.anthropic.com](https://console.anthropic.com), stored in your Keychain |
| **Apple Intelligence** | Free | Everything stays on your Mac | macOS 26 on a Mac with Apple Intelligence turned on |

Gemma comes in two sizes: E2B (faster, lighter) and E4B (better writing, more memory). Claude gives the best writing. Apple's model has a small memory window, so very long scripts may need Gemma or Claude.

If you use live cues with Claude, let others on the call know their speech is being sent to an AI service.

## Permissions

| Feature | macOS asks for |
|---|---|
| Follow my voice | Microphone, Speech Recognition |
| Live call cues | Speech Recognition, Screen & System Audio Recording (used for call audio only) |

If you said no by mistake, turn it on under **System Settings → Privacy & Security** and restart the feature. Because each build has a new ad-hoc signature, macOS may ask again after you install an update.

## Shortcuts

| Keys | Action |
|---|---|
| ⌃⌥ Space | Play / pause, or start / stop listening |
| ⌃⌥ ↑ / ↓ | Back / forward one line |
| ⌃⌥ = / − | Faster / slower |
| ⌃⌥ R | Restart from the top |
| ⌃⌥ V | Switch Auto-scroll / Follow my voice |
| ⌃⌥ C | Live call cues on / off |
| ⌃⌥ H | Show / hide the prompter |

## Build it yourself

GitHub Actions builds the app on every push to `main` and publishes it as a release. On a Mac with Xcode or the Swift toolchain installed you can also run:

```
./scripts/build-app.sh
open build/NotchCoach.app
```

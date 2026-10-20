# NotchCoach

A teleprompter that sits in your MacBook's notch, right under the camera, with AI help built in.

- **Auto-scroll** at a speed you set. Hover over the prompter to pause.
- **Follow my voice**: the script only moves as you speak, using Apple's on-device speech recognition. Words you've already said are dimmed.
- **AI writer**: turn rough notes into a spoken script, or polish an existing one (Claude API).
- **Live call cues**: listens to the other people on a call and shows up to three short talking points under your script (Claude API).
- Hidden from screen sharing and screen recordings.

## Install

1. Open the [latest release](../../releases/latest) and download `NotchCoach.zip`.
2. Unzip it and drag `NotchCoach.app` into **Applications**.
3. The app isn't notarised by Apple, so the first launch is blocked. Open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**. Or run this in Terminal:
   ```
   xattr -dr com.apple.quarantine /Applications/NotchCoach.app
   ```
4. NotchCoach runs from the menu bar (speech-bubble icon). The script window opens on launch.

Needs macOS 14 (Sonoma) or later. Works on Macs without a notch too: the prompter then sits at the top centre of the screen.

## Set up the AI features

1. Create an API key at [console.anthropic.com](https://console.anthropic.com).
2. Paste it into **Settings → Claude** and click **Save**. It's stored in your macOS Keychain.
3. Pick a model. Opus 5.5 gives the best quality; Haiku 5.5 is fastest and cheapest, and a good choice for live cues.

Script text is sent to Anthropic only when you use the AI writer. When live cues are on, the transcript of the other people on the call and your script are sent after each pause in the conversation. Let others on the call know if you use it.

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

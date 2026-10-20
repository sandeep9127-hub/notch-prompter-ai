# Privacy

NotchCoach is built to keep what you say on your Mac.

## What NotchCoach never does

- It has no account, sign-up, analytics, ads or tracking.
- It doesn't run a server, and the developers receive nothing from your Mac.
- It doesn't record or save your audio, and it doesn't save transcripts.

## What stays on your Mac

- **Your script and settings** are stored in macOS user defaults on your Mac.
- **Your Anthropic API key**, if you add one, is stored in your macOS Keychain.
- **A small log file** at `~/Library/Logs/NotchCoach.log` records app events, such as starting and stopping features and error messages, to help with bug reports. It doesn't contain your script or what anyone said. Delete it whenever you like.

## Speech recognition

**Follow my voice** listens to your microphone, and **live call cues** listen to your Mac's system audio (the other people on a call). Both use Apple's speech recognition, which runs on your Mac when your language supports it. Otherwise Apple may process the audio under [Apple's privacy policy](https://www.apple.com/legal/privacy/). Audio isn't stored by NotchCoach.

## AI features

What happens depends on the AI engine you choose in Settings:

| Engine | Where the text goes |
|---|---|
| Gemma | Nowhere. It runs on your Mac. The model is downloaded once from Hugging Face. |
| Apple Intelligence | Nowhere. It runs on your Mac. |
| Claude | Your script, your notes and, for live cues, recent call transcript are sent to Anthropic's API using your own key, under [Anthropic's privacy policy](https://www.anthropic.com/legal/privacy). |

## Live call cues and consent

Live cues listen to other people. Tell the people on your call when you use them. Recording and consent rules vary by country.

## Questions

Open an issue on [GitHub](https://github.com/sandeep9127-hub/notch-prompter-ai/issues).

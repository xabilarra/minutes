# Minutes

A tiny native macOS menu-bar app that records your video calls **without a bot joining the meeting**, transcribes them with Groq when the call ends, and keeps everything on your Mac as plain files your AI agents can read.

- **No bot, no meeting invite.** Minutes notices when Zoom, Teams, Slack, Webex, FaceTime, WhatsApp, Discord or a browser tab with Google Meet / Teams / Zoom / Whereby / Jitsi starts using the microphone, and starts recording by itself. It stops when the app releases the microphone.
- **Two separate audio tracks**: your microphone (**Yo**) and what the other participants say through your Mac (**Ellos**), captured with a Core Audio process tap. When the microphone also picks up the others through your speakers, those echoed lines are removed from the transcript.
- **Sharp video**: the meeting window (including what others share) or the whole screen (including what you present), at native resolution up to 2560 px wide, 15 fps, hardware HEVC — about 0.5 GB per hour for a typical call.
- **Agent-ready output**: Markdown and JSON transcripts with timestamps that line up with the video, plus metadata. When the call ends, a floating pill offers **Copy text**, **Copy path** and **Open folder**.
- **Light**: a 2 MB SwiftUI app. Capture and encoding run on macOS' own frameworks and the media engine.

The UI is in Spanish on Spanish systems and in English elsewhere.

## Requirements

- macOS 15 or later
- Xcode 16 or later (Swift 6) to build
- A [Groq API key](https://console.groq.com/keys) for transcription (`whisper-large-v3`, around $0.11 per audio hour at the time of writing; a meeting has two tracks)

## Install

```bash
git clone https://github.com/xabilarra/minutes.git
cd minutes
scripts/build-app.sh --install   # builds, signs and copies Minutes.app to ~/Applications
open ~/Applications/Minutes.app
```

The script signs with your **Apple Development** certificate when you have one (free: Xcode → Settings → Accounts → Manage Certificates). macOS ties privacy permissions to the signature, so with a certificate it remembers them across rebuilds; without one the app is signed ad hoc and macOS asks again after every rebuild.

## First run

Opening Minutes shows its window with the current state, each permission and the Groq key field:

1. **Microphone** — allow when asked.
2. **Screen & System Audio Recording** — enable Minutes in System Settings → Privacy & Security, then relaunch it. Needed for the video and to recognise meetings in browser tabs.
3. **System audio** — allow when asked (the window has a button to trigger the prompt).
4. **Groq API key** — paste it in the window. It is stored in your macOS Keychain.

Minutes then lives in the menu bar (waveform icon). On Macs with many menu bar icons it can hide behind the notch; opening Minutes again always brings the window back.

Use headphones when you can: it gives the cleanest "Yo" track.

## What you get

One folder per meeting in `~/Reuniones`:

```
~/Reuniones/2026-10-19 10.30 Weekly sync (Google Meet)/
  video.mp4            meeting window or screen
  yo.m4a               your microphone
  ellos.m4a            the other participants
  transcripcion.md     "[00:12:31] Ellos: …" grouped by speaker turns
  transcripcion.json   segments with exact start/end seconds and speaker
  meta.json            app, window title, start/end, duration, video offset, transcription status
```

Folder, file and speaker names are Spanish ("Reuniones", "transcripción", "Yo" = me, "Ellos" = them). Transcript timestamps are measured from the start of the audio; the video starts `videoOffsetSeconds` later (usually under a second).

Videos move to the Trash after the retention period you choose (7, 30, 90 days or never). Audio and transcripts are kept.

## How it works

- **Detection** polls Core Audio's process list every second for apps whose audio input is running and matches them against known meeting apps; browser tabs count only when the window title looks like a meeting. Recording starts after 3 s and stops 45 s after the app releases the microphone (the pill shows a countdown with *Stop now*), so short pauses do not split the meeting.
- **Audio**: a private global process tap records system audio and `AVAudioEngine` records the microphone, both as 16 kHz mono CAF aligned on the host clock.
- **Video**: ScreenCaptureKit + `AVAssetWriter` (HEVC), written as a crash-tolerant fragmented movie and remuxed to MP4 at the end. Minutes' own windows are never recorded.
- **Transcription** runs after the call: each track is cut into chunks of up to 10 minutes, silent chunks are skipped, segments over silence and known Whisper hallucinations are dropped, and microphone echo of the other side is removed. You can pick the language or let Whisper detect it.

## Privacy and responsible use

- Recordings and transcripts never leave your Mac, except the audio chunks sent to Groq to be transcribed. There is no telemetry.
- Recording laws differ: in some places **every participant must consent**. Minutes does not announce itself in the call, so tell people you are recording.

## Limitations

- macOS only. Transcription needs Groq (no on-device model yet).
- Speakers are "you" and "the others"; individual names are not identified.
- Output names are Spanish.

## Development

```bash
swift test                         # unit tests (core logic and transcription pipeline)
scripts/build-app.sh               # build + sign into build/Minutes.app
scripts/check-localizations.sh     # every Spanish UI string has an English translation
swift scripts/make-icon.swift      # regenerate Resources/AppIcon.icns
log show --last 10m --predicate 'subsystem == "io.github.xabilarra.Minutes"'
```

Targets: `MinutesCore` (pure logic), `MinutesCapture` (Core Audio, AVFoundation, ScreenCaptureKit) and `Minutes` (the menu-bar app). UI strings are written in Spanish in the code; `Resources/en.lproj` holds the English translations.

For a quick end-to-end check, quit Minutes and run `open build/Minutes.app --args --smoke-test 20`: it records the frontmost app for 20 seconds, transcribes it and quits.

## License

[MIT](LICENSE)

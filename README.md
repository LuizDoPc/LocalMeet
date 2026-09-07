<div align="center">
  <img src="Resources/AppIcon-1024.png" width="128" alt="LocalMeet app icon">

  # LocalMeet

  **Your meetings, transcribed and organized without leaving your Mac.**

  Capture system audio and your microphone as independent tracks, preserve the original language, and generate translations, summaries, and next steps with on-device models.

  [![macOS 15+](https://img.shields.io/badge/macOS-15%2B-111111?logo=apple)](https://www.apple.com/macos/)
  [![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://www.swift.org/)
  [![Local processing](https://img.shields.io/badge/privacy-local%20processing-2E7D32)](#privacy)
  [![Release](https://img.shields.io/github/v/release/LuizDoPc/LocalMeet?display_name=tag)](https://github.com/LuizDoPc/LocalMeet/releases/latest)
</div>

---

## Features

- Captures **system audio and microphone separately**, even when people speak over each other.
- Identifies distinct speakers in the system-audio track with locally running **WhisperX**, and attributes every transcript segment to a participant.
- Includes a persistent **Contacts** area; a detected voice can be named or linked to an existing contact directly from the meeting.
- Shows a scrollable near-real-time original-language transcript during recording, usually within 15–25 seconds, while keeping the final high-quality transcription pipeline independent.
- Temporarily mutes only your microphone while system audio keeps recording; muted intervals are written as silence to preserve timeline alignment.
- Lets you browse and edit previous meetings while recording, with persistent timer, microphone mute, and stop controls.
- Transcribes meetings containing **Portuguese, English, and German** in the same conversation.
- Detects language changes dynamically without replacing the original transcript.
- Shows on-demand translations in all three languages and validates the generated language.
- Generates summaries, decisions, key dates, and action items with owners and due dates.
- Lets you choose between the fully on-device Apple Intelligence model and the locally installed Claude Code CLI for each summary.
- Can regenerate a summary with either provider without retranscribing the meeting or rebuilding its translations.
- Lets you mark action items as completed and records their completion date.
- Lets you correct the meeting title, summary, decisions, dates, original transcript, and translations directly in the meeting detail.
- Supports inline editing and deletion of generated action items, including task, owner, and due date.
- Organizes meetings with tags, search, and filters.
- Exports meetings as Markdown.
- Reports whether microphone and system-audio signals were detected during capture.
- Checkpoints each meeting and preserves recovery audio before transcription begins.
- Resumes failed transcriptions from valid chunk checkpoints instead of starting over, and processes system audio and microphone serially to avoid local-model contention.
- Shows explicit **Retry with Local LLM** and **Retry with Claude** actions when a preserved recording needs to be processed again.
- Processes long meetings with bounded chunks and hierarchical summarization instead of sending the full transcript to one model context.
- Saves summaries and action items before starting potentially long translation work.
- Queues multiple meetings for background processing and shows separate progress for transcription, summary generation, and translations.
- Persists the processing queue so pending meetings resume in order after the app is reopened.

## Privacy

LocalMeet is designed to keep meeting content on your device:

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) handles transcription and language detection locally.
- [WhisperX](https://github.com/m-bain/whisperX) performs speaker diarization locally. Model files are fetched once and remain in the local Hugging Face cache.
- Apple Foundation Models generates translations and meeting analysis on-device when available.
- Claude is optional. When selected, LocalMeet invokes the user's existing local Claude Code installation and authentication in a tool-free, non-persistent session; the transcript is sent to Anthropic for processing.
- Audio is removed after successful transcription and speaker identification. If either step fails, both tracks are preserved locally so you can retry without losing the meeting.
- Transcripts are stored at `~/Library/Application Support/LocalMeet/meetings.json`.
- Failed recordings are kept under `~/Library/Application Support/LocalMeet/RecoveryAudio/` until a retry succeeds.
- No proprietary LocalMeet server is required. Speaker diarization needs a free Hugging Face account only to accept the model terms and download its weights; inference remains local.

> On first launch, the app downloads the multilingual whisper.cpp `small` model, which is approximately 466 MB. Transcription works offline after that.

## Installation

1. Download the DMG from the [Releases](https://github.com/LuizDoPc/LocalMeet/releases/latest) page.
2. Open it and drag **LocalMeet** into **Applications**.
3. Allow **Microphone** and **Screen & System Audio Recording** when prompted by macOS.
4. Select your input device on the welcome screen or in **Settings**.
5. To identify individual speakers, install WhisperX (`uv tool install whisperx`), accept the pyannote model terms, and save a Hugging Face read token in **Settings**.

The current build uses an ad hoc signature and is not notarized yet. If macOS blocks the first launch, right-click the app, choose **Open**, and confirm.

## Requirements

| Feature | Requirement |
| --- | --- |
| Audio capture and transcription | macOS 15 or later |
| Translation, summaries, and action items | macOS 26 with Apple Intelligence enabled |
| Optional Claude summaries | Claude Code installed and authenticated locally |
| Speaker identification | WhisperX, ffmpeg, and a Hugging Face read token for the first model download |
| Current DMG architecture | Apple Silicon |
| Building from source | Xcode 16+, Swift 6, and Homebrew |

## How it works

```text
System audio ──── ScreenCaptureKit ─┐
                                    ├─ independent temporary audio files
Microphone ────── AVFoundation ─────┘
                                                  │
                                                  ▼
                                    multilingual whisper.cpp
                                                  │
                              original transcript + shared timeline
                                                  │
                                                  ▼
                              on-device Apple Foundation Models
                         translation · summary · decisions · actions

                               or, for summary generation only
                                                  │
                                                  ▼
                             locally installed Claude Code CLI
                              summary · decisions · dates · actions

                         each meeting remains visible in a persistent
                          local queue with per-stage progress tracking
```

Both sources are transcribed independently and merged only after transcription using their timestamps. This keeps **You** and **Meeting** segments separate, including during overlapping speech.

While recording, LocalMeet closes short auxiliary windows for each source and sends them through one serialized local whisper.cpp queue. The recording screen keeps the resulting original-language captions in a scrollable timeline with optional auto-follow. These disposable windows never replace or modify the protected source recordings; the full retryable pipeline produces the definitive transcript after recording stops.

During a recording, use **Mute my microphone** or press `Shift-Command-M` for private side conversations. The system-audio track is unaffected, and unmuting resumes your microphone on the same timeline.

For summaries, choose **Local LLM** to keep the transcript entirely on-device or **Claude** to use the Claude Code installation already authenticated on your Mac. You can switch providers and select **Summarize again** at any time.

## Development

Install the native dependencies:

```bash
brew install whisper-cpp ggml libomp ffmpeg
brew install uv
uv tool install whisperx
```

Accept the terms for `pyannote/speaker-diarization-community-1`, create a read token in Hugging Face, and save it in **LocalMeet → Settings → WhisperX**. LocalMeet keeps that token in the macOS Keychain and only exposes it to the local WhisperX subprocess through its environment.

Build the project and run its tests:

```bash
swift build
swift test
```

Create the application bundle:

```bash
./scripts/build-app.sh
open dist/LocalMeet.app
```

Create a distributable DMG:

```bash
./scripts/build-dmg.sh
```

The build script embeds the whisper.cpp runtime in the `.app` and applies an ad hoc signature. For broader distribution, replace it with a Developer ID identity and notarize the app with Apple.

## Tech stack

- SwiftUI
- ScreenCaptureKit
- AVFoundation
- whisper.cpp (`small`, multilingual)
- WhisperX + pyannote (local speaker diarization)
- Apple Foundation Models
- Swift Testing

## Data and permissions

LocalMeet requests only the permissions required to capture both audio sources. If a recording does not include your voice, confirm the selected microphone in **Settings**. Each meeting's capture diagnostics show which input was used and whether a signal was detected.

---

<div align="center">
  Built for multilingual meetings — and to keep working when the internet does not.
</div>

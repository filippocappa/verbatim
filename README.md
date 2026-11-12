<div align="center">

<img src=".github/icon.png" width="128" height="128" alt="Verbatim app icon">

# Verbatim

**Talk anywhere on your Mac. The text lands where you're typing.**

A native macOS dictation app. Tap a key, speak in English or Italian, tap again,<br>
and clean text is pasted at your cursor. It also takes meeting notes without a bot joining the call.

[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white)](#requirements)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Version](https://img.shields.io/badge/version-0.1-blue)](project.yml)

</div>

---

## Features

- **Dictate into any app.** Double-tap right `⌘`, talk, tap right `⌘` again. The text is pasted where your cursor is. The left `⌘` stays free for normal shortcuts.
- **Cleaned to fit the app.** Filler words go, punctuation goes in. Each app gets its own tone (Formal, Normal, Casual, Exact or your own), so Slack and Mail don't read the same.
- **Commands.** Double-tap right `⌥` to rewrite the selected text, open apps and sites, search, or run your own saved commands ("bullets", "reply", "standup").
- **Fast.** Audio is compressed before upload, and long dictations are sent in parts at your natural pauses, so only the last bit is left when you stop.
- **Online or fully on your Mac.** Groq's Whisper by default. Download Parakeet or Whisper large v3 turbo in Settings to run speech on the Mac, as a backup or for everything.
- **Meeting notes, no bot.** Notices when Zoom, Meet, Teams, Webex, FaceTime, Slack or Discord starts a call and offers to take notes. It hears the call app and your mic as two sides, writes the transcript as it goes, and adds a recap (summary, decisions, action items, open questions) when the call ends.
- **Learns your words.** A Dictionary of names and terms, filled in by itself when you fix a word it got wrong.
- **Snippets.** Say "my email" and get your email.
- **History and Stats.** Every dictation with the app it went into and the engine that wrote it, plus words per minute, time saved and a few fun facts.
- **Pill or Notch.** Status shows as a small glass pill at the bottom of the screen, or drops down from the notch.

## Usage

| Action | How |
|---|---|
| Start dictating | Double-tap right `⌘` |
| Stop and paste | Tap right `⌘` |
| Cancel | `Esc` |
| Command | Double-tap right `⌥`, speak, tap right `⌥` |
| Take meeting notes | **Take Notes** on the call pill, or from the menu bar |
| Open Verbatim | Menu bar icon. Pages are `⌘1` to `⌘8`. |
| Settings | `⌘,` |

## Pages

| Page | What's there |
|---|---|
| **Home** | Today's words, time saved and your speaking speed |
| **Stats** | Words over time, speed, apps you dictate into, fun facts |
| **History** | Every dictation, searchable, with the app and engine |
| **Meetings** | Calls by day, with the recap and the transcript (You / Them) |
| **Dictionary** | Words and names it should always get right |
| **Snippets** | Short phrases that expand into longer text |
| **Style** | The tone for each app, with examples and editable instructions |
| **Commands** | Your saved commands and your own sites to open and search |

## Speech engines

| Engine | Where it runs | Notes |
|---|---|---|
| Groq, Whisper large v3 turbo | Online | Default. Needs a free Groq key. |
| Parakeet | This Mac | 630 MB download. About 0.1 s per sentence. |
| Whisper large v3 turbo | This Mac | 630 MB download. 1 to 3 s per sentence, uses your Dictionary as hints. |
| Apple speech | This Mac | Built in. Last resort when offline. |

**Settings → Speech → Speech goes to** picks *Groq first* (a local model takes over when you're offline or Groq is slow) or *Only this Mac* (your voice never leaves the Mac). Cleanup always uses Groq, text only.

## Install

Verbatim uses [XcodeGen](https://github.com/yonaskolb/XcodeGen), so the `.xcodeproj` isn't in the repo.

```bash
brew install xcodegen
git clone https://github.com/filippocappa/verbatim.git
cd verbatim
make install      # Release build into /Applications, then launch
```

`make run` builds and launches a Debug copy instead.

Add your [Groq](https://console.groq.com/keys) key in **Settings → Speech**. It's stored in the Keychain.

> [!IMPORTANT]
> On first launch Verbatim asks for **Microphone** and **Accessibility** (to paste and read the selection). Meeting notes also need **Screen & System Audio Recording**, only to hear the call app.

> [!TIP]
> Build with your **Apple Development** identity (set in `project.yml`). With ad-hoc signing, macOS treats every rebuild as a new app and asks for the permissions again.

### Requirements

- macOS 26 or later
- Xcode 27 / Swift 6
- A free Groq API key, or a local model downloaded in Settings

## How it works

```
right ⌘ ×2 ──▶ mic ──▶ compress ──▶ Groq Whisper ──▶ cleanup (Groq, tone per app) ──▶ paste
                          │              │
                          │              └─ slow or offline ─▶ Parakeet / Whisper on the Mac / Apple
                          └─ after 15 s, earlier parts are sent at each pause
```

1. **Listen.** The mic records while you talk. After 15 seconds, the audio so far is sent at your next pause, so the end goes faster.
2. **Transcribe.** Groq's Whisper gets the compressed audio. If it doesn't answer in 5 to 12 seconds, or there's no internet, a local engine takes over and the pill says so.
3. **Clean up.** The text goes to a Groq language model with the tone set for the app you're in and your Dictionary.
4. **Paste.** It's pasted at your cursor and saved to History.

Meetings use a Core Audio process tap to hear only the call app, plus the mic. Both sides are transcribed about every 25 seconds into a Markdown file in **Documents → Verbatim Meetings**. No audio is saved.

## Project structure

| Folder | Responsibility |
|---|---|
| `App/` | Entry point, menu bar and window setup |
| `Core/` | Dictation and meeting controllers, settings, stats, styles, permissions |
| `Engine/` | Hotkeys, recording, Groq, local speech, Apple speech, system audio tap, call detection, pasting |
| `UI/Main/` | The main window pages |
| `UI/Pill/` | The pill and the notch island |
| `UI/Settings/` · `UI/Onboarding/` · `UI/MenuBar/` | Settings, first launch, menu bar menu |
| `Resources/` | Info.plist, entitlements, app icon, start and stop sounds |

## Dependencies

- [FluidAudio](https://github.com/FluidInference/FluidAudio) for Parakeet on the Mac
- [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) for Whisper on the Mac

Everything else is Apple frameworks: AppKit, SwiftUI, AVFoundation, Core Audio and Speech.

## Changelog

What's changed, in plain words: [CHANGELOG.md](CHANGELOG.md).

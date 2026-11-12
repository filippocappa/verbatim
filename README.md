# Verbatim

A personal dictation app for macOS.

- Double-tap ⌘, speak in English or Italian, tap ⌘ again, and the text is pasted where you're typing.
- Double-tap ⌥ for commands: rewrite the selected text, open apps and sites, search, or run your own saved commands.
- Speech goes to Groq's Whisper and gets cleaned up to match the tone you set for each app. Offline, it uses Apple's speech engine on the Mac.
- Stats, History, a Dictionary that learns from your fixes, Snippets.

## Build

Needs Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
make run       # build and launch
make install   # release build into /Applications
```

Add your Groq key in Settings → Speech. It's stored in the Keychain.

What's changed: [CHANGELOG.md](CHANGELOG.md).

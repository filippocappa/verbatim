# What's changed

Newest first. Each entry says what changed and where to find it.



## 12 November 2026, speech models on this Mac

- **Settings → Speech → Engines: download a speech model to run on this Mac.**
  - *Parakeet* (630 MB, recommended): about a tenth of a second per sentence, English, Italian and 23 more.
  - *Whisper large v3 turbo* (630 MB): the model Groq runs, 1–3 s per sentence here, uses your Dictionary words as hints.
  - Each has Download (with progress), Use, and a bin to delete it and free the space. The first time after downloading it gets ready for the Mac's chip: under a minute for Parakeet, about 10 minutes for Whisper.
- **Speech goes to: Groq first, or Only this Mac.** With *Groq first*, a downloaded model replaces Apple's engine as the backup when you're offline or Groq is slow. With *Only this Mac*, your voice never leaves the Mac. Cleanup still uses Groq, text only.
- Meeting notes follow the same choice.
- The Meetings icon in the sidebar is now a camera, the same width as the others, so the names line up.
- History shows which engine wrote each dictation (Groq, Parakeet, Whisper or Apple), and the status under the app name says which local model is ready.
- The model loads while you talk and is unloaded after 10 idle minutes, so it doesn't take memory when you're not dictating.

## 12 November 2026, right-hand keys only

- **Only the right ⌘ and the right ⌥ start dictation and commands** (and stop them). The left keys are now free for normal shortcuts. Every hint in the app says "right ⌘" / "right ⌥".

## 12 November 2026, meetings

Meeting notes, without a bot joining the call. Built so far:
- **Hearing the call.** Verbatim can listen to just the meeting app (Zoom, Meet in a browser, Webex, Teams, FaceTime, Slack, Discord) plus your mic, as two separate sides.
- **Noticing calls.** When one of those apps starts using the mic, a pill asks "Zoom call · Take notes?". It stays until you answer it or the call ends, with a soft sound when it appears (a 12-second offer was too easy to miss). It doesn't ask again for the same call.
- **Meetings page** in the sidebar (⌘4). Every meeting, by day, with the app's icon, time and length. On the right: the recap (summary, decisions, action items you can tick, open questions) and the transcript with times and You / Them. Search, Copy Notes, Open in Editor, Show in Finder, Move to Trash. While a call is being written down it updates by itself. The toolbar has Take Notes / Stop. The other pages moved one number along (Dictionary is now ⌘5).
- Very short calls (under about 40 words) get "Too short for a recap" instead of a made-up summary.
- **Settings → General → Where it shows: Pill or Notch**, picked by clicking one of two small previews. Each shows a mini screen playing a dictation, then a call offer, where they'd really appear.
  - *Pill* (default): dictation at the bottom as before; call messages use the same glass pill but at the top, under the menu bar, so they don't cover the call's buttons.
  - *Notch*: everything, dictation included, drops down from the notch as a small black island.
- **The call's own logo**: a call in the browser shows the Meet / Teams / Webex / Zoom logo instead of Safari's or Chrome's, in the offer and on the Meetings page. The logos are fetched once and kept on the Mac.
- The offer is shorter: logo, "Google Meet", Take Notes, ✕.
- A Meet call in Safari is no longer mistaken for FaceTime. FaceTime only counts when the FaceTime app is open.
- **While taking notes:** the menu bar shows a record icon and the time. The menu has the "Taking notes" row with Stop, or "Take Notes" for a call it didn't notice.
- **Stops by itself** about 20 seconds after the call app lets go of the mic.
- If the call stays silent for 20 seconds, the pill says "Can't hear the call" with a button to the permission setting.

- **Notes, quick version.** While the call runs, both sides are written down every ~25 seconds into a file in **Documents → Verbatim Meetings**, as "You" and "Them" lines with times. When the call ends, a recap (summary, decisions, action items, open questions) goes on top, and the pill shows "Meeting notes ready" with Open.
- If the mic picks up the others through the speakers, those repeated lines are dropped.
- The call doesn't end while you're muted, as long as the call app is still playing sound.

No audio is saved.

## 12 November 2026, afternoon

- **No more long "Writing" when Groq is slow.** It used to wait up to 20 s for Groq, then try again for another 20 s before using the Mac (42 s once at 12:22). Now it waits 5 to 12 s depending on how long you talked, never tries twice, and the pill says "Groq is slow, using this Mac" while the Mac takes over.
- The project folder and the GitHub repo are now both called Verbatim (github.com/filippocappa/verbatim, private). The old Parla files went to the Trash.

## 12 November 2026, later

- **Commands:** the plain Write / Open and search switch is now a wide sliding switch, with a one-line description under each side.
- **Stats → Fun facts:** starts on a random fact each time, not always the book.
- **Settings (⌘,):** now a 16:9 window with a sidebar, like the main window. That also removes the big highlight box that showed over the tabs.
- **Settings → Speech → Engines:** shows what runs online (Groq, Whisper large v3 turbo) and offline (Apple's speech engine), and which one is in use.
- **Settings → Speech → Today on Groq's free plan:** the numbers now account for the steady refill (one cleanup back every ~1.5 min, one transcription every ~45 s) instead of assuming a reset.

## 12 November 2026

### Speed
- **It isn't live streaming.** It still waits for you to stop, but two things make it much faster:
  - **Smaller upload.** Audio is compressed before it goes to Groq (about 7 times smaller). On a 43-second clip, transcribing went from about 2 s to 0.7 s.
  - **Early parts.** After 15 seconds of talking, the audio so far is sent at your next natural pause, while you keep talking. When you stop, only the last part is left. In the same test, the last part took 0.44 s against 0.81 s for the whole clip, with the same text.
- History now shows the app you pasted into, not the one you were in when you started talking.

### Commands (sidebar → Commands)
- Two tabs: **Write** and **Open and search**.
- **Your commands.** Save a short name with your own instruction, for example "bullets" → "Turn it into a bullet list".
  - With text selected, it runs your instruction on the selection.
  - With nothing selected, it writes from what you say after the name and pastes it at your cursor ("standup finished login, working on stats").
  - Anything you say after the name is added just that once ("bullets, keep it to three").
  - Starters: bullets, tldr, reply, translate, standup.
- **Your sites.** Add a site it doesn't know (name and address). "open Linear" and "search Linear for …" then work. To search inside the site, search it for the word TEST and paste that address.

### Style (sidebar → Style)
- Cleanup is merged into Style; there's no separate Cleanup setting any more.
  - Formal = cleaned and smoothed.
  - Normal and the casual tones = cleaned.
  - Exact = the words as heard.
- A slider per app with an icon for each tone.
- **Examples written for each app.** The model guesses what you'd typically dictate in that app and writes it in every tone. A new app gets one a few seconds after you add it.
- **Edit Tones** (top right) shows what each tone tells the AI, and lets you change it. Reset puts back the original. The base cleanup instructions are at the bottom.
- **Custom** tone that follows instructions you write.
- Casual is now clearly different from Normal: it trims words, joins sentences with commas, and drops the final full stop.
- Formal no longer translates Italian into English.

### Stats (sidebar → Stats)
- The number tiles have small charts inside.
- **Fun facts** show one at a time. A bar fills over 7 seconds, then it moves on. It pauses while the pointer is over it. Click a bar to jump; click the book fact for another book.

### Snippets (sidebar → Snippets)
- Same tile look as the other pages.
- When empty, it shows starters (my email, my phone, my address, meeting link, sign off). Click one to fill the boxes.

### Settings (⌘,)
- Tabs with icons: General, Speech, Permissions. Each group sits in its own tile, with an icon on every row.
- All tabs are the same size, so switching no longer resizes the window (that was the flash).
- "Learn from my fixes" moved to General. The cleanup model is under Speech → Advanced.
- **Speech → Today on Groq's free plan.** Shows how many transcriptions and cleanups are left today and when they refill. The numbers update with every dictation; Check Now asks Groq again.

### Look
- Page titles use a serif font (New York). Easy to switch back.

## Groq's free plan, in short
- Per day: 2,000 transcriptions and 1,000 cleanups. A dictation uses up to 2 transcriptions and 1 cleanup.
- It doesn't reset at midnight. Each one you use comes back on its own, spread over 24 hours: a cleanup every ~86 s, a transcription every ~43 s.
- Per minute: about 8 dictations.
- When a limit is hit, speech falls back to Apple's engine on the Mac and text pastes without cleanup.

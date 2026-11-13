# What's changed

Newest first. Each entry says what changed and where to find it.

## 13 November 2026, the screen assistant, recordings, asking your meetings, and voices

- **Screenshots in the README.** Home, Meetings, Style and Stats, made from sample data. `make shots` makes them again without putting anything on screen.
- **Ask about what's on screen.** Double-tap right ⌥ with nothing selected and say what you want.
  - Ask for something to write ("reply saying Thursday at 10 works") and it's written at your cursor. It reads the screen, so the reply fits the conversation: same language, same names, about the same length.
  - Ask a question ("what does this error mean", "what does Marco want from me") and the answer shows in a small panel at the bottom of the screen. Esc or a click anywhere else closes it, and **Copy** copies it.
  - "Open" and "search" work as before. Questions that need the web right now, like the weather, still go to Google.
  - It reads the text of the front window. If Verbatim already has Screen Recording permission, it also sends a picture of that window. It never asks for that permission itself.
  - It uses Claude when you have a Claude key, Groq otherwise. With *Only this Mac* it uses Groq, like the other commands. In tests a reply took about 3.5 seconds and an answer about 3.
- **Translate as you dictate.** Double-tap the **right ⇧**, speak Italian and it pastes English, or speak English and it pastes Italian. Lists and line breaks are kept. Needs a Groq key. Listed in **Settings → General → Shortcuts**.
- **Transcribe a recording.** Drop an audio or video file on **Meetings**, or use the new **Transcribe a Recording** button. It becomes a meeting like any other: transcript, speakers told apart, recap. With Parakeet a one-minute video took 9 seconds.
- **Ask your meetings.** The **Ask** button on Meetings (the magnifying glass). Ask "what did we decide about pricing?" or "cosa ha detto Giulia sull'onboarding?" and Claude answers from your notes and transcripts, with links to the meetings it came from. If you have a lot of meetings, it first reads the recaps to pick which transcripts to read. Needs a Claude key, and it's off with *Only this Mac*.
- **Voices are remembered across meetings.** When you rename *Person 2* to *Sara*, or Meet's captions or the call name her, her voice is kept, and the next meeting says *Sara* by itself. Claude's guesses aren't learned, so a wrong guess can't spread.
  - In a test with the same voices in two different calls, the same voice scored 0.94 and different voices 0.17, so names only go on clear matches.
  - **Settings → Meetings → Voices** shows who it knows and lets you forget one voice or all of them. Voice prints are numbers, not audio. They stay on this Mac and aren't in backups.
- **Edit the transcript.** Hover a line and click the pencil, or right-click it, to fix what was heard. Right-click → **Said By** moves a line to another speaker, and **Delete Line** removes it.
- **Merge speakers.** When a call splits one person into two, click one of them and pick **Or the same person as**.
- **Words as you talk.** **Settings → Speech → Show words as you talk** (off by default). Your words appear in a dark card sitting right on top of the pill while you speak (under the notch in notch mode).
  - New words are grey. Once two reads in a row agree on a word it turns white, so the end of the sentence can still change while the start stays put.
  - "New line" breaks the line and "bullet point" starts a list as you say them. A "send" at the end shows as ↵.
  - Nothing goes into the app while you talk. When you stop, the cleaned-up text is pasted as usual and the card goes away.
  - For commands and translations the words show in the pill itself.
  - It needs Parakeet, which is loaded the moment you start talking, so the first words don't wait for it. It re-reads about five times a second, and each read takes about a tenth of a second. Long dictations stay that fast because it only re-reads what you've said since the last pause.
- **No more 40-second waits when the internet is bad.** The time limit on Groq and Claude only counted silence, so on a broken Wi-Fi a dictation could wait half a minute before giving up. Now it's a hard limit: with Parakeet downloaded, Groq gets about 2.5 seconds, then your Mac takes over, and the Mac's cleanup gets ready while it waits. That dictation would now take about 3 seconds.
- **"Send" after a comma always counts.** "Let me know what works for you, send" now presses Return. Before, the "you" right before it made it look like part of the sentence.

## 12 November 2026, formatting by voice, "send", export and backup

- **Format as you talk.** Say "new line", "new paragraph", "bullet", "comma", "full stop" or "question mark" and you get the real thing. Italian works too: "a capo", "nuovo paragrafo", "punto elenco", "virgola", "punto interrogativo". When you're talking *about* them ("add a new line to the file", "a missing comma"), they stay as words.
- **Say "send" at the end** (or "invia") and it presses Return after pasting, so a Slack or WhatsApp message goes without touching the keyboard. Not when it's part of the sentence ("I'll send", "te lo invia"). Turn it off in **Settings → General → Say “send” to send**.
- **Meetings can start by themselves.** **Settings → Meetings → Take notes by itself** (off by default) starts the notes as soon as a call is noticed, without the Take Notes button. The offer to take notes has its own switch there too.
- **Export a meeting** as Markdown, plain text or PDF, from the **Export** button on a meeting.
- **Backup and restore** in **Settings → General → Backup**. One zip with your meetings, history, Dictionary, snippets, styles and commands. API keys aren't in it. Restoring adds what's missing and deletes nothing, and puts your settings back as they were in the backup.

## 12 November 2026, better meeting transcripts and names

- **Meetings now use Parakeet on this Mac** when it's downloaded, instead of Groq. We tested both on three recorded meetings (English, Italian, a business call). Parakeet got more words right (12–16% wrong against 14–28% for Groq) and was about 5 times faster. The audio doesn't leave the Mac. If Parakeet fails on a piece, Groq does it.
- **Names are spelled right more often.**
  - Parakeet now listens for the names in your Dictionary and checks them against the audio. The first time, a small model is downloaded for this (about 100 MB).
  - **Settings → Meetings → Names from Calendar** (off by default). It reads who's invited to the call from Calendar and adds their names too. It asks for Calendar access when you turn it on.
  - **In Google Meet, the names on the video tiles are read too**, every 10 seconds, so people who join late count. Nothing to turn on. Your own name is left out.
  - **With only one other person on the call, the transcript uses their name** instead of *Them*.
- **Google Meet: turn on captions (the CC button) and the transcript says who said what, by name**, instead of *Person 1*, *Person 2*. Verbatim doesn't use Meet's text, only whose captions are moving at each moment. Captions are only shown to you. In a test with three voices, every sentence got the right name.
  - In the test call, it fixed all 4 people's names that Parakeet had got wrong before (for example "Randy Givens" → "Randy Giveans"), without changing other words.
- **Claude fixes names after the call.** Paste an Anthropic key in **Settings → Meetings → Claude**. When the call ends, Claude reads the transcript and fixes misheard names of people, companies and products, before the recap is written. It sends the transcript to Anthropic, so it's off with *Only this Mac*. About $0.10 for an hour of call.
- **Claude also works out who Person 1, Person 2… are**, from what people say ("thanks Marco", "Sara, can you…") and the names in the call. Only when it's clear; otherwise the label stays and you can still click it to rename. Same request as the name fixes, so no extra cost.
- **Settings has a Meetings page** with what transcribes your calls, the Calendar switch and the Claude key.

## 12 November 2026, Apple Intelligence and voices in meetings

- **Cleanup on this Mac.** When Groq can't clean up the text (offline, out of free requests, slow, or with *Only this Mac*), Apple Intelligence on the Mac does it instead. Before, the text was pasted as heard.
  - It's lighter than Groq: punctuation, capitals and filler words go, your words stay as they are. Tones, Dictionary hints and "no wait" corrections are Groq only. In tests, the small model got those wrong and sometimes changed the meaning.
  - About a second per dictation. It loads while you talk.
- **Only this Mac now means everything.** Speech, cleanup and meeting recaps all stay on the Mac. Commands (right ⌥) still use Groq.
- **Settings → Speech → Engines** has an Apple Intelligence row: Backup, In use, or Off with the reason (for example, if Apple Intelligence is turned off in System Settings).
- **Meetings: who said what.** When the call ends, the voices on the other side are told apart and the transcript says *Person 1*, *Person 2*… instead of *Them*. With only one other person it stays *Them*. The speaker models are downloaded the first time (about 30 MB).
  - **Click a name in the transcript** to say who it is. It's changed everywhere in that meeting, recap included.
  - During the call, the other side's audio is kept in a temporary file for this and deleted as soon as the notes are written.
- **Meeting recaps on this Mac.** With *Only this Mac*, or when Groq fails, Apple Intelligence writes the recap. It's plainer than Groq's but stays on the Mac.
- The transcript now goes sentence by sentence, so you and the others interleave properly instead of in 25-second blocks.
- **Fixed: meeting transcripts with holes.** About one piece in ten sent to Groq came back as a few Dictionary words instead of what was said, so up to 25 seconds went missing. Now that piece is asked again without the Dictionary words.

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

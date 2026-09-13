# J.A.R.V.I.S. — Windows Desktop Assistant

A zero-install JARVIS-style assistant for Windows: an iron-man-style chat HUD that
talks to AI models through **OpenRouter**, and executes local commands like opening
apps and websites, searching, volume control, and locking the PC.

Built with pure PowerShell + WPF — **nothing to install** on Windows 10/11.

## Quick start

1. Double-click **`Start Jarvis.bat`**
   (or run: `powershell -NoProfile -STA -ExecutionPolicy Bypass -File Jarvis.ps1`)
2. Click **API Key** (top-right) and paste your OpenRouter key.
   Get a free one at **https://openrouter.ai/keys** — many models have free tiers.
3. Chat away. Try `help` to see everything it can do locally.

## What it can do

**Local commands** (instant, no AI involved):

| Say this | Result |
|---|---|
| `open <anything>` | launches **any installed app** — JARVIS scans your Start Menu (plus Store apps) on startup, so `open spotify`, `open valorant`, `open whatsapp` all work |
| `list apps` | browse everything it can launch · `list apps <name>` to search |
| `rescan apps` | re-scan installed apps (after installing something new) |
| `open youtube` / `open github` / `open example.com` | opens the site in your browser |
| `close chrome` | politely closes the app |
| `search quantum computing` | Google search (also `youtube …`, `bing …`, `wikipedia …`, `github …`) |
| `play lofi beats on youtube` | YouTube search |
| `volume up` / `volume down` / `mute` | media keys |
| `lock` | locks the workstation |
| `screenshot` | saves a PNG to your Pictures folder |
| `battery` / `my ip` / `what time is it` / `what's the date` | quick info |
| `switch model to anthropic/claude-3.5-haiku` | change AI model on the fly |
| `clear` / `help` | housekeeping |

Anything that isn't a local command goes to the AI, with a JARVIS personality.

## Changing the model

- Type `switch model to <model-id>` in chat, or
- Use the model dropdown in the top bar / Settings panel (auto-populated from OpenRouter's model catalog).

Popular cheap/fast picks: `openai/gpt-4o-mini`, `anthropic/claude-3.5-haiku`,
`google/gemini-2.0-flash-001`, `deepseek/deepseek-chat`.

## Where your key lives

`%APPDATA%\Jarvis\config.json` — local only, saved after OpenRouter verifies it
(the app calls `GET /api/v1/key` to validate before storing).

## Files

- `Jarvis.ps1` — the entire app (UI, command engine, OpenRouter client)
- `Start Jarvis.bat` — double-click launcher

## Self-tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File Jarvis.ps1 -SelfTest   # intent parser tests
powershell -NoProfile -STA -ExecutionPolicy Bypass -File Jarvis.ps1 -XamlTest  # UI markup test
powershell -NoProfile -STA -ExecutionPolicy Bypass -File Jarvis.ps1 -VoiceTest # mic + TTS probe (say something!)
```

## Settings (click **API Key** in the top bar)

- **OpenRouter API key** — for AI chat
- **Model** — any OpenRouter model
- **Start JARVIS automatically when Windows starts** — adds itself to your user's autostart (HKCU Run key, no admin needed)
- **Wake word** — say *"hey Jarvis"* any time and the window comes to the front, ready for your command

Everything applies immediately on **Save**.

## Tray & closing behavior

Closing the window **minimizes JARVIS to the system tray** — it keeps running and listening. To really quit: right-click the tray icon → **Exit**. Double-click (or left-click) the tray icon to bring it back, and so does saying *"hey Jarvis"*.

Start hidden to tray on boot: launch with `powershell -NoProfile -STA -ExecutionPolicy Bypass -File Jarvis.ps1 -Tray`

## Notes

- **Voice input is hybrid** for accuracy: a precision command grammar built from *your* app names + known commands is tried first (this recognizes "open spotify"-style phrases very reliably), with free dictation as fallback for anything else. All offline.
- **Male voice replies**: JARVIS speaks command confirmations out loud via **Microsoft David** (the male Windows voice), or the first male voice installed.
- Because it's PowerShell, smart antivirus may prompt once on first run; it's a plain-text script — read it, then allow it.

# Sendpoint

A macOS menu bar app for making voice notes while you read.

Select a passage in any app, press `⌥⌘`, and say what you are thinking:
what you don't follow, what seems off, or what you want checked. Hold the
shortcut while you talk and release it to save, or tap it once to start and
again to save. Keep reading. Each note is stamped with where you were. When
you reach the end, one shortcut turns the whole train of thought into a prompt
and pastes it into whatever model you're talking to, so it answers your
reasoning and not just your question.

For a typed note, press `⌃⌘A` to capture the selection and open the note box.
Voice notes and typed notes both require Accessibility. Voice notes also need
Input Monitoring, Microphone access, and the local voice model. Input Monitoring
lets Sendpoint recognize `⌥⌘` while another app is active. The model downloads
on first voice use or when you choose to set it up explicitly.

It works on anything you can select: LLM output, docs, papers, code, or a draft
of your own.

Requires macOS 14 or later on Apple Silicon.

## Install

Download the latest zip from [Releases](../../releases), unzip it, and drag
**Sendpoint** into `/Applications`. Open it and look for the
speech-bubble icon in the menu bar.

The current builds are ad-hoc signed and are not notarized by Apple. On the
first launch, macOS may block the app. Try to open it once, then open **System
Settings > Privacy & Security**, scroll to **Security**, click **Open Anyway**,
and confirm **Open**. Only do this if you trust this repository.

The setup assistant asks for:

- **Accessibility.** Required. It reads your selection and sends the paste
  keystroke.
- **Input Monitoring.** Required for voice notes. It lets Sendpoint recognize
  the modifier-only `⌥⌘` shortcut in any app.
- **Microphone and a voice model.** Required for voice notes. The local model
  downloads on first voice use or during explicit setup. It is a one-time
  460 MB download. Transcription runs on your Mac and audio never leaves it.

The first time you capture from a browser, macOS asks whether the app may
control it. Allowing it lets notes record the tab's title and URL.

## Shortcuts

| Key      | Action                                                            |
| -------- | ----------------------------------------------------------------- |
| `⌥⌘`     | Voice note: hold to talk and release to save, or tap twice       |
| `⌃⌘A`    | Typed note: capture the selection and open the note box           |
| `⌘↩`     | Save the typed note and close the box                             |
| `⎋`      | Discard the typed note                                            |
| `⌃⌘V`    | Paste the stack as Markdown into the current app                  |
| `⌃⌘S`    | Open the stack window                                             |
| `⌃⌘K`    | Switch session                                                    |
| `⌃⌘⌫`    | Clear the current session                                         |
| `⌘Z`     | Undo the last clear in the stack window                           |

The voice shortcut is fixed at `⌥⌘`. The five key-based global shortcuts are
rebindable in Settings. The typed note save and discard keys belong to the note
box; `⌘Z` belongs to the stack window.

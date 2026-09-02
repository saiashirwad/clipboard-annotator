# Sendpoint

A macOS menu bar app for thinking out loud while you read.

Select a passage in any app, press a shortcut, and say or type what you are
thinking: what you don't follow, what seems off, what you want checked. Keep
reading. Each note is stamped with where you were. When you reach the end, one
shortcut turns the whole train of thought into a prompt and pastes it into
whatever model you're talking to, so it answers your reasoning and not just
your question.

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
- **Microphone and a voice model.** Only for voice notes. The model is a
  one-time 460 MB download. Transcription runs on your Mac and audio never
  leaves it.

The first time you capture from a browser, macOS asks whether the app may
control it. Allowing it lets notes record the tab's title and URL.

## Shortcuts

| Key   | Action                                             |
| ----- | -------------------------------------------------- |
| `⌃⌘A` | Capture the selection and open the note box        |
| `⌃⌘E` | Hold to record a voice annotation; release to save |
| `⌘↩`  | Save the note, close the box                       |
| `⎋`   | Discard the note                                   |
| `⌃⌘V` | Paste the stack as Markdown into the current app   |
| `⌃⌘S` | Open the stack window                              |
| `⌃⌘⌫` | Clear the stack                                    |
| `⌘Z`  | Undo the last clear                                |

All six global shortcuts are rebindable in Settings.

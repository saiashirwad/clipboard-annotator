# Clipboard Annotator

A macOS menu bar app. Select text in any app, press a shortcut, write a note
about it. Notes collect in a stack. Paste the stack anywhere as Markdown.

Requires macOS 14 or later on Apple Silicon.

## Install

Download the latest `ClipboardAnnotator-<version>.zip` from
[Releases](../../releases), unzip it, and drag **Clipboard Annotator** into
`/Applications`. Open it and look for the speech-bubble icon in the menu bar.

On first launch the setup assistant walks through:

- **Accessibility**, in System Settings → Privacy & Security → Accessibility.
  Required. It reads the selection in other apps and sends the paste
  keystroke. Nothing works without it.
- **Microphone**, only if you want voice annotations.
- **Voice model**, only if you want voice annotations. Transcription runs on
  your Mac with [FluidAudio](https://github.com/FluidInference/FluidAudio) and
  the Parakeet model. The model is a one-time 460 MB download from Hugging
  Face into `~/Library/Application Support/FluidAudio`. After that, audio and
  transcription never leave your Mac.

When you capture from a browser, macOS asks once per browser whether
Clipboard Annotator may control it. Allowing it lets a note record the tab's
title and URL. Declining only loses that detail.

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

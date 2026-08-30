# Clipboard Annotator

A macOS menu bar app. Select text in any app, press a shortcut, write a note
about it. Notes collect in a stack. Paste the stack anywhere as Markdown.

## Shortcuts

| Key   | Action                                           |
| ----- | ------------------------------------------------ |
| `⌃⌘A` | Capture the selection and open the note box      |
| `⌘↩`  | Save the note, close the box                     |
| `⎋`   | Discard the note                                 |
| `⌃⌘V` | Paste the stack as Markdown into the current app |
| `⌃⌘S` | Open the stack window                            |
| `⌃⌘⌫` | Clear the stack                                  |
| `⌘Z`  | Undo the last clear                              |

The four global shortcuts are rebindable in Settings.

## Build and install

```sh
./build.sh     # builds dist/Clipboard Annotator.app
./install.sh   # copies it to /Applications and launches it
```

Requires macOS 14 or later.

`build.sh` signs with an Apple Development certificate if one exists, which keeps
the Accessibility grant across rebuilds. Set `CODESIGN_IDENTITY` to choose a
different one. With no certificate it signs ad-hoc, and macOS asks for
Accessibility again after every build.

## Permissions

**Accessibility**, in System Settings → Privacy & Security → Accessibility.
Required to read selections in other apps and to send the synthetic keystrokes.
Nothing works without it.

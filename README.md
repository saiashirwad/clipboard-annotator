# Clipboard Annotator

A macOS menu bar app. Select text in any app, press a shortcut, write a note
about it. Notes collect in a stack. Paste the stack anywhere as Markdown.

## Shortcuts

| Key   | Action                                           |
| ----- | ------------------------------------------------ |
| `⌃⌘A` | Capture the selection and open the note box      |
| `⌃⌘E` | Hold to record a voice annotation; release to save |
| `⌘↩`  | Save the note, close the box                     |
| `⎋`   | Discard the note                                 |
| `⌃⌘V` | Paste the stack as Markdown into the current app |
| `⌃⌘S` | Open the stack window                            |
| `⌃⌘⌫` | Clear the stack                                  |
| `⌘Z`  | Undo the last clear                              |

All six global shortcuts are rebindable in Settings.

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

## Running a downloaded build

The build attached to a release is signed, but signed is not the same as
distributable. It uses an Apple Development certificate rather than a Developer
ID, and it is not notarized, so Gatekeeper blocks it:

```
$ spctl -a -t exec -vv "Clipboard Annotator.app"
Clipboard Annotator.app: rejected
```

Strip the quarantine flag to run it anyway:

```sh
xattr -dr com.apple.quarantine "/Applications/Clipboard Annotator.app"
```

Building from source avoids this, because a locally built app is never
quarantined.

Opening normally would need a paid Apple Developer Program membership, a
**Developer ID Application** certificate, and notarization with `notarytool`.
`build.sh` already prefers a Developer ID certificate over a Development one, so
only the notarize-and-staple step would be missing.

## Permissions

**Accessibility**, in System Settings → Privacy & Security → Accessibility.
Required to read selections in other apps and to send the synthetic keystrokes.
Nothing works without it.

**Microphone**, when you first use the voice shortcut. Voice annotations use
FluidAudio, the local transcription engine used by Hex. The first voice
annotation downloads its Parakeet model. You can download it first in Settings.
Audio and transcription stay on your Mac.

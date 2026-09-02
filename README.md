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

## Where things live

| What               | Where                                                                                           |
| ------------------ | ----------------------------------------------------------------------------------------------- |
| Notes and sessions | `~/Library/Application Support/ClipboardAnnotator`                                              |
| Diagnostic log     | `~/Library/Application Support/ClipboardAnnotator/debug.log` (capped, never contains note text) |
| Voice model        | `~/Library/Application Support/FluidAudio`                                                      |
| Settings           | `~/Library/Preferences/com.texoport.ClipboardAnnotator.plist`                                   |

To uninstall, quit the app, delete it from `/Applications`, delete the folders
above, and remove it from the Accessibility list in System Settings.

## Build from source

```sh
./build.sh     # builds dist/Clipboard Annotator.app
./install.sh   # copies it to /Applications and launches it
```

`build.sh` signs with a Developer ID certificate if one is in the keychain,
otherwise an Apple Development certificate, otherwise ad-hoc. A stable
identity keeps the Accessibility grant across rebuilds; with ad-hoc signing
macOS asks again after every build. Set `CODESIGN_IDENTITY` to pick one.

Every build uses the hardened runtime and the entitlements in
`Resources/ClipboardAnnotator.entitlements`, so a local build behaves exactly
like a released one.

The app icon comes from `Resources/AppIcon.svg`. Edit it, or hand
`scripts/make-icon.sh` any 1024×1024 PNG, to regenerate `AppIcon.icns`.

## Cut a release

```sh
./release.sh 1.2            # build, notarize, staple, zip into dist/
./release.sh 1.2 --publish  # ...then tag v1.2 and create the GitHub release
```

This needs a paid Apple Developer account with a **Developer ID Application**
certificate in the keychain, and notarization credentials stored once:

```sh
xcrun notarytool store-credentials clipboard-annotator \
    --apple-id you@example.com --team-id TEAMID
```

Without notarization, a downloaded build is blocked by Gatekeeper. Anyone who
trusts you can still run it by stripping the quarantine flag:

```sh
xattr -dr com.apple.quarantine "/Applications/Clipboard Annotator.app"
```

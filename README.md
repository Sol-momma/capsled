# capsled

[日本語](README.ja.md) | English

`capsled` turns the physical Caps Lock LED into a reusable indicator without
changing the logical Caps Lock state. It is designed for macOS users who remap
the physical Caps Lock key to Control but still want to use its LED.

## Quick start

Choose the behavior you want and start with one of these two paths.

### 1. Toggle the LED with the physical Caps Lock key

Install the CLI with Homebrew, then start the watcher:

```sh
brew install Sol-momma/tap/capsled
capsled watch
```

Press the physical Caps Lock key to toggle the LED. Stop the watcher with
Control-C; capsled then returns LED control to macOS.

The first run may require **System Settings > Privacy & Security > Input
Monitoring** permission for `capsled`. Enable it, then run `capsled watch` again.
The watcher observes the raw physical key without changing or suppressing the
key event.

### 2. Control the LED from the menu bar

Download `capsled-menu-bar-macos-universal.zip` from the
[latest release](https://github.com/Sol-momma/capsled/releases/latest), unzip it,
and move `CapsLED.app` to Applications. Open the Caps Lock icon in the menu bar
and choose **Keep LED On**, **Turn LED Off**, or **Return Control to macOS**.

CapsLED is currently ad-hoc signed rather than Developer ID signed and
notarized. On first launch, Control-click `CapsLED.app`, choose **Open**, then
confirm **Open**.

These instructions require capsled v0.2.0 or later. If an existing Homebrew
installation does not recognize `watch`, update it with:

```sh
brew update
brew upgrade Sol-momma/tap/capsled
```

## Requirements

- macOS 14 or newer
- A keyboard whose Caps Lock LED is exposed through macOS's HID event system
- No root privileges or Accessibility permission
- Input Monitoring permission only for `watch`; the other commands and the
  menu-bar controls do not require it

## Other CLI commands

`watch` is the normal starting point. The remaining commands support fixed LED
states and process-running indicators:

| Command | Purpose |
| --- | --- |
| `capsled on` | Keep the LED on in the background. |
| `capsled off` | Stop forced-on mode and write the LED state to Off once. |
| `capsled auto` | Stop capsled control and return the LED to macOS. |
| `capsled run -- <command>` | Keep the LED on while a command runs, then return it to macOS. |

For example:

```sh
capsled run -- npm test
```

The wrapped command's exit status is preserved. `on`, `run`, and `watch`
replace each other rather than restoring a previous mode afterward.

## Troubleshooting

- **`watch` asks for permission:** Enable `capsled` in **System Settings >
  Privacy & Security > Input Monitoring**, then run it again.
- **The LED remains forced after a crash or power loss:** Run `capsled auto`.
- **`watch` is not recognized:** Run the Homebrew update commands shown in
  Quick start and confirm that `capsled --help` lists `watch`.
- **CapsLED.app will not open:** Control-click the app and choose **Open** for
  the first launch.

## Update and uninstall

For the Homebrew CLI:

```sh
brew upgrade Sol-momma/tap/capsled
capsled auto
brew uninstall Sol-momma/tap/capsled
```

For the menu-bar app, choose **Return Control to macOS**, quit CapsLED, then
remove `CapsLED.app` from Applications.

Users who need a standalone CLI installation can follow
[Advanced installation](docs/advanced-installation.md).

## Compatibility and limitations

| Environment | Keyboard | Result |
| --- | --- | --- |
| Apple Silicon, macOS 26.5.1 | Built-in, Caps Lock remapped to Control | LED control and raw `watch` toggle verified |
| Intel Mac | Built-in | Universal Binary builds; hardware not verified |
| External keyboards | Varies | Not verified |

- Raw physical-key detection used by `watch` is experimental and has been
  verified only on the built-in Apple Silicon keyboard listed above.
- When no built-in keyboard can be identified, capsled falls back to every
  keyboard service. This may light an attached keyboard as well.
- capsled uses the unsupported `HIDCapsLockLED` event-system property from
  Apple's IOHIDFamily implementation. It may stop working in a future macOS
  release.
- `on`, `run`, and the On state of `watch` check the effective LED state every
  10 ms. A macOS overwrite can still produce a very short dark interval.
- SIGKILL, a crash, or power loss can prevent automatic cleanup. Run
  `capsled auto` to recover.
- The menu status reports the last action completed in the app. Later CLI
  changes are not continuously mirrored in that status.
- Release binaries are ad-hoc signed, not Developer ID signed or notarized.

## Contributing

Build instructions and hardware-safe checks are in
[CONTRIBUTING.md](CONTRIBUTING.md). Security reports are described in
[SECURITY.md](SECURITY.md). Issues and pull requests are welcome.

## License

[MIT](LICENSE)

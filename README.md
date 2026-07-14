# capsled

[日本語](README.ja.md) | English

`capsled` is an experimental macOS CLI that turns the physical Caps Lock LED
into a process-running indicator without changing the logical Caps Lock state.
It is useful when the physical Caps Lock key is remapped to Control but its LED
would otherwise be unused.

## Requirements

- macOS 14 or newer
- A keyboard whose Caps Lock LED is exposed through macOS's HID event system
- No root privileges or Accessibility permission
- Input Monitoring permission is required only for the experimental `watch`
  command; `on`, `off`, `auto`, and `run` do not require it

## Install

### Homebrew

If you already use Homebrew, install with:

```sh
brew install Sol-momma/tap/capsled
```

This provides Homebrew-managed upgrades and removal without installing Swift or
Xcode as a dependency.

### Smallest footprint

For the smallest footprint—or if Homebrew is not installed—use the standalone
installer. It downloads the latest Universal Binary (Apple Silicon + Intel),
verifies its SHA-256 checksum, places it in `~/.local/bin`, and removes the
temporary download. Only the approximately 289 KiB executable remains:

```sh
curl -fsSL https://raw.githubusercontent.com/Sol-momma/capsled/main/install.sh | sh
```

For a system-wide or custom location, inspect `install.sh` first and then set
`CAPSLED_INSTALL_DIR`, for example:

```sh
CAPSLED_INSTALL_DIR=/usr/local/bin sh install.sh
```

Make sure the install directory is on your `PATH`. For the default zsh on
macOS, add the following once and open a new terminal:

```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
```

Writing to a system directory such as `/usr/local/bin` may require administrator
permission. Running `capsled` itself does not require root privileges.

## Usage

```sh
capsled on
capsled off
capsled auto
capsled run -- npm test
capsled watch
```

- `on` starts one background maintainer and returns. It repairs a macOS `Off`
  overwrite until `off`, `auto`, or `run` stops it.
- `off` stops that maintainer and performs one `Off` write. macOS may overwrite
  the shared value on a later keyboard-state update.
- `auto` stops that maintainer and returns LED control to macOS.
- `run` keeps the LED on while the child command runs, repairs a macOS `Off`
  overwrite, then returns the LED to `auto`. It replaces a prior persistent
  `on` rather than restoring it after the child exits.
- `watch` preserves the current LED state until the first physical Caps Lock
  press, toggles it on each press, and returns the LED to `auto` when stopped.
  It also replaces a prior persistent `on` rather than restoring it on exit.
  It reads the raw Caps Lock HID usage instead of a transformed Control key
  code so the two can be distinguished on supported hardware; it does not alter
  or suppress either key event. Raw detection remains experimental.

For example:

```sh
capsled run -- sleep 30
```

The wrapped command's exit status is preserved.

To use the experimental watcher, run it in the foreground and stop it with
Control-C:

```sh
capsled watch
```

On first use, macOS may ask for Input Monitoring access. Enable the executable
in **System Settings > Privacy & Security > Input Monitoring**, then run the
command again. This permission is necessary even though the watcher accepts
only Caps Lock input values and opens the keyboard non-exclusively.

## Update and uninstall

With Homebrew:

```sh
brew upgrade Sol-momma/tap/capsled
capsled auto
brew uninstall Sol-momma/tap/capsled
```

With the standalone installer, run it again to update. To uninstall, first
restore automatic LED control, then remove the executable:

```sh
capsled auto
rm "$HOME/.local/bin/capsled" # Replace this path if a custom directory was used.
```

## Compatibility

| Environment | Keyboard | Result |
| --- | --- | --- |
| Apple Silicon, macOS 26.5.1 | Built-in, Caps Lock remapped to Control | LED control and raw `watch` toggle verified |
| Intel Mac | Built-in | Universal Binary builds; hardware not verified |
| External keyboards | Varies | Not verified |

When no built-in keyboard can be identified, `capsled` falls back to every
keyboard service. This may light an attached keyboard as well.

Raw physical-key detection used by `watch` is still experimental. It has been
verified only on the built-in Apple Silicon keyboard listed above; other
hardware remains unverified.

## Important limitations

- This project uses the unsupported `HIDCapsLockLED` event-system property from
  Apple's IOHIDFamily implementation. It may stop working in a future macOS
  release.
- `on`, `run`, and the On state of `watch` check the effective LED state every
  10 ms.
  A macOS overwrite can still produce a very short dark interval before it is
  repaired.
- The background `on` maintainer, `run`, and `watch` cannot restore `auto` after
  SIGKILL, a crash, or power loss. Run `capsled auto` to recover.
- Release binaries are ad-hoc signed but are not Developer ID signed or
  notarized. macOS may show a security warning depending on how they are
  downloaded.

## Build from source

Requires Swift 6:

```sh
swift build -c release
.build/release/capsled --help
```

Build and package the Universal Binary:

```sh
scripts/build-release.sh
```

The checks below do not touch hardware:

```sh
swiftc Sources/CapsLEDCore/Command.swift Checks/CommandParserCheck.swift \
  -o .build/capsled-parser-check
.build/capsled-parser-check

swiftc Sources/CapsLEDCore/*.swift Checks/OnPersistenceCheck.swift \
  -o .build/capsled-on-persistence-check
.build/capsled-on-persistence-check
```

The watch lifecycle check also uses fake keyboard and LED backends and does not
touch hardware:

```sh
swiftc Sources/CapsLEDCore/*.swift Checks/WatchBehaviorCheck.swift \
  -o .build/capsled-watch-behavior-check
.build/capsled-watch-behavior-check
```

Security reports are described in [SECURITY.md](SECURITY.md). Contributions are
welcome through GitHub Issues and pull requests.

## License

[MIT](LICENSE)

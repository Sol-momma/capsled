# capsled

[日本語](README.ja.md) | English

`capsled` is an experimental macOS CLI that turns the physical Caps Lock LED
into a process-running indicator without changing the logical Caps Lock state.
It is useful when the physical Caps Lock key is remapped to Control but its LED
would otherwise be unused.

## Requirements

- macOS 14 or newer
- A keyboard whose Caps Lock LED is exposed through macOS's HID event system
- No root privileges, Accessibility permission, or Input Monitoring permission

## Install

The installer downloads the latest Universal Binary (Apple Silicon + Intel),
verifies its SHA-256 checksum, and places it in `~/.local/bin`:

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
```

- `on` and `off` perform one LED write. macOS may overwrite that shared value
  on a later keyboard-state update.
- `auto` returns LED control to macOS.
- `run` keeps the LED on while the child command runs, repairs a macOS `Off`
  overwrite, then returns the LED to `auto`.

For example:

```sh
capsled run -- sleep 30
```

The wrapped command's exit status is preserved.

## Update and uninstall

Run the installer again to update. To uninstall, first restore automatic LED
control, then remove the executable:

```sh
capsled auto
rm "$HOME/.local/bin/capsled" # Replace this path if a custom directory was used.
```

## Compatibility

| Environment | Keyboard | Result |
| --- | --- | --- |
| Apple Silicon, macOS 26.5.1 | Built-in, Caps Lock remapped to Control | Verified |
| Intel Mac | Built-in | Universal Binary builds; hardware not verified |
| External keyboards | Varies | Not verified |

When no built-in keyboard can be identified, `capsled` falls back to every
keyboard service. This may light an attached keyboard as well.

## Important limitations

- This project uses the unsupported `HIDCapsLockLED` event-system property from
  Apple's IOHIDFamily implementation. It may stop working in a future macOS
  release.
- `run` checks the effective LED state every 10 ms. A macOS overwrite can still
  produce a very short dark interval before it is repaired.
- `run` cannot restore `auto` after SIGKILL, a crash, or power loss. Run
  `capsled auto` to recover.
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

The parser check does not touch hardware:

```sh
swiftc Sources/CapsLEDCore/Command.swift Checks/CommandParserCheck.swift \
  -o .build/capsled-parser-check
.build/capsled-parser-check
```

Security reports are described in [SECURITY.md](SECURITY.md). Contributions are
welcome through GitHub Issues and pull requests.

## License

[MIT](LICENSE)

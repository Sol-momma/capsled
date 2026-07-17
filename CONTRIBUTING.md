# Contributing to capsled

Thank you for helping improve capsled. Bug reports, hardware compatibility
results, documentation fixes, and focused pull requests are welcome.

## Development requirements

- macOS 14 or newer
- Swift 6
- Hardware access is not required for the checks below

## Build

Build only the product you are changing.

CLI:

```sh
swift build -c release --product capsled
.build/release/capsled --help
```

Menu-bar executable:

```sh
swift build -c release --product CapsLEDMenuBar
.build/release/CapsLEDMenuBar
```

## Verify changes

These checks use parsers or fake keyboard and LED backends; they do not change
physical keyboard state.

```sh
swiftc Sources/CapsLEDCore/Command.swift Checks/CommandParserCheck.swift \
  -o .build/capsled-parser-check
.build/capsled-parser-check

swiftc Sources/CapsLEDCore/*.swift Checks/MenuBarCommandCheck.swift \
  -o .build/capsled-menu-bar-command-check
.build/capsled-menu-bar-command-check

swiftc Sources/CapsLEDCore/*.swift Checks/WatchBehaviorCheck.swift \
  -o .build/capsled-watch-behavior-check
.build/capsled-watch-behavior-check

swiftc Sources/CapsLEDCore/*.swift Checks/OnPersistenceCheck.swift \
  -o .build/capsled-on-persistence-check
.build/capsled-on-persistence-check
```

Also validate distribution metadata when changing install, packaging, or app
bundle files:

```sh
sh -n install.sh
bash -n scripts/build-release.sh
plutil -lint Support/CapsLEDMenuBar-Info.plist
```

## Build release archives

The release script builds Universal Binaries for Apple Silicon and Intel,
creates the CLI archive and `CapsLED.app`, signs them ad hoc, and writes SHA-256
checksums.

```sh
CAPSLED_VERSION=0.0.0 scripts/build-release.sh
```

Generated files are written to `.build/distribution`.

## Pull requests

- Keep changes focused and explain the user-visible behavior.
- Add or update a hardware-safe check when behavior changes.
- Keep `README.md` and `README.ja.md` aligned when changing user instructions.
- Report hardware testing separately from simulator or fake-backend checks.

Security reports should follow [SECURITY.md](SECURITY.md) instead of a public
issue.

# capsled

`capsled` is an experimental macOS CLI that uses the physical Caps Lock LED as
a general-purpose process indicator without changing the logical Caps Lock
modifier.

```sh
capsled on
capsled off
capsled auto
capsled run -- npm test
```

`on` and `off` perform one LED write. macOS may overwrite that shared value on
a later keyboard-state update. `auto` returns ownership to macOS, so the light
follows the normal Caps Lock state again. `run` watches the effective LED state,
repairs a macOS `Off` overwrite while the child command is active, and returns
to `auto` after normal exit, SIGINT, or SIGTERM.

## Build

Requires macOS 14 or newer and Swift 6.

```sh
swift build -c release
.build/release/capsled --help
```

The parser check does not touch hardware:

```sh
swiftc Sources/CapsLEDCore/Command.swift Checks/CommandParserCheck.swift \
  -o .build/capsled-parser-check
.build/capsled-parser-check
```

No installer is included yet. After the hardware behavior is verified, the
release binary can be copied to a directory on `PATH`, such as
`$HOME/.local/bin`.

## Important limitations

- This prototype uses the `HIDCapsLockLED` event-system property found in
  Apple's open-source IOHIDFamily implementation. The property values are not
  declared in the public macOS SDK, so this is unsupported SPI and may change
  in a future macOS release.
- The implementation does not open keyboard devices, register input callbacks,
  or read key events. The tested Passive-client path did not request Input
  Monitoring permission, but it remains unsupported SPI.
- `run` checks the effective LED state every 10 ms. A macOS overwrite can still
  produce a very short dark interval before `capsled` repairs it.
- `run` cannot restore `auto` after SIGKILL, a crash, or power loss. Run
  `capsled auto` to recover.
- Compatibility is not guaranteed across Mac models or external keyboards.

This project remains experimental and depends on unsupported macOS SPI.

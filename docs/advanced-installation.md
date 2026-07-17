# Advanced installation

[日本語](advanced-installation.ja.md) | English

The main [README](../README.md) covers the two recommended paths: Homebrew for
the CLI and the prebuilt menu-bar app. This page is for users who need the CLI
without Homebrew or contributors who are testing an unreleased checkout.

## Standalone CLI installer

The installer downloads the latest Universal Binary, verifies its SHA-256
checksum, installs it in `~/.local/bin`, and removes its temporary files.

Review [`install.sh`](../install.sh), then run:

```sh
curl -fsSL https://raw.githubusercontent.com/Sol-momma/capsled/main/install.sh | sh
```

Make sure the directory is on `PATH`. For the default zsh on macOS:

```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
```

Open a new terminal after changing `PATH`.

To use another destination, download and review the script first:

```sh
curl -fsSL https://raw.githubusercontent.com/Sol-momma/capsled/main/install.sh \
  -o install.sh
less install.sh
```

Then set `CAPSLED_INSTALL_DIR` when you run it:

```sh
CAPSLED_INSTALL_DIR=/usr/local/bin sh install.sh
```

A system directory such as `/usr/local/bin` may require administrator
permission. Running capsled itself does not require root privileges.

Run the standalone installer again to update. To uninstall:

```sh
capsled auto
rm "$HOME/.local/bin/capsled"
```

Replace the path if you selected a custom destination.

## Build an unreleased checkout

Building requires Git and Swift 6. Clone the repository, build only the CLI
product, then run it directly:

```sh
git clone https://github.com/Sol-momma/capsled.git
cd capsled
swift build -c release --product capsled
.build/release/capsled watch
```

Use [CONTRIBUTING.md](../CONTRIBUTING.md) when changing source code or building
the menu-bar app and release archives.

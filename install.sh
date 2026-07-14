#!/bin/sh

set -eu

if [ "$(uname -s)" != "Darwin" ]; then
    echo "capsled: this installer supports macOS only" >&2
    exit 1
fi

repository="Sol-momma/capsled"
install_dir="${CAPSLED_INSTALL_DIR:-$HOME/.local/bin}"
download_base="${CAPSLED_DOWNLOAD_BASE_URL:-https://github.com/$repository/releases/latest/download}"
archive_name="capsled-macos-universal.tar.gz"
checksum_name="$archive_name.sha256"

# A private temporary directory prevents a local attacker from substituting the
# downloaded executable before checksum verification. The trap only removes the
# directory created by this process and never touches an existing user path.
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/capsled-install.XXXXXX")"
cleanup() {
    rm -rf "$temporary_dir"
}
trap cleanup EXIT
# Exit first for interruption signals; the EXIT trap then performs cleanup once
# instead of deleting the directory mid-command and resuming with missing files.
trap 'exit 1' HUP INT TERM

download() {
    curl \
        --proto '=https' \
        --tlsv1.2 \
        --fail \
        --location \
        --silent \
        --show-error \
        "$1" \
        --output "$2"
}

download "$download_base/$archive_name" "$temporary_dir/$archive_name"
download "$download_base/$checksum_name" "$temporary_dir/$checksum_name"

# The checksum file contains only the stable archive filename, so validation is
# performed from the temporary directory instead of rewriting trusted input.
(
    cd "$temporary_dir"
    shasum -a 256 -c "$checksum_name"
)

tar -xzf "$temporary_dir/$archive_name" -C "$temporary_dir"
if [ ! -x "$temporary_dir/capsled" ]; then
    echo "capsled: release archive does not contain an executable" >&2
    exit 1
fi

mkdir -p "$install_dir"
install -m 0755 "$temporary_dir/capsled" "$install_dir/capsled"

echo "capsled installed at $install_dir/capsled"
case ":$PATH:" in
    *":$install_dir:"*) ;;
    *) echo "Add $install_dir to PATH before running capsled." ;;
esac

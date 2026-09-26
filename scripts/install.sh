#!/bin/sh
# Installs or updates yap on this Mac:
#
#   curl -fsSL https://raw.githubusercontent.com/Bjoernbom/yap/main/scripts/install.sh | sh
#
# It finds the newest yap 1.x release on GitHub, downloads the zip, checks its
# SHA-256, quits yap if it's running from the install location, moves the app
# to /Applications and opens it. Files fetched with curl aren't quarantined,
# so Gatekeeper doesn't interrupt. It only uses sudo when your account can't
# write to /Applications, and says so first.
#
# Settings (environment):
#   YAP_VERSION=v1.0.0       install this release instead of the newest 1.x
#   YAP_INSTALL_DIR=<dir>    install somewhere other than /Applications
#   YAP_REPLACE=yes|no       answer "replace the installed yap?" without asking
#   YAP_OPEN=no              don't open yap afterwards
#   YAP_RELEASES_API=<url>   release list to read (for testing)
set -eu

releases_api=${YAP_RELEASES_API:-https://api.github.com/repos/Bjoernbom/yap/releases?per_page=50}
install_dir=${YAP_INSTALL_DIR:-/Applications}
wanted=${YAP_VERSION:-}
replace=${YAP_REPLACE:-ask}
open_after=${YAP_OPEN:-yes}
dest=$install_dir/yap.app

say() { printf '%s\n' "$*"; }
die() { printf 'yap install: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "yap is a macOS app."
[ "$(uname -m)" = arm64 ] || die "yap needs a Mac with Apple silicon."
os=$(sw_vers -productVersion)
[ "${os%%.*}" -ge 26 ] || die "yap needs macOS 26 or later; this Mac has $os."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT TERM

# 1. Find the release: the newest 1.x that isn't a pre-release, or exactly the
#    one asked for. Through the API rather than /releases/latest, so a
#    pre-release can still be installed by name.
curl -fsSL -H 'Accept: application/vnd.github+json' "$releases_api" -o "$work/releases.json" \
	|| die "couldn't read the release list from GitHub. Check your connection and try again."

json() { plutil -extract "$1" raw -o - "$work/releases.json" 2>/dev/null; }

tag='' index=''
i=0
while name=$(json "$i.tag_name"); do
	if [ "$(json "$i.draft")" != true ] && { [ -n "$wanted" ] || [ "$(json "$i.prerelease")" != true ]; }; then
		case $name in
			v1.*)
				if [ -z "$wanted" ] || [ "$name" = "$wanted" ]; then
					tag=$name index=$i
					break
				fi
				;;
		esac
	fi
	i=$((i + 1))
done
[ -n "$tag" ] || die "no yap ${wanted:-1.x} release found."

zip_name='' zip_url='' sums_url=''
j=0
while asset=$(json "$index.assets.$j.name"); do
	url=$(json "$index.assets.$j.browser_download_url")
	case $asset in
		yap-*.zip) zip_name=$asset zip_url=$url ;;
		SHA256SUMS) sums_url=$url ;;
	esac
	j=$((j + 1))
done
[ -n "$zip_url" ] && [ -n "$sums_url" ] || die "release $tag is missing its zip or SHA256SUMS."

# 2. Download and verify.
say "Downloading yap $tag…"
curl -fL --progress-bar "$zip_url" -o "$work/$zip_name" || die "download failed."
curl -fsSL "$sums_url" -o "$work/SHA256SUMS" || die "couldn't download SHA256SUMS."

expected=$(awk -v f="$zip_name" '$2 == f || $2 == "*" f { print $1 }' "$work/SHA256SUMS")
actual=$(shasum -a 256 "$work/$zip_name" | awk '{ print $1 }')
[ -n "$expected" ] || die "SHA256SUMS has no entry for $zip_name."
if [ "$expected" != "$actual" ]; then
	die "checksum mismatch for $zip_name (expected $expected, got $actual). Nothing was installed."
fi
say "Checksum OK."

ditto -x -k "$work/$zip_name" "$work/unpacked" || die "couldn't unpack $zip_name."
new=$work/unpacked/yap.app
[ -d "$new" ] || die "$zip_name doesn't contain yap.app."
codesign --verify --deep --strict "$new" 2>/dev/null || die "yap.app's code signature is broken. Nothing was installed."

# 3. Replace an existing install only with permission.
ask() {
	case $replace in
		yes) return 0 ;;
		no) return 1 ;;
	esac
	# `curl | sh` feeds this script on stdin, so ask on the terminal.
	if ! { : < /dev/tty; } 2>/dev/null; then
		die "$1 Run again with YAP_REPLACE=yes to replace it, or YAP_REPLACE=no to keep it."
	fi
	printf '%s Replace it? [y/N] ' "$1" > /dev/tty
	read -r answer < /dev/tty || answer=
	case $answer in
		[yY]*) return 0 ;;
		*) return 1 ;;
	esac
}

if [ -e "$dest" ]; then
	old_id=$(defaults read "$dest/Contents/Info" CFBundleIdentifier 2>/dev/null || echo unknown)
	old_version=$(defaults read "$dest/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")
	case $old_id in
		com.bjornbom.yap) what="yap $old_version is already installed in $install_dir." ;;
		com.voicething.app) what="yap $old_version (the old 0.x app) is installed in $install_dir." ;;
		*) what="$dest already exists ($old_id)." ;;
	esac
	if ! ask "$what"; then
		say "Kept the installed yap. Nothing changed."
		exit 0
	fi
fi

# 4. Quit yap if it runs from where we install. Other copies are left alone.
exe=$dest/Contents/MacOS/yap
pids=$(ps -axo pid=,comm= | awk -v exe="$exe" '{ pid = $1; sub(/^ *[0-9]+ /, ""); if ($0 == exe) print pid }')
if [ -n "$pids" ]; then
	say "Quitting yap…"
	# shellcheck disable=SC2086 # one pid per word
	kill $pids 2>/dev/null || true
	n=0
	# shellcheck disable=SC2086 # unquoted on purpose: newlines to commas
	while [ $n -lt 50 ] && ps -p "$(echo $pids | tr ' ' ',')" > /dev/null 2>&1; do
		sleep 0.2
		n=$((n + 1))
	done
fi

# 5. Move it into place.
sudo=
if [ ! -d "$install_dir" ]; then
	mkdir -p "$install_dir" 2>/dev/null || sudo=sudo
fi
if [ -z "$sudo" ] && [ ! -w "$install_dir" ]; then
	sudo=sudo
fi
if [ -n "$sudo" ]; then
	say "Your account can't write to $install_dir, so moving yap there needs"
	say "an administrator password (sudo). Nothing else runs as root."
	sudo mkdir -p "$install_dir"
fi
staging=$install_dir/.yap-install.$$
$sudo rm -rf "$staging"
$sudo ditto "$new" "$staging"
if [ -n "$sudo" ]; then
	# Owned by you, so yap's own updates install without a password.
	sudo chown -R "$(id -u):$(id -g)" "$staging"
fi
$sudo rm -rf "$dest"
$sudo mv "$staging" "$dest"
say "Installed yap $tag in $install_dir."

# 6. Open it.
if [ "$open_after" != no ]; then
	open "$dest"
	say "yap is in your menu bar. It asks for Microphone and Accessibility the first time."
fi

#!/bin/sh
# Builds, signs and packages a yap release into dist/:
#   yap-<version>.zip   the app (install.sh, Homebrew and Sparkle use this)
#   yap-<version>.dmg   the app + an Applications link, for manual downloads
#   install.sh          scripts/install.sh, published next to the archives
#   SHA256SUMS          checksums of the three files above
#   appcast-item.xml    the Sparkle <item> for this release
#
# Usage:
#   scripts/release/package.sh <version>             real release (CI)
#   scripts/release/package.sh --dry-run [version]   local, no secrets needed
#
# Environment:
#   YAP_SIGN_IDENTITY     code-signing identity in the keychain
#                         (docs/SIGNING.md); dry run: ad-hoc unless set
#   SPARKLE_PRIVATE_KEY   EdDSA private key (base64, from `generate_keys -x`);
#                         dry run: no appcast signature unless set
#   BUILD_NUMBER          CFBundleVersion; default: commits on HEAD, which only
#                         grows on main (Sparkle compares this number)
#   DOWNLOAD_BASE         where the archives will live; default: the GitHub
#                         release for v<version>
#   SPARKLE_PUBLIC_KEY    overrides the key in project.yml (tests only)
set -eu

cd "$(dirname "$0")/../.."
root=$(pwd)

dry_run=no
if [ "${1:-}" = "--dry-run" ]; then
	dry_run=yes
	shift
fi
version=${1:-}
if [ -z "$version" ]; then
	if [ "$dry_run" = yes ]; then
		version="$(sed -n 's/^ *MARKETING_VERSION: *//p' project.yml)-dryrun"
	else
		echo "usage: $0 [--dry-run] <version>" >&2
		exit 64
	fi
fi
case $version in
	v*) version=${version#v} ;;
esac

build_number=${BUILD_NUMBER:-$(git rev-list --count HEAD)}
download_base=${DOWNLOAD_BASE:-"https://github.com/Bjoernbom/yap/releases/download/v$version"}
identity=${YAP_SIGN_IDENTITY:-}
sparkle_key=${SPARKLE_PRIVATE_KEY:-}

if [ "$dry_run" = no ]; then
	[ -n "$identity" ] || { echo "error: YAP_SIGN_IDENTITY is required for a release (docs/SIGNING.md)" >&2; exit 1; }
	[ -n "$sparkle_key" ] || { echo "error: SPARKLE_PRIVATE_KEY is required for a release (docs/RELEASING.md)" >&2; exit 1; }
fi
if [ -z "$identity" ]; then
	identity=-
	echo "warning: DRY RUN, ad-hoc signed. Not for users: permissions won't survive an update." >&2
fi

derived=build/release
app=$derived/Build/Products/Release/yap.app
dist=dist
sparkle_bin=$derived/SourcePackages/artifacts/sparkle/Sparkle/bin
zip=yap-$version.zip
dmg=yap-$version.dmg

step() { printf '\n==> %s\n' "$*"; }

step "Building yap $version ($build_number)"
rm -rf "$dist" "$app"
mkdir -p "$dist"
xcodegen generate --quiet
set -- MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number"
if [ -n "${SPARKLE_PUBLIC_KEY:-}" ]; then
	set -- "$@" SPARKLE_PUBLIC_KEY="$SPARKLE_PUBLIC_KEY"
fi
# Xcode doesn't sign; this script does, below, so a dry run exercises the
# same signing steps as a release, and CI needs no Xcode-trusted identity.
xcodebuild -project yap.xcodeproj -scheme yap -configuration Release \
	-derivedDataPath "$derived" -destination 'platform=macOS,arch=arm64' \
	-quiet CODE_SIGNING_ALLOWED=NO "$@" build

public_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")
if [ "$dry_run" = no ] && [ -z "$public_key" ]; then
	echo "error: SUPublicEDKey is empty. Put the key from generate_keys in SPARKLE_PUBLIC_KEY in project.yml." >&2
	exit 1
fi
if [ -n "$sparkle_key" ] && [ -n "$public_key" ]; then
	if derived_key=$(printf '%s' "$sparkle_key" | xcrun swift "$root/scripts/release/ed25519-public-key.swift"); then
		if [ "$derived_key" != "$public_key" ]; then
			echo "error: SPARKLE_PRIVATE_KEY doesn't belong to the app's SUPublicEDKey; users could never install this update." >&2
			exit 1
		fi
	else
		echo "warning: couldn't derive a public key from SPARKLE_PRIVATE_KEY (older key format?); skipping the key-pair check." >&2
	fi
fi

step "Signing with ${identity}"
# Inside out, as Sparkle documents: nested helpers first, the app last.
sign() { codesign --force --timestamp=none --options runtime --sign "$identity" "$@"; }
fw=$app/Contents/Frameworks/Sparkle.framework/Versions/B
sign "$fw/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$fw/XPCServices/Downloader.xpc"
sign "$fw/Autoupdate"
sign "$fw/Updater.app"
sign "$app/Contents/Frameworks/Sparkle.framework"
sign --entitlements App/yap.entitlements "$app"
codesign --verify --deep --strict "$app"
codesign -d -r- "$app" 2>&1 | sed -n 's/^# designated => /designated requirement: /p'

step "Packaging"
# --sequesterRsrc --keepParent: what Sparkle and Finder's Compress produce.
ditto -c -k --sequesterRsrc --keepParent "$app" "$dist/$zip"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/yap.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname yap -srcfolder "$stage" -fs HFS+ -format ULFO -ov "$dist/$dmg"
if [ "$identity" != - ]; then
	codesign --force --timestamp=none --sign "$identity" "$dist/$dmg"
fi

cp scripts/install.sh "$dist/install.sh"
(cd "$dist" && shasum -a 256 "$zip" "$dmg" install.sh > SHA256SUMS)

step "Appcast item"
length=$(stat -f %z "$dist/$zip")
signature_attr=
if [ -n "$sparkle_key" ]; then
	signature=$(printf '%s' "$sparkle_key" | "$sparkle_bin/sign_update" --ed-key-file - -p "$dist/$zip")
	signature_attr=" sparkle:edSignature=\"$signature\""
else
	echo "warning: no SPARKLE_PRIVATE_KEY, so the appcast item is unsigned and Sparkle will reject it." >&2
fi
minimum_os=$(sed -n 's/^ *MACOSX_DEPLOYMENT_TARGET: *"\{0,1\}\([0-9.]*\)"\{0,1\}/\1/p' project.yml | head -1)
cat > "$dist/appcast-item.xml" <<EOF
		<item>
			<title>yap $version</title>
			<pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
			<link>https://github.com/Bjoernbom/yap/releases/tag/v$version</link>
			<description><![CDATA[<p>What's new: <a href="https://github.com/Bjoernbom/yap/releases/tag/v$version">yap $version release notes</a>.</p>]]></description>
			<sparkle:version>$build_number</sparkle:version>
			<sparkle:shortVersionString>$version</sparkle:shortVersionString>
			<sparkle:minimumSystemVersion>$minimum_os</sparkle:minimumSystemVersion>
			<enclosure url="$download_base/$zip" length="$length" type="application/octet-stream"$signature_attr/>
		</item>
EOF

step "Done"
(cd "$dist" && ls -l && cat SHA256SUMS)

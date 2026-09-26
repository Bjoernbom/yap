#!/bin/sh
# CI only. Puts the signing certificate where codesign finds it on a fresh
# runner: a temporary keychain, unlocked, key usable by codesign without a
# prompt, on the user search list (codesign only resolves identities from
# keychains on that list; `codesign --keychain` alone reports "no identity
# found"). Prints the identity's SHA-1 for YAP_SIGN_IDENTITY.
#
# Usage: scripts/signing/ci-keychain.sh <p12-file> <p12-password>
set -eu

if [ "${CI:-}" != true ]; then
	echo "error: CI only; this changes the keychain search list. Locally, see docs/SIGNING.md." >&2
	exit 1
fi

p12=$1
p12_password=$2
keychain=${RUNNER_TEMP:-${TMPDIR:-/tmp}}/yap-signing.keychain-db
keychain_password=$(openssl rand -hex 24)

security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$p12" -k "$keychain" -f pkcs12 -P "$p12_password" -T /usr/bin/codesign > /dev/null
# Without this codesign stops at a (headless, so fatal) "allow access" prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" > /dev/null
# shellcheck disable=SC2046 # one keychain path per word; runner paths have no spaces
security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')

security find-identity -p codesigning "$keychain" >&2
security find-identity -p codesigning "$keychain" | awk '/"yap self-signed/ { print $2; exit }'

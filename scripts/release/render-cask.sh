#!/bin/sh
# Prints the Homebrew cask for a packaged release (dist/ from package.sh).
# Usage: scripts/release/render-cask.sh <version> [dist-dir]
set -eu

version=${1#v}
dist=${2:-dist}
cd "$(dirname "$0")/../.."

sha=$(awk -v f="yap-$version.zip" '$2 == f { print $1 }' "$dist/SHA256SUMS")
[ -n "$sha" ] || { echo "error: no yap-$version.zip in $dist/SHA256SUMS" >&2; exit 1; }
sed -e "s/@VERSION@/$version/" -e "s/@SHA256@/$sha/" \
	-e '/^# Template for/,/^# release workflow/d' \
	packaging/homebrew/yap.rb

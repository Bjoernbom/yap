#!/bin/sh
# Adds a release's <item> (dist/appcast-item.xml from package.sh) to the top
# of the appcast, replacing an older item for the same version.
#
# Usage: scripts/release/update-appcast.sh <item.xml> [appcast.xml]
set -eu

item=$1
appcast=${2:-appcast.xml}
marker='<!-- releases, newest first -->'

grep -qF "$marker" "$appcast" || { echo "error: $appcast has no '$marker' line" >&2; exit 1; }
version=$(sed -n 's:.*<sparkle\:shortVersionString>\(.*\)</sparkle\:shortVersionString>.*:\1:p' "$item")
[ -n "$version" ] || { echo "error: $item has no sparkle:shortVersionString" >&2; exit 1; }

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
# Drop an item for the same version (a re-run of a tag), then put the new
# one right under the marker.
awk -v item="$item" -v marker="$marker" -v version="$version" '
	/<item>/ { buf = $0 "\n"; in_item = 1; next }
	in_item {
		buf = buf $0 "\n"
		if ($0 ~ /<\/item>/) {
			in_item = 0
			if (index(buf, "<sparkle:shortVersionString>" version "</sparkle:shortVersionString>") == 0) printf "%s", buf
		}
		next
	}
	{ print }
	index($0, marker) { while ((getline line < item) > 0) print line }
' "$appcast" > "$tmp"
xmllint --noout "$tmp"
cat "$tmp" > "$appcast"
echo "appcast: yap $version added to $appcast"

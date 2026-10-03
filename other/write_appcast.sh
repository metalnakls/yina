#!/bin/bash
#
#  write_appcast.sh
#  yina
#
#  Writes a Sparkle appcast describing a single signed update archive.
#
#  Usage:
#    other/write_appcast.sh <appcast-out> <enclosure-url> <version> <ed-signature> <archive>
#
#  The EdDSA signature is produced by Sparkle's `sign_update` using the private key
#  in the login keychain. This script never sees that key.
#
set -euo pipefail

if [ "$#" -ne 5 ]; then
  echo "usage: $0 <appcast-out> <enclosure-url> <version> <ed-signature> <archive>" >&2
  exit 64
fi

APPCAST_OUT="$1"
ENCLOSURE_URL="$2"
VERSION="$3"
ED_SIGNATURE="$4"
ARCHIVE="$5"

if [ ! -f "$ARCHIVE" ]; then
  echo "update archive does not exist: $ARCHIVE" >&2
  exit 66
fi

ARCHIVE_LENGTH="$(wc -c < "$ARCHIVE" | tr -d ' ')"

# The heredoc is intentionally unindented: an indented terminator would close the
# block early and emit a malformed appcast.
cat > "$APPCAST_OUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>yina</title>
    <item>
      <enclosure url="$ENCLOSURE_URL" sparkle:version="$VERSION" sparkle:shortVersionString="$VERSION" sparkle:edSignature="$ED_SIGNATURE" length="$ARCHIVE_LENGTH" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML

echo "Wrote appcast: $APPCAST_OUT"

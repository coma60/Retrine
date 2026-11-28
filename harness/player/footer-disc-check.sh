#!/bin/sh
# The player footer's disc of the control that is on (issue #83), the real PlayerFooter.x and the Kit's glyph button on
# Mac Catalyst; no simulator.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC=${SRC:-$(cd "$HERE/../../tweak/Sources" && pwd)}
LOGOS=${THEOS:-$HOME/theos}/bin/logos.pl
OUT=$(mktemp -d /tmp/player-footer-disc-check.XXXXXX)
trap 'rm -rf "$OUT"' EXIT
APP=$OUT/Check.app
mkdir -p "$APP/Contents/MacOS"
"$LOGOS" -c generator=internal "$SRC/Redesigned/Player/PlayerFooter.x" > "$OUT/PlayerFooter.m"
SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun clang -target $(uname -m)-apple-ios17.0-macabi -fobjc-arc -g -O0 -isysroot "$SDK" \
    -iframework "$SDK/System/iOSSupport/System/Library/Frameworks" \
    -I"$SRC" -I"$SRC/Redesigned/Player" -I"$HERE" -Wall -Wno-unused-parameter -Wno-deprecated-declarations \
    "$OUT/PlayerFooter.m" "$HERE/footer-disc-check.m" \
    "$SRC/Redesigned/Kit/SGRGlyph.m" "$SRC/Redesigned/Kit/SGRTokens.m" \
    -framework UIKit -framework QuartzCore -framework CoreGraphics -framework Foundation -framework Symbols \
    -o "$APP/Contents/MacOS/Check"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Check</string>
<key>CFBundleIdentifier</key><string>com.retrine.player.footerdisccheck</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
codesign -f -s - "$APP" >/dev/null 2>&1
"$APP/Contents/MacOS/Check"

#!/bin/sh
# The player's ink in the backdrop's hue (SGRBackdropInk.h, issue #82 F1), the complete SGRRestyle.m, on Mac Catalyst;
# no simulator.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC=${SRC:-$(cd "$HERE/../../tweak/Sources" && pwd)}
OUT=$(mktemp -d /tmp/player-backdrop-ink-check.XXXXXX)
trap 'rm -rf "$OUT"' EXIT
APP=$OUT/Check.app
mkdir -p "$APP/Contents/MacOS"
SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun clang -target $(uname -m)-apple-ios17.0-macabi -fobjc-arc -g -O0 -isysroot "$SDK" \
    -iframework "$SDK/System/iOSSupport/System/Library/Frameworks" \
    -I"$SRC" -I"$SRC/Redesigned/Player" -I"$HERE" -Wall -Wno-unused-parameter -Wno-deprecated-declarations \
    "$HERE/backdrop-ink-check.m" "$SRC/Redesigned/Kit/SGRRestyle.m" "$SRC/Redesigned/Kit/SGRRollingDigits.m" "$SRC/Redesigned/Kit/SGRTokens.m" \
    "$SRC/Core/SGViewTree.m" "$SRC/Core/SGLog.m" "$SRC/Settings/SGPageStyle.m" "$SRC/Core/SGLocalize.m" "$SRC/Redesigned/Kit/SGRRefinements.m" \
    -framework UIKit -framework QuartzCore -framework CoreGraphics -framework CoreText -framework Foundation \
    -o "$APP/Contents/MacOS/Check"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Check</string>
<key>CFBundleIdentifier</key><string>com.retrine.player.backdropinkcheck</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
codesign -f -s - "$APP" >/dev/null 2>&1
"$APP/Contents/MacOS/Check"

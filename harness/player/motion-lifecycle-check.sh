#!/bin/sh
# The player clip's lifecycle (issue #82), compiled from the production sources: PlayerField.x's visibility and
# close-pending state with its appearance hook bodies and transition-end observer, and PlayerMotion.x's
# consumerVisible, brieflyUnseen, alreadyShowing, show and lifecycleChanged with the %ctor's observer loop.
# Runs as a Mac Catalyst process with doubles for the clip's view, the follower and the poster; no simulator.
#   sh harness/player/motion-lifecycle-check.sh        (from the repository root; SRC=<tweak/Sources> for another tree)
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC=${SRC:-$(cd "$HERE/../../tweak/Sources" && pwd)}
OUT=$(mktemp -d /tmp/retrine-motion-lifecycle.XXXXXXXX)
trap 'rm -rf "$OUT"' EXIT
python3 - "$SRC/Redesigned/Player/PlayerField.x" "$SRC/Redesigned/Player/PlayerMotion.x" "$OUT" <<'PY'
import pathlib
import re
import sys

field = pathlib.Path(sys.argv[1]).read_text()
motion = pathlib.Path(sys.argv[2]).read_text()
out = pathlib.Path(sys.argv[3])
STATE = "UIApplication.sharedApplication.applicationState"

def one(pattern, source, what):
    found = re.findall(pattern, source, re.M | re.S)
    if len(found) != 1:
        raise SystemExit(f"expected one {what}, found {len(found)}")
    return found[0]

# The visibility state, up to the morph's coverage hooks (Logos).
start = field.index("static __weak SGRArtworkField *sg_field;")
end = field.index("SGRArtworkField *SGRPlayerField(void)")
region = field[start:end]
for needed in ("BOOL SGRPlayerClosePending(void)", "static void visibilityChanged(void)"):
    if needed not in region:
        raise SystemExit(f"PlayerField.x: {needed} not in the visibility region")
region = re.sub(r"^%group.*?^%end\n%end\n", "", region, flags=re.M | re.S)
if re.search(r"%(hook|orig|group|end|init)", region):
    raise SystemExit("PlayerField.x: Logos left in the visibility region")

# The background controller's appearance hooks, their bodies without %orig.
hook = one(r"^%hook _TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController\n(.*?)^%end", field, "background controller hook")
hooks = []
for name in ("viewWillAppear", "viewDidAppear", "viewWillDisappear", "viewDidDisappear"):
    body = one(r"^- \(void\)" + name + r":\(BOOL\)animated \{\n(.*?)^\}", hook, name)
    body = "\n".join(line for line in body.splitlines() if line.strip() != "%orig;")
    hooks.append(f"static void field_{name}(void) {{\n{body}\n}}\n")
ended = one(r"^    \[NSNotificationCenter\.defaultCenter addObserverForName:SGPlayerTransitionEndedNotification .*?^    \}\];\n",
            field, "transition-end observer")
hooks.append("static void field_observe(void) {\n" + ended + "}\n")
(out / "field.inc").write_text((region + "\n" + "\n".join(hooks)).replace(STATE, "harnessAppState"))

parts = []
for pattern, what in (
        (r"^static BOOL consumerVisible\(void\) \{\n.*?^\}\n", "consumerVisible"),
        (r"^static BOOL brieflyUnseen\(NSNotificationName name\) \{\n.*?^\}\n", "brieflyUnseen"),
        (r"^static BOOL alreadyShowing\(NSString \*track, NSURL \*file\) \{\n.*?^\}\n", "alreadyShowing"),
        (r"^static void show\(NSString \*track, NSURL \*file\) \{\n.*?^\}\n", "show"),
        (r"^static void lifecycleChanged\(NSNotificationName name\) \{\n.*?^\}\n", "lifecycleChanged")):
    parts.append(one(pattern, motion, what))
loop = one(r"^    for \(NSNotificationName name in @\[UIApplicationWillResignActiveNotification.*?^    \}\n", motion, "lifecycle observer loop")
for name in ("UIApplicationWillResignActiveNotification", "UIApplicationDidBecomeActiveNotification",
             "UIApplicationDidEnterBackgroundNotification", "SGRPlayerVisibilityDidChangeNotification", "lifecycleChanged(note.name)"):
    if name not in loop:
        raise SystemExit(f"PlayerMotion.x: the lifecycle observers lack {name}")
parts.append("static void motion_observe(void) {\n" + loop + "}\n")
(out / "motion.inc").write_text("\n".join(parts).replace(STATE, "harnessAppState"))
PY
SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun clang -target "$(uname -m)-apple-ios17.0-macabi" -isysroot "$SDK" \
    -iframework "$SDK/System/iOSSupport/System/Library/Frameworks" -fobjc-arc -Wall -Wno-unused-variable \
    -Wno-unused-function -I"$SRC" -I"$OUT" -I"$HERE/.." "$HERE/motion-lifecycle-check.m" \
    -framework UIKit -framework Foundation -framework CoreGraphics -o "$OUT/motion-lifecycle"
"$OUT/motion-lifecycle"

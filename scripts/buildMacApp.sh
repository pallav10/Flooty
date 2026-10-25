#!/bin/bash
# buildMacApp.sh — wrap flooty in a real macOS .app bundle (icon, dock
# identity, Finder launch, ad-hoc signature).
#
# The bundle does NOT compile Julia: it is a launcher around the same entry point
# the `flooty` shim uses (`-m Flooty` with JULIA_LOAD_PATH pointing at
# the dev checkout). Fast, and edits to the checkout are picked up on the next
# launch. For a SELF-CONTAINED app (no Julia install, no checkout), see the README
# section "Self-contained app" (PackageCompiler.create_app).
#
# Usage:
#   scripts/buildMacApp.sh                     # -> ~/Applications/Flooty.app
#   scripts/buildMacApp.sh --out /Applications  # -> /Applications/Flooty.app
#   scripts/buildMacApp.sh --icon assets/flooty-icon.svg
#   scripts/buildMacApp.sh --no-sign            # skip the ad-hoc codesign
#
# Env (defaults shown):
#   FLOOTY_DEPOT=$HOME/.julia  FLOOTY_PROJECT=$FLOOTY_DEPOT/dev/Flooty
#   FLOOTY_JULIA=$HOME/.juliaup/bin/julia   APP_NAME=Flooty
#   BUNDLE_ID=dev.flooty.agent
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$HOME/Applications"
ICON_SRC="$REPO/assets/flooty-icon.svg"
SIGN=1
IDENTITY=""
APP_NAME="${APP_NAME:-Flooty}"
BUNDLE_ID="${BUNDLE_ID:-dev.flooty.agent}"
DISPLAY_NAME="${DISPLAY_NAME:-Flooty}"
FLOOTY_DEPOT="${FLOOTY_DEPOT:-$HOME/.julia}"
FLOOTY_PROJECT="${FLOOTY_PROJECT:-$FLOOTY_DEPOT/dev/Flooty}"
FLOOTY_JULIA="${FLOOTY_JULIA:-$HOME/.juliaup/bin/julia}"
VERSION="${VERSION:-0.1.0}"

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT_DIR="$2"; shift 2 ;;
        --icon) ICON_SRC="$2"; shift 2 ;;
        --no-sign) SIGN=0; shift ;;
        --identity) IDENTITY="$2"; shift 2 ;;
        --name) APP_NAME="$2"; shift 2 ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

APP="$OUT_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

command -v iconutil >/dev/null || { echo "iconutil missing (macOS only)" >&2; exit 1; }
[ -x "$FLOOTY_JULIA" ] || { echo "julia not found at $FLOOTY_JULIA" >&2; exit 1; }
[ -d "$FLOOTY_PROJECT" ] || { echo "project not found at $FLOOTY_PROJECT" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ---- icon -------------------------------------------------------------------
iconset="$work/$APP_NAME.iconset"
mkdir -p "$iconset"
if [ "${ICON_SRC##*.}" = "png" ]; then
    cp "$ICON_SRC" "$work/base.png"
else
    # QuickLook adds an opaque background; AppKit preserves the SVG's alpha.
    swift -e '
import AppKit
let input = CommandLine.arguments[1]
let output = CommandLine.arguments[2]
guard let image = NSImage(contentsOfFile: input),
      let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("could not render \(input)\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: output))
' "$ICON_SRC" "$work/base.png"
fi
for spec in "16 icon_16x16.png" "32 icon_16x16@2x.png" "32 icon_32x32.png" \
            "64 icon_32x32@2x.png" "128 icon_128x128.png" "256 icon_128x128@2x.png" \
            "256 icon_256x256.png" "512 icon_256x256@2x.png" "512 icon_512x512.png" \
            "1024 icon_512x512@2x.png"; do
    set -- $spec
    sips -z "$1" "$1" "$work/base.png" --out "$iconset/$2" >/dev/null
done
iconutil -c icns "$iconset" -o "$work/$APP_NAME.icns"

# ---- bundle -----------------------------------------------------------------
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp "$work/$APP_NAME.icns" "$RES/$APP_NAME.icns"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$DISPLAY_NAME</string>
    <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>        <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>         <string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>LSMinimumSystemVersion</key>  <string>12.0</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key> <true/>
</dict>
</plist>
PLIST

# The launcher reproduces the Pkg.Apps shim's environment (depot + the dev
# checkout on JULIA_LOAD_PATH) and never inherits the caller's project.
cat > "$MACOS/$APP_NAME" <<LAUNCH
#!/bin/bash
set -euo pipefail
export JULIA_DEPOT_PATH="$FLOOTY_DEPOT:"
export JULIA_LOAD_PATH="$FLOOTY_PROJECT"
# A Finder launch starts in "/" — the app's panes and journal paths expect $HOME.
cd "\$HOME"
LOG="\$HOME/Library/Logs/$APP_NAME.log"
mkdir -p "\$(dirname "\$LOG")"
echo "=== \$(date '+%Y-%m-%d %H:%M:%S') launch \$*" >>"\$LOG"
# The app flushes stdout/stderr once a second when this is set (a file redirect
# is block-buffered, so the log would otherwise stay empty until exit).
export FLOOTY_APP_BUNDLE=1
exec "$FLOOTY_JULIA" --startup-file=no --color=no -m Flooty "\$@" >>"\$LOG" 2>&1
LAUNCH
chmod +x "$MACOS/$APP_NAME"

plutil -lint "$CONTENTS/Info.plist" >/dev/null

if [ "$SIGN" = "1" ]; then
    # LOCAL NETWORK PRIVACY (macOS 14+): panes' `ssh`/curl to LAN/link-local
    # addresses is attributed to THIS app, and an UNSIGNED (ad-hoc) app is not
    # offered the permission — macOS filters the traffic and the pane sees
    # "No route to host" while the same ssh works from Terminal.
    # A real identity (Development or Developer ID) makes the prompt appear.
    if [ -z "$IDENTITY" ]; then
        IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null |
                    sed -n 's/.*"\(.*\)"/\1/p' | head -1)"
    fi
    if [ -n "$IDENTITY" ]; then
        codesign --force --deep --sign "$IDENTITY" "$APP" >/dev/null 2>&1 && \
            echo "signed: $IDENTITY" || {
            echo "warning: signing with '$IDENTITY' failed; falling back to ad-hoc" >&2
            codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
        }
    else
        # Ad-hoc signature: enough for the local machine (and for Gatekeeper to
        # treat the bundle as a unit), but NOT enough for Local Network privacy.
        codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
            echo "warning: ad-hoc codesign failed (the app still runs locally)" >&2
        echo "note: ad-hoc signed — the app will NOT be offered Local Network" >&2
        echo "      permission on macOS 14+; launch it from Terminal for LAN ssh," >&2
        echo "      or sign with: scripts/buildMacApp.sh --identity \"Developer ID Application: …\"" >&2
    fi
fi

echo "built: $APP"
echo "launch: open \"$APP\""

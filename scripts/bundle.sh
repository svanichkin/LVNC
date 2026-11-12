#!/bin/bash
# Build LVNC and wrap the binaries into signed app bundles.
#
#   scripts/bundle.sh <out dir>
#
# Produces <out dir>/LVNC.app (viewer) and <out dir>/LVNC Agent.app (agent).
#
# Environment:
#   LVNC_SIGN_IDENTITY  codesign identity (name or SHA-1); "-" = ad-hoc (default)
#   LVNC_HARDENED=1     hardened runtime + secure timestamp (required for notarization)
#   LVNC_UNIVERSAL=1    build for arm64 and x86_64
#   LVNC_BUILD          CFBundleVersion (default: current date and time)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?usage: bundle.sh <out dir>}"
IDENTITY="${LVNC_SIGN_IDENTITY:--}"
BUILD="${LVNC_BUILD:-$(date +%Y%m%d%H%M)}"

cd "$ROOT"
VERSION="$(sed -n 's/^public let lvncVersion = "\(.*\)"/\1/p' Sources/LVNCCore/Wire.swift)"
[ -n "$VERSION" ] || { echo "cannot read lvncVersion" >&2; exit 1; }

BUILD_ARGS=(-c release)
if [ "${LVNC_UNIVERSAL:-0}" = 1 ]; then BUILD_ARGS+=(--arch arm64 --arch x86_64); fi

echo "==> building $VERSION ($BUILD)"
swift build "${BUILD_ARGS[@]}"
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT

echo "==> icon"
swift scripts/make-icon.swift "$WORK/AppIcon.iconset" >/dev/null
iconutil -c icns "$WORK/AppIcon.iconset" -o "$WORK/AppIcon.icns"

# make_app <bundle name> <executable> <bundle id> <LSUIElement true|false>
make_app() {
    local name="$1" exe="$2" id="$3" agent="$4"
    local app="$OUT/$name.app"
    rm -rf "${app:?}"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$BIN/$exe" "$app/Contents/MacOS/$exe"
    cp "$WORK/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
    cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$id</string>
    <key>CFBundleName</key><string>$name</string>
    <key>CFBundleDisplayName</key><string>$name</string>
    <key>CFBundleExecutable</key><string>$exe</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><$agent/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
}

make_app "LVNC" lvnc-viewer local.lvnc.viewer false
make_app "LVNC Agent" lvnc-agent local.lvnc.agent true
cp scripts/install-agent.sh "$OUT/LVNC Agent.app/Contents/Resources/install-agent.sh"
chmod +x "$OUT/LVNC Agent.app/Contents/Resources/install-agent.sh"

SIGN_ARGS=(--force --sign "$IDENTITY")
if [ "$IDENTITY" = "-" ]; then
    echo "==> signing ad-hoc (privacy permissions will not survive updates)"
elif [ "${LVNC_HARDENED:-0}" = 1 ]; then
    echo "==> signing with the configured identity, hardened runtime"
    SIGN_ARGS+=(--options runtime --timestamp)
else
    echo "==> signing with the configured identity"
    SIGN_ARGS+=(--timestamp=none)
fi
for name in "LVNC" "LVNC Agent"; do
    codesign "${SIGN_ARGS[@]}" "$OUT/$name.app"
    codesign --verify --strict "$OUT/$name.app"
done

echo "==> bundled LVNC $VERSION ($BUILD) in $OUT"

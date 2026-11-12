#!/bin/bash
# Build LVNC, sign it and install it into /Applications (run from an admin account).
#
#   /Applications/LVNC.app         viewer (Dock-able)
#   /Applications/LVNC Agent.app   agent (background, started by a LaunchAgent; see install-agent.sh)
#   /opt/homebrew/bin/lvnc-viewer  CLI wrapper for the viewer
#
# Signing identity: LVNC_SIGN_IDENTITY, else scripts/local.env (not in git), else ad-hoc.
# A stable identity keeps Screen Recording / Accessibility grants across rebuilds; with
# ad-hoc signing they have to be granted again after every update.
#
#   echo 'LVNC_SIGN_IDENTITY=<SHA-1 from: security find-identity -v -p codesigning>' > scripts/local.env
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "${LVNC_SIGN_IDENTITY:-}" ] && [ -f "$ROOT/scripts/local.env" ]; then
    # shellcheck disable=SC1091
    source "$ROOT/scripts/local.env"
fi
export LVNC_SIGN_IDENTITY="${LVNC_SIGN_IDENTITY:--}"
APPS="/Applications"
BIN_LINK_DIR="/opt/homebrew/bin"
SHARED="/Users/Shared/lvnc"

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE:?}"' EXIT

"$ROOT/scripts/bundle.sh" "$STAGE"

echo "==> installing into $APPS"
for name in "LVNC" "LVNC Agent"; do
    target="$APPS/$name.app"
    rm -rf "${target:?}.new"
    ditto "$STAGE/$name.app" "$target.new"
    rm -rf "${target:?}"
    mv "$target.new" "$target"
    echo "    $target"
done

if [ -d "$BIN_LINK_DIR" ]; then
    cat > "$BIN_LINK_DIR/lvnc-viewer" <<'EOF'
#!/bin/sh
exec "/Applications/LVNC.app/Contents/MacOS/lvnc-viewer" "$@"
EOF
    chmod +x "$BIN_LINK_DIR/lvnc-viewer"
    echo "    $BIN_LINK_DIR/lvnc-viewer"
fi

mkdir -p "$SHARED/run" "$SHARED/logs"
chmod 1777 "$SHARED/run" "$SHARED/logs" 2>/dev/null || true

echo "==> done"
echo "    A running agent started by launchd picks up the new build within ~5 s."

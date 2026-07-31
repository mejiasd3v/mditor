#!/bin/bash
# Applies the native-sdk open-files host patch to the installed CLI.
#
# Background: macOS delivers documents to a running app via the
# open-document AppleEvent (odoc), not argv. The Native SDK host
# (appkit_host.m) had no NSApplicationDelegate, so Finder double-clicks,
# "Open With", and `open -a App file.md` silently dropped the file. This
# patch adds an app delegate that forwards odoc paths into the runtime
# as `open_files` events, which UiApp apps receive through the
# `on_open_files` option.
#
# The CLI is a global npm install; a CLI upgrade (or `native` reinstall)
# overwrites these files, so re-run this script after upgrading. It is
# idempotent: already-patched files are skipped.
set -euo pipefail

CLI="${NATIVE_SDK_CLI_DIR:-$HOME/.local/lib/node_modules/@native-sdk/cli}"
PATCH_DIR="$(cd "$(dirname "$0")/native-sdk-patch" && pwd)"

if [ ! -f "$CLI/package.json" ]; then
  echo "error: native-sdk CLI not found at $CLI (set NATIVE_SDK_CLI_DIR)" >&2
  exit 1
fi

marker="Open-document AppleEvent"
marker_v2="Markdown default-handler claim (host patch v2)"
# The v1 marker alone is not enough: a CLI patched by an older version
# of this script carries the open-files delegate but not the v2
# default-handler claim, so re-apply (the cp's below overwrite).
if grep -q "$marker" "$CLI/src/platform/macos/appkit_host.h" 2>/dev/null && grep -q "$marker_v2" "$CLI/src/platform/macos/appkit_host.m" 2>/dev/null; then
  echo "native-sdk CLI already patched; nothing to do."
  exit 0
fi

cp "$PATCH_DIR/platform/macos/appkit_host.h" "$CLI/src/platform/macos/appkit_host.h"
cp "$PATCH_DIR/platform/macos/appkit_host.m" "$CLI/src/platform/macos/appkit_host.m"
cp "$PATCH_DIR/platform/macos/root.zig"        "$CLI/src/platform/macos/root.zig"
cp "$PATCH_DIR/platform/types.zig"             "$CLI/src/platform/types.zig"
cp "$PATCH_DIR/runtime/api.zig"                "$CLI/src/runtime/api.zig"
cp "$PATCH_DIR/runtime/flow.zig"               "$CLI/src/runtime/flow.zig"
cp "$PATCH_DIR/runtime/session_journal.zig"    "$CLI/src/runtime/session_journal.zig"
cp "$PATCH_DIR/runtime/ui_app.zig"             "$CLI/src/runtime/ui_app.zig"
echo "patched native-sdk CLI at $CLI"
echo "next: rebuild and reinstall the app:"
echo "  native build && native package --target macos"
echo "  rm -rf /Applications/MDitor.app && cp -R zig-out/package/mditor.app /Applications/MDitor.app"
echo "  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/MDitor.app"

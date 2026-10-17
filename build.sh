#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Better Mac Taskbar"
EXEC_NAME="BetterMacTaskbar"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/${APP_NAME}.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

# Prefer an SDK the installed swiftc can compile against. CLT often points at a
# newer MacOSX.sdk than the toolchain (e.g. 27.0 vs Swift 6.3).
SDK="${SDKROOT:-$(xcrun --show-sdk-path)}"
if [[ "$SDK" == *MacOSX27* ]]; then
  for candidate in \
      /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk \
      /Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk; do
    if [[ -d "$candidate" ]]; then
      SDK="$candidate"
      break
    fi
  done
fi

echo "==> Collecting sources"
SOURCES=()
while IFS= read -r -d '' file; do
  SOURCES+=("$file")
done < <(find "$ROOT/Sources" -name '*.swift' -print0 | sort -z)

if [[ ${#SOURCES[@]} -eq 0 ]]; then
  echo "No Swift sources found" >&2
  exit 1
fi

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# -parse-as-library because the entry point is `@main` (Sources/main.swift).
echo "==> Compiling ${#SOURCES[@]} files against $SDK"
swiftc \
  -sdk "$SDK" \
  -target "arm64-apple-macosx${MACOSX_DEPLOYMENT_TARGET}" \
  -parse-as-library \
  -framework AppKit \
  -framework Cocoa \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -framework ServiceManagement \
  -framework ImageIO \
  -framework SwiftUI \
  -framework EventKit \
  -O \
  "${SOURCES[@]}" \
  -o "$MACOS_DIR/$EXEC_NAME"

cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
# CFBundleShortVersionString is maintained by hand in Resources/Info.plist (the
# single source of truth). CFBundleVersion is stamped here from the commit count
# so every commit gets a distinct, increasing build number without editing the
# source plist. Outside a git checkout the source plist's value is kept.
if BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null)"; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$CONTENTS/Info.plist"
fi
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

/usr/bin/plutil -convert binary1 "$CONTENTS/Info.plist" 2>/dev/null || true
/usr/bin/plutil -convert xml1 "$CONTENTS/Info.plist" 2>/dev/null || true

echo "==> Signing"
BUNDLE_ID="com.bettermac.taskbar"
# Prefer a real Apple identity so Accessibility grants survive rebuilds.
# Ad-hoc (-) changes CDHash every build and TCC stops recognizing the app.
# Fallback: a stable self-signed local identity (created once, reused forever).
SIGN_IDENTITY=""
LOCAL_IDENTITY="Better Mac Taskbar Local"
# Outside build/ so cleaning the build can't lose the identity — a new one means
# re-granting Accessibility and every other TCC permission.
SIGNING_DIR="$HOME/Library/Application Support/BetterMacTaskbar/signing"
P12_PATH="$SIGNING_DIR/BetterMacTaskbarLocal.p12"
P12_PASS="bettermac-local-dev"
LEGACY_P12_PATH="$ROOT/build/signing/BetterMacTaskbarLocal.p12"
ENTITLEMENTS="$ROOT/Resources/BetterMacTaskbar.entitlements"

if [[ ! -f "$P12_PATH" && -f "$LEGACY_P12_PATH" ]]; then
  echo "    Moving local signing identity to $SIGNING_DIR"
  mkdir -p "$SIGNING_DIR"
  chmod 700 "$SIGNING_DIR"
  mv "$LEGACY_P12_PATH" "$P12_PATH"
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -q 'Apple Development\|Developer ID Application\|Mac Developer'; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E 'Apple Development|Developer ID Application|Mac Developer' \
    | head -1 \
    | sed -E 's/.*"(.+)"/\1/')"
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "$LOCAL_IDENTITY"; then
    SIGN_IDENTITY="$LOCAL_IDENTITY"
  elif [[ -f "$P12_PATH" ]]; then
    echo "    Importing local signing identity from $P12_PATH"
    security import "$P12_PATH" -P "$P12_PASS" -A -T /usr/bin/codesign -T /usr/bin/security >/dev/null 2>&1 || true
    # Allow codesign to use the key without GUI unlock prompts.
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1 || true
    SIGN_IDENTITY="$LOCAL_IDENTITY"
  else
    echo "    Creating stable local codesigning identity (one-time)…"
    mkdir -p "$SIGNING_DIR"
    chmod 700 "$SIGNING_DIR"
    TMP="$(mktemp -d)"
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
      -subj "/CN=${LOCAL_IDENTITY}/O=Better Mac Taskbar/C=US" \
      -addext "extendedKeyUsage=codeSigning" >/dev/null 2>&1
    openssl pkcs12 -export -out "$P12_PATH" \
      -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
      -passout "pass:${P12_PASS}" -name "$LOCAL_IDENTITY" >/dev/null 2>&1
    # Prefer legacy bag encryption so `security import` accepts the p12 (OpenSSL 3 defaults break import).
    if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then
      openssl pkcs12 -export -legacy -out "$P12_PATH" \
        -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -passout "pass:${P12_PASS}" -name "$LOCAL_IDENTITY" >/dev/null 2>&1
    else
      openssl pkcs12 -export -out "$P12_PATH" \
        -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg SHA1 \
        -passout "pass:${P12_PASS}" -name "$LOCAL_IDENTITY" >/dev/null 2>&1
    fi
    rm -rf "$TMP"
    security import "$P12_PATH" -P "$P12_PASS" -A -T /usr/bin/codesign -T /usr/bin/security >/dev/null 2>&1 || true
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1 || true
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "$LOCAL_IDENTITY"; then
      SIGN_IDENTITY="$LOCAL_IDENTITY"
      echo "    Created and imported: $LOCAL_IDENTITY"
      echo "    Grant Accessibility ONCE for this identity — it will survive rebuilds."
    else
      echo "    Warning: could not install local identity; falling back to ad-hoc"
    fi
  fi
fi

# Hardened runtime in dev too, so a missing entitlement shows up here rather
# than only in a notarized release. It doesn't change the designated requirement,
# so existing TCC grants still match. No --deep: the bundle has no nested code.
SIGN_FLAGS=(--force --options runtime --entitlements "$ENTITLEMENTS" --identifier "$BUNDLE_ID")
if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "    Using identity: $SIGN_IDENTITY"
  if ! codesign "${SIGN_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$APP_DIR" 2>/dev/null; then
    echo "    Identity not usable (untrusted?) — falling back to ad-hoc"
    codesign "${SIGN_FLAGS[@]}" --sign - "$APP_DIR"
  fi
else
  echo "    No signing identity — using ad-hoc (Accessibility breaks every rebuild)"
  codesign "${SIGN_FLAGS[@]}" --sign - "$APP_DIR"
fi

echo "==> Built: $APP_DIR"

# Install to /Applications so the app has one stable home. Accessibility is
# granted per-path, so running from build/ means re-granting whenever the
# working copy moves. Set BMT_NO_INSTALL=1 to build without installing.
# /Applications is used when the folder is writable (admin) or when a copy the
# user owns is already there (e.g. from the .pkg) and can be updated in place;
# otherwise ~/Applications.
SYSTEM_APP="/Applications/${APP_NAME}.app"
USER_APP="$HOME/Applications/${APP_NAME}.app"
if [[ -w "/Applications" || -w "$SYSTEM_APP" ]]; then
  INSTALLED_APP="$SYSTEM_APP"
  OTHER_APP="$USER_APP"
else
  INSTALLED_APP="$USER_APP"
  OTHER_APP="$SYSTEM_APP"
  mkdir -p "$HOME/Applications"
fi

if [[ "${BMT_NO_INSTALL:-0}" == "1" ]]; then
  echo "==> Skipping install (BMT_NO_INSTALL=1)"
  RUN_APP="$APP_DIR"
else
  echo "==> Installing to $INSTALLED_APP"
  # Quit whichever copy is running first — overwriting a running bundle corrupts
  # it, and a copy running from elsewhere would keep the old binary alive.
  if pgrep -x "$EXEC_NAME" >/dev/null 2>&1; then
    echo "    Quitting running copy"
    # SIGTERM is a graceful quit (it restores the Dock first), so wait for the
    # process to actually exit; force it only if it hangs.
    pkill -x "$EXEC_NAME" || true
    for _ in {1..50}; do
      pgrep -x "$EXEC_NAME" >/dev/null 2>&1 || break
      sleep 0.1
    done
    pkill -KILL -x "$EXEC_NAME" 2>/dev/null || true
  fi

  INSTALL_OK=0
  if [[ -w "$(dirname "$INSTALLED_APP")" ]]; then
    # Stage beside the target and swap, so a failed copy never leaves a half bundle.
    rm -rf "$INSTALLED_APP.tmp"
    if ditto "$APP_DIR" "$INSTALLED_APP.tmp"; then
      rm -rf "$INSTALLED_APP"
      mv "$INSTALLED_APP.tmp" "$INSTALLED_APP"
      INSTALL_OK=1
    else
      rm -rf "$INSTALLED_APP.tmp"
    fi
  elif rsync -a --delete "$APP_DIR/" "$INSTALLED_APP/"; then
    # Parent not writable but the bundle is ours: sync its contents in place.
    INSTALL_OK=1
  fi

  if [[ "$INSTALL_OK" -eq 1 ]]; then
    # Re-assert the signature so the CDHash matches what TCC verifies.
    codesign --verify --strict "$INSTALLED_APP" >/dev/null 2>&1 \
      || echo "    Warning: installed copy failed signature verification"
    RUN_APP="$INSTALLED_APP"
  else
    echo "    Warning: install failed — falling back to $APP_DIR"
    RUN_APP="$APP_DIR"
  fi

  if [[ -d "$OTHER_APP" ]]; then
    echo "    Warning: a second copy exists at $OTHER_APP."
    echo "    Two bundles with one identifier confuse Launch Services and Login Items;"
    echo "    delete it unless you need it."
  fi
fi

# scripts/bmt-log and the Stop hook launch whatever this records, so they never
# start a second bundle with the same identifier (TCC would track two apps).
# Packaging builds (BMT_NO_INSTALL=1) aren't run, so they leave it alone.
if [[ "${BMT_NO_INSTALL:-0}" != "1" ]]; then
  printf '%s\n' "$RUN_APP" >"$BUILD_DIR/.run-app-path"
fi

echo "Run with: open \"$RUN_APP\""

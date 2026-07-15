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

SDK="$(xcrun --show-sdk-path)"
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

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
  -O \
  "${SOURCES[@]}" \
  -o "$MACOS_DIR/$EXEC_NAME"

# parse-as-library with main.swift that isn't @main can fail — rebuild without it if needed
if [[ ! -x "$MACOS_DIR/$EXEC_NAME" ]]; then
  echo "Retrying without -parse-as-library"
  swiftc \
    -sdk "$SDK" \
    -target "arm64-apple-macosx${MACOSX_DEPLOYMENT_TARGET}" \
    -framework AppKit \
    -framework Cocoa \
    -framework ApplicationServices \
    -framework CoreGraphics \
    -framework ServiceManagement \
    -O \
    "${SOURCES[@]}" \
    -o "$MACOS_DIR/$EXEC_NAME"
fi

cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
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
SIGNING_DIR="$ROOT/build/signing"
P12_PATH="$SIGNING_DIR/BetterMacTaskbarLocal.p12"
P12_PASS="bettermac-local-dev"

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

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "    Using identity: $SIGN_IDENTITY"
  if ! codesign --force --deep --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP_DIR" 2>/dev/null; then
    echo "    Identity not usable (untrusted?) — falling back to ad-hoc"
    codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_DIR"
  fi
else
  echo "    No signing identity — using ad-hoc (Accessibility breaks every rebuild)"
  codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_DIR"
fi

echo "==> Built: $APP_DIR"
echo "Run with: open \"$APP_DIR\""

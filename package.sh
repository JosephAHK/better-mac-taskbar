#!/bin/bash
# Build installers into releases/, optionally publish a GitHub Release.
#
#   ./package.sh              # build .pkg + .dmg → releases/
#   ./package.sh --publish    # build, then tag + upload via `gh`
#
# Artifacts stay out of git — upload them to GitHub Releases instead.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Better Mac Taskbar"
BUNDLE_ID="com.bettermac.taskbar"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist" 2>/dev/null || echo "1.0.0")"
TAG="v${VERSION}"
SAFE_NAME="Better-Mac-Taskbar"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/${APP_NAME}.app"
PKG_ROOT="$BUILD_DIR/pkgroot"
RELEASES_DIR="$ROOT/releases"
PKG_OUT="$RELEASES_DIR/${SAFE_NAME}-${VERSION}.pkg"
DMG_OUT="$RELEASES_DIR/${SAFE_NAME}-${VERSION}.dmg"

PUBLISH=0
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    -h|--help)
      sed -n '2,10p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg (try --publish)" >&2
      exit 1
      ;;
  esac
done

echo "==> Building app (v${VERSION})"
BMT_NO_INSTALL=1 "$ROOT/build.sh"

if [[ ! -d "$APP_DIR" ]]; then
  echo "App bundle missing: $APP_DIR" >&2
  exit 1
fi

echo "==> Staging package payload"
rm -rf "$PKG_ROOT"
mkdir -p "$PKG_ROOT" "$RELEASES_DIR"
ditto "$APP_DIR" "$PKG_ROOT/${APP_NAME}.app"

echo "==> Building Installer package → $PKG_OUT"
pkgbuild \
  --root "$PKG_ROOT" \
  --install-location "/Applications" \
  --identifier "$BUNDLE_ID" \
  --version "$VERSION" \
  --min-os-version "13.0" \
  "$PKG_OUT"

echo "==> Building DMG → $DMG_OUT"
DMG_STAGE="$BUILD_DIR/dmgstage"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
ditto "$APP_DIR" "$DMG_STAGE/${APP_NAME}.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGE" \
  -ov \
  -format UDZO \
  "$DMG_OUT" >/dev/null
rm -rf "$DMG_STAGE" "$PKG_ROOT"

echo ""
echo "Release artifacts (not committed — upload to GitHub Releases):"
echo "  $PKG_OUT"
echo "  $DMG_OUT"
echo ""

if [[ "$PUBLISH" -eq 0 ]]; then
  echo "Next: ./package.sh --publish"
  echo "  (tags ${TAG}, creates a GitHub Release, uploads both files)"
  open "$RELEASES_DIR" 2>/dev/null || true
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is required to publish. Install with: brew install gh && gh auth login" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "Not logged into GitHub CLI. Run: gh auth login" >&2
  exit 1
fi

cd "$ROOT"

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "==> Tag ${TAG} already exists"
else
  echo "==> Creating tag ${TAG}"
  git tag -a "$TAG" -m "Release ${TAG}"
fi

echo "==> Pushing tag ${TAG}"
git push origin "$TAG"

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "==> Release ${TAG} exists — uploading assets"
  gh release upload "$TAG" "$PKG_OUT" "$DMG_OUT" --clobber
else
  echo "==> Creating GitHub Release ${TAG}"
  gh release create "$TAG" "$PKG_OUT" "$DMG_OUT" \
    --title "Better Mac Taskbar ${VERSION}" \
    --notes "Install with the **.pkg** (double-click Installer), or open the **.dmg** and drag the app into Applications.

After install, grant **Accessibility** in System Settings → Privacy & Security.

Requires macOS 13+ (Apple Silicon)."
fi

echo ""
echo "Published: $(gh release view "$TAG" --json url -q .url)"

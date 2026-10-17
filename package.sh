#!/bin/bash
# Build installers into releases/, optionally publish a GitHub Release.
#
#   ./package.sh                         # build .pkg + .dmg → releases/
#   ./package.sh --publish               # build, then tag + upload via `gh`
#   ./package.sh --publish --allow-unnotarized
#                                        # publish even without notarization
#
# Release signing needs a "Developer ID Application" and a "Developer ID
# Installer" identity in the keychain, plus a notarytool keychain profile named
# by $BMT_NOTARY_PROFILE (xcrun notarytool store-credentials <name> ...).
# Without them the artifacts are still built, but Gatekeeper will block them.
#
# Artifacts stay out of git — upload them to GitHub Releases instead.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Better Mac Taskbar"
BUNDLE_ID="com.bettermac.taskbar"
# Resources/Info.plist is the single source of truth for the marketing version.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
TAG="v${VERSION}"
SAFE_NAME="Better-Mac-Taskbar"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/${APP_NAME}.app"
PKG_ROOT="$BUILD_DIR/pkgroot"
RELEASES_DIR="$ROOT/releases"
PKG_OUT="$RELEASES_DIR/${SAFE_NAME}-${VERSION}.pkg"
DMG_OUT="$RELEASES_DIR/${SAFE_NAME}-${VERSION}.dmg"
ENTITLEMENTS="$ROOT/Resources/BetterMacTaskbar.entitlements"

PUBLISH=0
ALLOW_UNNOTARIZED=0
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    --allow-unnotarized) ALLOW_UNNOTARIZED=1 ;;
    -h|--help)
      sed -n '2,15p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg (try --publish)" >&2
      exit 1
      ;;
  esac
done

die() {
  echo "Error: $*" >&2
  exit 1
}

# Name of the first valid identity starting with $1; remaining args go to
# `security find-identity` (installer identities aren't codesigning identities).
find_identity() {
  local prefix="$1"
  shift
  security find-identity -v "$@" 2>/dev/null \
    | grep -F "\"$prefix" \
    | head -1 \
    | sed -E 's/.*"(.+)"/\1/' \
    || true
}

# ---- Publish preflight: fail before spending minutes on a build -----------

if [[ "$PUBLISH" -eq 1 ]]; then
  command -v gh >/dev/null 2>&1 \
    || die "gh is required to publish. Install with: brew install gh && gh auth login"
  gh auth status >/dev/null 2>&1 || die "Not logged into GitHub CLI. Run: gh auth login"

  cd "$ROOT"
  # The release must be reproducible from the tag; build.sh compiles every file
  # under Sources/, so untracked files count as dirty too.
  [[ -z "$(git status --porcelain)" ]] \
    || die "working tree is dirty — commit or remove changes before publishing."

  HEAD_COMMIT="$(git rev-parse HEAD)"
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    [[ "$(git rev-list -n 1 "$TAG")" == "$HEAD_COMMIT" ]] \
      || die "tag $TAG already exists on a different commit. Bump CFBundleShortVersionString in Resources/Info.plist."
  fi
  # Last line is the peeled commit for annotated tags, the commit itself otherwise.
  REMOTE_TAGS="$(git ls-remote origin "refs/tags/$TAG" "refs/tags/$TAG^{}")" \
    || die "couldn't reach origin to check whether $TAG already exists."
  REMOTE_TAG_COMMIT="$(printf '%s\n' "$REMOTE_TAGS" | tail -1 | cut -f1)"
  if [[ -n "$REMOTE_TAG_COMMIT" && "$REMOTE_TAG_COMMIT" != "$HEAD_COMMIT" ]]; then
    die "tag $TAG already exists on origin at a different commit. Bump CFBundleShortVersionString in Resources/Info.plist."
  fi
fi

# ---- Release signing prerequisites ----------------------------------------

APP_IDENTITY="$(find_identity "Developer ID Application" -p codesigning)"
INSTALLER_IDENTITY="$(find_identity "Developer ID Installer")"
NOTARY_PROFILE="${BMT_NOTARY_PROFILE:-}"

NOTARIZE=0
if [[ -n "$APP_IDENTITY" && -n "$INSTALLER_IDENTITY" && -n "$NOTARY_PROFILE" ]]; then
  NOTARIZE=1
else
  echo "" >&2
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
  echo "!!  NOT NOTARIZED — Gatekeeper will block these installers on other Macs." >&2
  [[ -z "$APP_IDENTITY" ]] && echo "!!  Missing: \"Developer ID Application\" signing identity" >&2
  [[ -z "$INSTALLER_IDENTITY" ]] && echo "!!  Missing: \"Developer ID Installer\" signing identity" >&2
  [[ -z "$NOTARY_PROFILE" ]] && echo "!!  Missing: BMT_NOTARY_PROFILE (xcrun notarytool store-credentials)" >&2
  echo "!!  Fine for local testing; not for distribution." >&2
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
  echo "" >&2
  if [[ "$PUBLISH" -eq 1 && "$ALLOW_UNNOTARIZED" -eq 0 ]]; then
    die "refusing to publish unnotarized artifacts. Pass --allow-unnotarized to override."
  fi
fi

# Submit, wait, and fail unless Apple accepted it. notarytool's exit status alone
# doesn't distinguish Accepted from Invalid, so read the status from its JSON.
notarize() {
  local file="$1" result status id
  echo "==> Notarizing $(basename "$file") (usually a few minutes)"
  result="$(xcrun notarytool submit "$file" --wait \
    --keychain-profile "$NOTARY_PROFILE" --output-format json)" \
    || die "notarytool submit failed for $file"
  status="$(printf '%s' "$result" | /usr/bin/plutil -extract status raw -o - - 2>/dev/null || true)"
  if [[ "$status" != "Accepted" ]]; then
    id="$(printf '%s' "$result" | /usr/bin/plutil -extract id raw -o - - 2>/dev/null || true)"
    echo "Notarization of $file finished with status: ${status:-unknown}" >&2
    [[ -n "$id" ]] && echo "  Details: xcrun notarytool log $id --keychain-profile \"$NOTARY_PROFILE\"" >&2
    exit 1
  fi
}

# ---- App -------------------------------------------------------------------

echo "==> Building app (v${VERSION})"
BMT_NO_INSTALL=1 "$ROOT/build.sh"

[[ -d "$APP_DIR" ]] || die "App bundle missing: $APP_DIR"

if [[ -n "$APP_IDENTITY" ]]; then
  # build.sh signed with the dev identity; re-sign for distribution. The bundle
  # has a single executable and no nested code, so no --deep and no inside-out
  # pass are needed.
  echo "==> Signing app for distribution: $APP_IDENTITY"
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --identifier "$BUNDLE_ID" \
    --sign "$APP_IDENTITY" \
    "$APP_DIR"
  codesign --verify --strict --verbose=2 "$APP_DIR"
fi

if [[ "$NOTARIZE" -eq 1 ]]; then
  # Staple the app itself too, so a copy installed by the pkg passes Gatekeeper
  # offline — stapling the pkg only covers the pkg file.
  APP_ZIP="$BUILD_DIR/${SAFE_NAME}-${VERSION}-app.zip"
  ditto -c -k --keepParent "$APP_DIR" "$APP_ZIP"
  notarize "$APP_ZIP"
  rm -f "$APP_ZIP"
  xcrun stapler staple "$APP_DIR"
fi

# ---- Installer package -----------------------------------------------------

echo "==> Staging package payload"
rm -rf "$PKG_ROOT"
mkdir -p "$PKG_ROOT" "$RELEASES_DIR"
ditto "$APP_DIR" "$PKG_ROOT/${APP_NAME}.app"

# Bundles are relocatable by default: if a copy with the same bundle id exists
# anywhere (e.g. a dev build), Installer "upgrades" that copy in place instead
# of installing to /Applications.
COMPONENT_PLIST="$BUILD_DIR/component.plist"
pkgbuild --analyze --root "$PKG_ROOT" "$COMPONENT_PLIST" >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$COMPONENT_PLIST"

echo "==> Building Installer package → $PKG_OUT"
UNSIGNED_PKG="$BUILD_DIR/${SAFE_NAME}-${VERSION}-unsigned.pkg"
pkgbuild \
  --root "$PKG_ROOT" \
  --component-plist "$COMPONENT_PLIST" \
  --install-location "/Applications" \
  --identifier "$BUNDLE_ID" \
  --version "$VERSION" \
  --min-os-version "13.0" \
  "$UNSIGNED_PKG"
rm -f "$COMPONENT_PLIST"

if [[ -n "$INSTALLER_IDENTITY" ]]; then
  echo "    Signing package: $INSTALLER_IDENTITY"
  productsign --timestamp --sign "$INSTALLER_IDENTITY" "$UNSIGNED_PKG" "$PKG_OUT"
  rm -f "$UNSIGNED_PKG"
else
  mv -f "$UNSIGNED_PKG" "$PKG_OUT"
fi

# ---- Disk image ------------------------------------------------------------

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

if [[ -n "$APP_IDENTITY" ]]; then
  codesign --force --timestamp --sign "$APP_IDENTITY" "$DMG_OUT"
fi

if [[ "$NOTARIZE" -eq 1 ]]; then
  notarize "$PKG_OUT"
  notarize "$DMG_OUT"
  xcrun stapler staple "$PKG_OUT"
  xcrun stapler staple "$DMG_OUT"
fi

echo ""
echo "Release artifacts (not committed — upload to GitHub Releases):"
echo "  $PKG_OUT"
echo "  $DMG_OUT"
if [[ "$NOTARIZE" -eq 1 ]]; then
  echo "  Signed, notarized and stapled."
else
  echo "  NOT notarized — Gatekeeper will block these on other Macs."
fi
echo ""

if [[ "$PUBLISH" -eq 0 ]]; then
  echo "Next: ./package.sh --publish"
  echo "  (tags ${TAG}, creates a GitHub Release, uploads both files)"
  open "$RELEASES_DIR" 2>/dev/null || true
  exit 0
fi

# ---- Publish ---------------------------------------------------------------

cd "$ROOT"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "==> Tag ${TAG} already points at HEAD"
else
  echo "==> Creating tag ${TAG}"
  git tag -a "$TAG" -m "Release ${TAG}"
fi

echo "==> Pushing tag ${TAG}"
git push origin "$TAG"

NOTES="Install with the **.pkg** (double-click Installer), or open the **.dmg** and drag the app into Applications.

After install, grant **Accessibility** in System Settings → Privacy & Security.

Requires macOS 13+ (Apple Silicon)."
if [[ "$NOTARIZE" -eq 0 ]]; then
  NOTES="$NOTES

**These builds are not notarized.** macOS will refuse to open them at first; right-click the app (or the installer) and choose **Open**, or allow it in System Settings → Privacy & Security."
fi

if gh release view "$TAG" >/dev/null 2>&1; then
  # Same tag, same commit: only a previous publish that stopped partway gets
  # here. No --clobber, so assets that were already uploaded are never replaced.
  echo "==> Release ${TAG} exists — uploading missing assets"
  # `gh release upload` fails outright if any named asset already exists, so
  # upload one at a time and skip what the earlier run got up.
  EXISTING_ASSETS="$(gh release view "$TAG" --json assets --jq '.assets[].name')"
  for asset in "$PKG_OUT" "$DMG_OUT"; do
    if grep -qxF "$(basename "$asset")" <<<"$EXISTING_ASSETS"; then
      echo "    $(basename "$asset") already uploaded — keeping it"
    else
      gh release upload "$TAG" "$asset"
    fi
  done
else
  echo "==> Creating GitHub Release ${TAG}"
  gh release create "$TAG" "$PKG_OUT" "$DMG_OUT" \
    --title "Better Mac Taskbar ${VERSION}" \
    --notes "$NOTES"
fi

echo ""
echo "Published: $(gh release view "$TAG" --json url -q .url)"

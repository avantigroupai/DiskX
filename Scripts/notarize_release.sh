#!/usr/bin/env bash
# Builds, Developer ID-signs, notarizes and staples a DiskX release for direct
# (non-App-Store) distribution, producing a notarized .app and a notarized DMG.
#
# Unlike the ad-hoc build from Scripts/package_app.sh, the artifact this script
# produces launches on a fresh Mac with no quarantine detour: no right-click →
# Open, no `xattr -d com.apple.quarantine`, no Privacy & Security panel.
#
# Prerequisites (one-time):
#   1. A "Developer ID Application: <Team> (<TeamID>)" certificate in the LOGIN
#      keychain. iCloud Keychain does NOT sync signing identities — import the
#      .p12 locally. Verify with:
#          security find-identity -v -p codesigning
#   2. A stored notarytool credential profile, created once with an
#      app-specific password from account.apple.com (NOT the Apple ID password):
#          xcrun notarytool store-credentials DiskX-Notary \
#            --apple-id "you@example.com" --team-id "579VUWVTXN" --password "abcd-efgh-ijkl-mnop"
#      A profile is per Apple ID + team, not per app, so an existing profile for
#      the same team works as-is:  NOTARY_PROFILE=WOS-Notary Scripts/notarize_release.sh
#   3. The team's Apple Developer Program agreements must be in effect.
#      A 403 "required agreement is missing or has expired" means the Account
#      Holder has to accept the current agreement at developer.apple.com →
#      Account → Agreements before any submission will be accepted.
#
# Usage:
#   Scripts/notarize_release.sh                 # full flow: build → sign → notarize → staple
#   SKIP_NOTARIZE=1 Scripts/notarize_release.sh # build + Developer ID sign only (no submission)
#
# Environment overrides:
#   APP_IDENTITY     signing identity (auto-detected from the keychain if unset)
#   NOTARY_PROFILE   notarytool keychain profile name (default: DiskX-Notary)
#   APPLE_ID / APPLE_TEAM_ID / APPLE_PASSWORD  inline credentials instead of a profile
#   ARCHES           space-separated arch list (default: "arm64 x86_64" universal)
#   DIST_DIR         output directory (default: <root>/dist)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source "$ROOT/version.env"

DIST_DIR="${DIST_DIR:-$ROOT/dist}"
NOTARY_PROFILE="${NOTARY_PROFILE:-DiskX-Notary}"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"
APPLE_ID="${APPLE_ID:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
APPLE_PASSWORD="${APPLE_PASSWORD:-}"

# Universal by default: a Developer ID build is what Intel users download, and
# an arm64-only DMG fails on those machines in a way notarization won't catch.
export ARCHES="${ARCHES:-arm64 x86_64}"

# ---------------------------------------------------------------------------
# 1. Resolve the signing identity.
# ---------------------------------------------------------------------------
if [[ -z "${APP_IDENTITY:-}" ]]; then
  APP_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application:" \
    | head -1 \
    | sed -E 's/.*"(.*)".*/\1/')
fi

if [[ -z "$APP_IDENTITY" ]]; then
  cat >&2 <<'ERR'
ERROR: No "Developer ID Application" identity found in the keychain.

Notarization requires a real Developer ID certificate — an ad-hoc signature
cannot be notarized. Import the .p12 into your LOGIN keychain (iCloud Keychain
does not sync signing identities), then re-run. Check with:

    security find-identity -v -p codesigning
ERR
  exit 1
fi

# The team id in parentheses is what notarytool matches the signature against.
TEAM_ID=$(sed -E 's/.*\(([A-Z0-9]+)\)$/\1/' <<<"$APP_IDENTITY")

echo "==> Identity:  $APP_IDENTITY"
echo "==> Team:      $TEAM_ID"
echo "==> Version:   $MARKETING_VERSION ($BUILD_NUMBER)"
echo "==> Arches:    $ARCHES"
echo

# ---------------------------------------------------------------------------
# 2. Build + sign the .app via the shared packager.
#
# Hardened runtime and a secure timestamp are both mandatory for notarization;
# package_app.sh applies them whenever SIGNING_MODE=identity.
# ---------------------------------------------------------------------------
APP_ENTITLEMENTS="$ROOT/Entitlements/DiskX-DeveloperID.entitlements"
export APP_ENTITLEMENTS
export SIGNING_MODE=identity
export APP_IDENTITY

"$ROOT/Scripts/package_app.sh" release

APP="$ROOT/${APP_NAME}.app"

echo
echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

if [[ "$SKIP_NOTARIZE" == "1" ]]; then
  echo
  echo "SKIP_NOTARIZE=1 — stopping after Developer ID signing."
  echo "Signed (not yet notarized): $APP"
  exit 0
fi

mkdir -p "$DIST_DIR"

# ---------------------------------------------------------------------------
# 3. Submit to the notary service.
#
# Two-stage on purpose: the .app is notarized and stapled FIRST, then embedded
# in the DMG, then the DMG is notarized and stapled. Notarizing only the DMG
# (the common shortcut) leaves the extracted .app without its own ticket, so a
# user who drags it to /Applications and first launches it offline gets the
# Gatekeeper prompt anyway — Gatekeeper has to reach Apple to verify.
# ---------------------------------------------------------------------------
notarize() {
  local target="$1"
  local output status
  set +e
  if [[ -n "$APPLE_ID" && -n "$APPLE_TEAM_ID" && -n "$APPLE_PASSWORD" ]]; then
    # SECURITY: --password puts the app-specific password in this process's argv,
    # where any local user can read it with ps for the whole --wait window (often
    # several minutes). The keychain-profile path below avoids that entirely.
    echo "WARNING: using inline APPLE_PASSWORD — it is visible in 'ps' output while" >&2
    echo "         notarization runs. Prefer a stored profile:" >&2
    echo "         xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\" >&2
    echo "           --apple-id ... --team-id ... --password ...    (then unset APPLE_PASSWORD)" >&2
    output=$(xcrun notarytool submit "$target" \
      --apple-id "$APPLE_ID" \
      --team-id "$APPLE_TEAM_ID" \
      --password "$APPLE_PASSWORD" \
      --wait 2>&1)
  else
    output=$(xcrun notarytool submit "$target" \
      --keychain-profile "$NOTARY_PROFILE" \
      --wait 2>&1)
  fi
  status=$?
  set -e
  echo "$output"

  # notarytool exits 0 on some server-side rejections, so match the message
  # rather than trusting the exit status alone.
  if grep -q "required agreement is missing or has expired" <<<"$output"; then
    cat >&2 <<ERR

BLOCKED: Apple rejected the submission at the account level, not because of
anything in this build.

Team $TEAM_ID has an Apple Developer Program agreement that is unsigned or
expired, and the notary service refuses every submission until it is in effect.
Only the team's Account Holder can clear this:

    developer.apple.com -> Account -> Agreements   (accept the current agreement)

App Store Connect -> Business -> Agreements may also show a pending item. After
accepting, re-run this script; nothing else here needs to change.
ERR
    exit 1
  fi

  if [[ $status -ne 0 ]] || grep -qi "status: Invalid" <<<"$output"; then
    echo >&2
    echo "ERROR: notarization failed for $target." >&2
    echo "Fetch the detailed log with:" >&2
    echo "    xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE" >&2
    exit 1
  fi
}

# notarytool only accepts zip/dmg/pkg containers, never a bare .app directory.
# ditto --keepParent preserves the bundle structure the service expects.
APP_ZIP="$DIST_DIR/${APP_NAME}-${MARKETING_VERSION}.zip"
rm -f "$APP_ZIP"
# The zip is a transport container for the notary service only; never leave it
# in dist/ where it could be mistaken for a release artifact.
trap 'rm -f "$APP_ZIP"' EXIT

echo
echo "==> Notarizing the app bundle"
/usr/bin/ditto -c -k --keepParent "$APP" "$APP_ZIP"
notarize "$APP_ZIP"

echo
echo "==> Stapling ticket to the app"
xcrun stapler staple "$APP"
rm -f "$APP_ZIP"

# ---------------------------------------------------------------------------
# 4. Package the stapled app into a DMG, then notarize that too.
# ---------------------------------------------------------------------------
DMG="$DIST_DIR/${APP_NAME}-${MARKETING_VERSION}.dmg"
DMG_STAGING="$DIST_DIR/.dmg-staging"

rm -rf "$DMG_STAGING"
rm -f "$DMG"
mkdir -p "$DMG_STAGING"
cp -R "$APP" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

echo
echo "==> Building DMG"
hdiutil create \
  -volname "$APP_NAME $MARKETING_VERSION" \
  -srcfolder "$DMG_STAGING" \
  -ov -format UDZO \
  "$DMG" >/dev/null
rm -rf "$DMG_STAGING"

echo "==> Signing DMG"
codesign --force --timestamp --sign "$APP_IDENTITY" "$DMG"

echo
echo "==> Notarizing the DMG"
notarize "$DMG"

echo
echo "==> Stapling ticket to the DMG"
xcrun stapler staple "$DMG"

# ---------------------------------------------------------------------------
# 5. Verify what a first-launch actually sees.
#
# The string to look for is "source=Notarized Developer ID". A merely signed
# build reports "source=Unnotarized Developer ID" and still triggers the
# "Apple cannot check it for malicious software" dialog.
# ---------------------------------------------------------------------------
echo
echo "==> Gatekeeper assessment"
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type install --verbose=2 "$DMG"
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"

echo
echo "Notarized and stapled:"
echo "  $APP"
echo "  $DMG"

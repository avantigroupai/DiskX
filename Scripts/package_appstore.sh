#!/usr/bin/env bash
# Builds the Mac App Store variant of DiskX: sandboxed, signed with App Store
# distribution identities, wrapped in a signed installer .pkg for upload via
# Transporter or `xcrun altool`/App Store Connect API.
#
# Prerequisites (one-time, needs an Apple Developer Program membership):
#   1. In Xcode → Settings → Accounts, create these certificates:
#        "Apple Distribution: <Team Name> (<TeamID>)"
#        "3rd Party Mac Developer Installer: <Team Name> (<TeamID>)"
#   2. Create an app record in App Store Connect with bundle id from version.env.
#   3. Create a Mac App Store provisioning profile for that bundle id and
#      save it as Entitlements/DiskX.provisionprofile (embedded below).
#
# Usage:
#   APP_IDENTITY="Apple Distribution: ..." \
#   INSTALLER_IDENTITY="3rd Party Mac Developer Installer: ..." \
#   Scripts/package_appstore.sh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source "$ROOT/version.env"

: "${APP_IDENTITY:?Set APP_IDENTITY to your 'Apple Distribution: ...' identity}"
: "${INSTALLER_IDENTITY:?Set INSTALLER_IDENTITY to your '3rd Party Mac Developer Installer: ...' identity}"

# Sandbox entitlements + distribution signing.
export APP_ENTITLEMENTS="$ROOT/Entitlements/DiskX-AppStore.entitlements"
export SIGNING_MODE=identity
export APP_IDENTITY

"$ROOT/Scripts/package_app.sh" release

APP="$ROOT/${APP_NAME}.app"

# Embed the provisioning profile if present (required for MAS validation).
PROFILE="$ROOT/Entitlements/DiskX.provisionprofile"
if [[ -f "$PROFILE" ]]; then
  cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
  # Re-sign after modifying the bundle.
  codesign --force --timestamp --options runtime \
    --entitlements "$APP_ENTITLEMENTS" --sign "$APP_IDENTITY" "$APP"
else
  echo "WARNING: $PROFILE not found — App Store validation will reject the build without it." >&2
fi

# Installer package for upload.
PKG="$ROOT/${APP_NAME}-${MARKETING_VERSION}.pkg"
productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$PKG"

echo
echo "Created $PKG"
echo "Upload with: xcrun altool --upload-app -f \"$PKG\" -t macos ... (or use Transporter.app)"

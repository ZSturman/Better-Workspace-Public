#!/bin/bash
# Validate a packaged release in an owned, quarantined extraction; never install it.
set -euo pipefail
if [ "$#" -ne 1 ]; then
  echo "Usage: bash Tools/verify_mac_download.sh /path/to/BetterWorkspace.zip" >&2
  exit 2
fi
package="$1"
test -f "$package"
verification_root="$(mktemp -d "${TMPDIR:-/tmp/}bw-download-verification-XXXXXX")"
ditto -x -k "$package" "$verification_root"
# Public packages use the human-readable installation name. Retain verification
# support for historical ZIPs without forcing a second app beside an installation.
application="$verification_root/Better Workspace.app"
if [ ! -d "$application" ]; then
  application="$verification_root/BetterWorkspace.app"
fi
test -d "$application"
# Add a quarantine marker to our copy, preserving the actual release package.
xattr -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");BetterWorkspaceReleaseVerification;$(uuidgen)" "$application"
codesign --verify --deep --strict --verbose=2 "$application"
xcrun stapler validate "$application"
spctl --assess --type execute --verbose=4 "$application"
shasum -a 256 "$package"
echo "Verified quarantined extraction retained at: $verification_root"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
channel="${1:-mobile}"
case "$channel" in
  mobile) scheme=BetterWorkspaceMobile; destination='generic/platform=iOS'; directory=AppStore ;;
  mac) scheme=BetterWorkspace; destination='generic/platform=macOS'; directory=MacDownload ;;
  # The sandboxed personal-only Mac Store edition is retired; the advanced Mac is the Mac app.
  mac-store) echo 'mac-store is retired: archive the advanced Mac with "mac" instead.' >&2; exit 2 ;;
  *) echo 'Usage: bash Tools/archive_release.sh [mobile|mac]' >&2; exit 2 ;;
esac
build_number="${BUILD_NUMBER:-1}"
if [[ ! "$build_number" =~ ^[0-9]+$ ]]; then
  echo 'BUILD_NUMBER must be a nonnegative integer.' >&2; exit 2
fi
archive="build/$directory/$scheme-$build_number.xcarchive"
if [[ -e "$archive" ]]; then
  echo "Archive already exists: $archive. Set a new BUILD_NUMBER or move it aside." >&2; exit 2
fi
build_arguments=(-project BetterWorkspace.xcodeproj -scheme "$scheme"
  -configuration Release -destination "$destination"
  -archivePath "$archive" -allowProvisioningUpdates
  "MARKETING_VERSION=${RELEASE_VERSION:-1.0}" "CURRENT_PROJECT_VERSION=$build_number")
# Optional existing API credentials support CI/local provisioning when the Xcode
# GUI account session is unavailable. Never copy the key into this repository.
if [[ -n "${APP_STORE_CONNECT_API_KEY_PATH:-}${APP_STORE_CONNECT_API_KEY_ID:-}${APP_STORE_CONNECT_API_ISSUER_ID:-}" ]]; then
  if [[ ! -f "${APP_STORE_CONNECT_API_KEY_PATH:-}" || -z "${APP_STORE_CONNECT_API_KEY_ID:-}" || -z "${APP_STORE_CONNECT_API_ISSUER_ID:-}" ]]; then
    echo 'Set all three APP_STORE_CONNECT_API_KEY_PATH / API_KEY_ID / API_ISSUER_ID values to existing credentials.' >&2
    exit 2
  fi
  build_arguments+=(-authenticationKeyPath "$APP_STORE_CONNECT_API_KEY_PATH" -authenticationKeyID "$APP_STORE_CONNECT_API_KEY_ID" -authenticationKeyIssuerID "$APP_STORE_CONNECT_API_ISSUER_ID")
fi
if [[ "$channel" == "mac" ]]; then
  python3 Tools/prepare_python_runtime.py
  runtime_signing_identity="$(security find-identity -v -p codesigning | awk '/Developer ID Application:/ {print $2; exit}')"
  if [[ -z "$runtime_signing_identity" ]]; then
    echo 'Developer ID Application signing is required for the embedded production runtime.' >&2; exit 2
  fi
  build_arguments+=(BW_REQUIRE_EMBEDDED_PYTHON=YES "BETTER_WORKSPACE_RUNTIME_SIGNING_IDENTITY=$runtime_signing_identity")
fi
xcodegen generate
xcodebuild "${build_arguments[@]}" archive
echo "Archive ready for Xcode Organizer validation: $archive"
echo 'Read docs/APP_STORE_RELEASE.md before exporting or uploading.'

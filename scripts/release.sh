#!/usr/bin/env bash
#
# Archive SameAge and ship it to TestFlight.
#
#   ./scripts/release.sh            # archive + export a local .ipa (no upload)
#   ./scripts/release.sh --upload   # archive + upload to App Store Connect
#
# Requires .env (gitignored) with ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH.
# The App Store Connect app record must already exist for --upload; there is no API
# to create one, so that step is browser-only and done once.

# Deliberately no `pipefail`: several display-only pipes end in `head`/`tail`, which
# close the pipe early and hand the producer a SIGPIPE. Under pipefail that aborts the
# whole release with exit 141 and no output. Every command whose failure actually
# matters (xcodebuild, swift test) is unpiped or checked explicitly.
set -eu

cd "$(dirname "$0")/.."

# Xcode 26+ is mandatory: App Store Connect has rejected uploads built with anything
# older since 2026-04-28. xcode-select on this machine points at the Command Line
# Tools, so select Xcode explicitly rather than relying on the system default.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ ! -f .env ]]; then
  echo "error: .env not found. See HANDOFF.md for the App Store Connect key setup." >&2
  exit 1
fi
set -a; source .env; set +a

for var in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH; do
  if [[ -z "${!var:-}" ]]; then echo "error: $var missing from .env" >&2; exit 1; fi
done
if [[ ! -f "$ASC_KEY_PATH" ]]; then
  echo "error: API key not found at $ASC_KEY_PATH" >&2
  echo "       The .p8 is downloadable from Apple exactly once; if lost, revoke the key" >&2
  echo "       and generate a new one at appstoreconnect.apple.com/access/integrations/api" >&2
  exit 1
fi

# `sed -n 1p` rather than `head -1`: sed drains the stream instead of closing the pipe.
XCODE_VERSION="$(xcodebuild -version 2>/dev/null | sed -n '1p')"
case "$XCODE_VERSION" in
  "Xcode 2"[6-9]*) ;;
  *) echo "error: $XCODE_VERSION cannot upload. Apple requires Xcode 26 or later." >&2; exit 1 ;;
esac

UPLOAD=false
[[ "${1:-}" == "--upload" ]] && UPLOAD=true

ARCHIVE="build/SameAge.xcarchive"
EXPORT_DIR="build/export"
OPTIONS="ExportOptions.plist"

AUTH=(
  -allowProvisioningUpdates
  -authenticationKeyPath "$ASC_KEY_PATH"
  -authenticationKeyID "$ASC_KEY_ID"
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
)

echo "==> Regenerating project"
command -v xcodegen >/dev/null || { echo "error: xcodegen not installed (brew install xcodegen)" >&2; exit 1; }
xcodegen generate >/dev/null

echo "==> Testing"
# Capture rather than pipe: piping into `tail` closes the pipe early, and under
# `set -o pipefail` the resulting SIGPIPE aborts the whole release.
TEST_LOG="$(mktemp -t sameage-tests)"
if ! (cd Packages/SameAgeCore && swift test > "$TEST_LOG" 2>&1); then
  echo "error: tests failed" >&2
  tail -30 "$TEST_LOG" >&2
  exit 1
fi
grep -E "Executed [0-9]+ tests" "$TEST_LOG" | tail -1

echo "==> Archiving ($XCODE_VERSION)"
rm -rf "$ARCHIVE"
xcodebuild -project SameAge.xcodeproj -scheme SameAge \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  "${AUTH[@]}" \
  archive

if $UPLOAD; then
  # Swap destination to upload without editing the checked-in plist.
  OPTIONS="$(mktemp -t sameage-export).plist"
  cp ExportOptions.plist "$OPTIONS"
  plutil -replace destination -string upload "$OPTIONS"
  echo "==> Uploading to App Store Connect"
else
  echo "==> Exporting local .ipa"
fi

rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$OPTIONS" \
  "${AUTH[@]}"

if $UPLOAD; then
  echo
  echo "Uploaded. Processing usually takes 5-15 minutes, then the build appears under"
  echo "TestFlight in App Store Connect. Internal testers need no Beta App Review."
else
  echo
  ls -lh "$EXPORT_DIR"
  echo
  echo "Local .ipa only. Re-run with --upload to send it to TestFlight."
fi

#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail

if [[ ! ${APPLE_TEAM_ID:-} =~ ^[A-Z0-9]{10}$ ||
      ! ${APPLE_API_KEY_ID:-} =~ ^[A-Z0-9]{10}$ ||
      ! ${APPLE_API_ISSUER:-} =~ ^[0-9A-Fa-f-]{36}$ ||
      ${APPLE_API_KEY_P8:-} != *"BEGIN PRIVATE KEY"* ]]; then
    echo "::error::Set the four Apple values in the testflight GitHub environment before running the upload."
    exit 1
fi

umask 077
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/moonlight-testflight.XXXXXX")"
key="$work/AuthKey_${APPLE_API_KEY_ID}.p8"
trap 'rm -f "$key"' EXIT
printf '%s\n' "$APPLE_API_KEY_P8" > "$key"
unset APPLE_API_KEY_P8
openssl pkey -in "$key" -noout -check >/dev/null

auth=(-allowProvisioningUpdates -authenticationKeyPath "$key"
      -authenticationKeyID "$APPLE_API_KEY_ID" -authenticationKeyIssuerID "$APPLE_API_ISSUER")

xcodebuild -project Moonlight.xcodeproj -scheme Moonlight \
    -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$work/MoonlightDuo.xcarchive" \
    -onlyUsePackageVersionsFromResolvedFile "${auth[@]}" \
    CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
    MARKETING_VERSION=1.0 CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-1}" archive

cat > "$work/export.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$APPLE_TEAM_ID</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>testFlightInternalTestingOnly</key><true/>
</dict></plist>
EOF

xcodebuild -exportArchive -archivePath "$work/MoonlightDuo.xcarchive" \
    -exportPath "$work/upload" -exportOptionsPlist "$work/export.plist" "${auth[@]}"

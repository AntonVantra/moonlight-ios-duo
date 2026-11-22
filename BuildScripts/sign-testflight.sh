#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail

bundle=com.antonvantra.moonlight.duo
for variable in MOONLIGHT_CERTIFICATE MOONLIGHT_CERTIFICATE_PASSWORD MOONLIGHT_PROFILE MOONLIGHT_UPLOAD_KEY_ID MOONLIGHT_UPLOAD_PRIVATE_KEY; do
    if [[ -z ${!variable:-} ]]; then
        echo "::error::Missing $variable in the Moonlight TestFlight environment."
        exit 1
    fi
done
if [[ ! "$MOONLIGHT_UPLOAD_KEY_ID" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "::error::Apple's individual API key ID must be a ten-character identifier."
    exit 1
fi

umask 077
work="$(mktemp -d "$RUNNER_TEMP/moonlight-duo-signing.XXXXXX")"
keychain="$work/moonlight.keychain-db"
profile_install=
cleanup() {
    security delete-keychain "$keychain" >/dev/null 2>&1 || true
    if [[ -n "$profile_install" ]]; then rm -f "$profile_install"; fi
    rm -rf "$work"
}
trap cleanup EXIT
printf '%s' "$MOONLIGHT_CERTIFICATE" | base64 -D > "$work/distribution.p12"
printf '%s' "$MOONLIGHT_PROFILE" | base64 -D > "$work/profile.mobileprovision"
mkdir -p "$work/private_keys"
key="$work/private_keys/AuthKey_${MOONLIGHT_UPLOAD_KEY_ID}.p8"
printf '%s\n' "$MOONLIGHT_UPLOAD_PRIVATE_KEY" > "$key"
unset MOONLIGHT_CERTIFICATE MOONLIGHT_PROFILE MOONLIGHT_UPLOAD_PRIVATE_KEY

# Confirm the individual key can see just this app before importing a signing key.
token="$(ruby -r openssl -r json -r base64 - "$key" "$MOONLIGHT_UPLOAD_KEY_ID" <<'RUBY'
key = OpenSSL::PKey.read(File.binread(ARGV[0]))
abort "Expected Apple's P-256 individual API key" unless key.is_a?(OpenSSL::PKey::EC) && key.group.curve_name == "prime256v1"
encode = ->(value) { Base64.urlsafe_encode64(value, padding: false) }
now = Time.now.to_i
header = { alg: "ES256", kid: ARGV[1], typ: "JWT" }
payload = { sub: "user", iat: now, exp: now + 300, aud: "appstoreconnect-v1" }
data = [encode.call(header.to_json), encode.call(payload.to_json)].join(".")
signature = OpenSSL::ASN1.decode(key.sign("SHA256", data)).value.map do |integer|
  integer.value.to_s(2).rjust(32, "\x00")
end.join
puts "#{data}.#{encode.call(signature)}"
RUBY
)"
echo "::add-mask::$token"
curl --fail --silent --show-error --max-time 30 \
    -H "Authorization: Bearer $token" 'https://api.appstoreconnect.apple.com/v1/apps?limit=2' \
    -o "$work/accessible-apps.json"
unset token

/usr/bin/security cms -D -i "$work/profile.mobileprovision" > "$work/profile.plist"
openssl pkcs12 -in "$work/distribution.p12" -clcerts -nokeys \
    -passin env:MOONLIGHT_CERTIFICATE_PASSWORD | openssl x509 -outform DER > "$work/distribution.der"

python3 - "$work" "$bundle" <<'PY'
import datetime
import hashlib
import json
import pathlib
import plistlib
import re
import sys

work = pathlib.Path(sys.argv[1])
bundle = sys.argv[2]
access = json.loads((work / "accessible-apps.json").read_text())
if [app["attributes"]["bundleId"] for app in access["data"]] != [bundle] or access.get("links", {}).get("next"):
    sys.exit("The upload account must have access to Moonlight Duo only.")

with (work / "profile.plist").open("rb") as file:
    profile = plistlib.load(file)
team = profile["TeamIdentifier"][0]
uuid = profile["UUID"]
entitlements = profile["Entitlements"]
if not re.fullmatch(r"[A-Z0-9]{10}", team) or not re.fullmatch(r"[0-9A-Fa-f-]{36}", uuid):
    sys.exit("Unexpected team or provisioning profile identifier.")
if entitlements.get("application-identifier") != f"{team}.{bundle}":
    sys.exit("The provisioning profile must be for the explicit Moonlight Duo bundle ID.")
if entitlements.get("get-task-allow") or profile.get("ProvisionedDevices") or profile.get("ProvisionsAllDevices"):
    sys.exit("Use an App Store Connect distribution profile for TestFlight.")
expires = profile["ExpirationDate"].replace(tzinfo=datetime.timezone.utc)
if expires <= datetime.datetime.now(datetime.timezone.utc):
    sys.exit("The Moonlight Duo provisioning profile has expired.")
certificate = (work / "distribution.der").read_bytes()
if profile["DeveloperCertificates"] != [certificate]:
    sys.exit("The profile must contain the uploaded Moonlight Duo distribution certificate.")
identity = hashlib.sha1(certificate).hexdigest().upper()
(work / "settings").write_text(f"{team}\n{uuid}\n{identity}\n")
with (work / "export.plist").open("wb") as file:
    plistlib.dump({
        "method": "app-store-connect",
        "destination": "export",
        "teamID": team,
        "signingStyle": "manual",
        "signingCertificate": identity,
        "provisioningProfiles": {bundle: uuid},
        "testFlightInternalTestingOnly": True,
        "manageAppVersionAndBuildNumber": False,
    }, file)
PY

team="$(sed -n '1p' "$work/settings")"
profile_uuid="$(sed -n '2p' "$work/settings")"
identity="$(sed -n '3p' "$work/settings")"
echo "::add-mask::$team"

keychain_password="$(openssl rand -hex 32)"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security list-keychains -d user -s "$keychain"
security import "$work/distribution.p12" -k "$keychain" -P "$MOONLIGHT_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
unset MOONLIGHT_CERTIFICATE_PASSWORD
security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" >/dev/null
if ! security find-identity -v -p codesigning "$keychain" | grep -Fq "$identity"; then
    curl --fail --silent --show-error --max-time 30 \
        'https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer' -o "$work/wwdr.cer"
    security import "$work/wwdr.cer" -k "$keychain" >/dev/null
    security find-identity -v -p codesigning "$keychain" | grep -Fq "$identity"
fi

profile_dir="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
mkdir -p "$profile_dir"
profile_install="$profile_dir/$profile_uuid.mobileprovision"
cp "$work/profile.mobileprovision" "$profile_install"

archive="$work/MoonlightDuo.xcarchive"
xcodebuild -project Moonlight.xcodeproj -scheme Moonlight -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$archive" -onlyUsePackageVersionsFromResolvedFile \
    CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$team" CODE_SIGN_IDENTITY="$identity" \
    MOONLIGHT_DUO_PROFILE="$profile_uuid" MARKETING_VERSION=1.0 \
    CURRENT_PROJECT_VERSION="$GITHUB_RUN_NUMBER.$GITHUB_RUN_ATTEMPT" archive
codesign --verify --strict "$archive/Products/Applications/Moonlight.app"

xcodebuild -exportArchive -archivePath "$archive" -exportPath "$work/export" \
    -exportOptionsPlist "$work/export.plist"
ipa="$work/export/Moonlight.ipa"
if [[ ! -s "$ipa" ]]; then
    echo "::error::Xcode did not export the expected Moonlight Duo IPA."
    exit 1
fi

unzip -q "$ipa" -d "$work/verify"
app="$work/verify/Payload/Moonlight.app"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist" | grep -Fx "$bundle"
codesign --verify --strict "$app"

cd "$work"
xcrun altool --upload-app -f "$ipa" -t ios --api-key "$MOONLIGHT_UPLOAD_KEY_ID" \
    --api-key-subject user --output-format json

# SPDX-License-Identifier: GPL-3.0-only
"""Submit the signed Moonlight Duo IPA through Apple's Build Upload API."""

import json
import pathlib
import plistlib
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile


API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE = "com.antonvantra.moonlight.duo"


def api_request(token, method, path, body):
    request = urllib.request.Request(
        API + path,
        data=json.dumps({"data": body}).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        method=method,
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            result = response.read()
            return json.loads(result).get("data") if result else None
    except urllib.error.HTTPError as error:
        try:
            details = json.load(error).get("errors", [])
        except ValueError:
            details = []
        summary = "; ".join(
            f"{item.get('code', '')} {item.get('detail', item.get('title', ''))}"
            for item in details
        )
        raise SystemExit(f"Apple returned HTTP {error.code} for {method} {path}. {summary}") from None


def transfer_file(token, build_upload_id, path, asset_type, uti):
    content = path.read_bytes()
    reserved = api_request(token, "POST", "/buildUploadFiles", {
        "type": "buildUploadFiles",
        "attributes": {
            "fileName": path.name,
            "fileSize": len(content),
            "assetType": asset_type,
            "uti": uti,
        },
        "relationships": {
            "buildUpload": {"data": {"type": "buildUploads", "id": build_upload_id}},
        },
    })
    operations = reserved["attributes"]["uploadOperations"]
    offset = 0
    for operation in sorted(operations, key=lambda value: value["offset"]):
        url = urllib.parse.urlsplit(operation["url"])
        end = offset + operation["length"]
        if (
            url.scheme != "https" or not url.hostname or url.username or url.password
            or operation["method"] != "PUT" or operation["offset"] != offset
            or end <= offset or end > len(content)
        ):
            raise SystemExit("Apple supplied an unexpected asset upload instruction.")
        request = urllib.request.Request(
            operation["url"],
            data=content[offset:end],
            headers={item["name"]: item["value"] for item in operation.get("requestHeaders") or []},
            method="PUT",
        )
        try:
            with urllib.request.urlopen(request, timeout=90) as response:
                if response.status not in (200, 201, 204):
                    raise SystemExit(f"Apple's asset server returned HTTP {response.status}.")
        except urllib.error.URLError as error:
            status = getattr(error, "code", None)
            raise SystemExit(f"The signed asset upload failed with HTTP status {status}.") from None
        offset = end
    if offset != len(content):
        raise SystemExit("Apple did not reserve the complete file.")
    api_request(token, "PATCH", f"/buildUploadFiles/{reserved['id']}", {
        "type": "buildUploadFiles",
        "id": reserved["id"],
        "attributes": {"uploaded": True},
    })
    print(f"Apple received {asset_type}.", flush=True)


def main():
    ipa = pathlib.Path(sys.argv[1])
    visible = json.loads(pathlib.Path(sys.argv[2]).read_text())
    apps = visible["data"]
    if [app["attributes"]["bundleId"] for app in apps] != [BUNDLE] or visible.get("links", {}).get("next"):
        raise SystemExit("The upload account must have access to Moonlight Duo only.")
    token = sys.stdin.read().strip()
    if not token:
        raise SystemExit("Missing the scoped App Store Connect token.")
    with zipfile.ZipFile(ipa) as archive:
        app = plistlib.loads(archive.read("Payload/Moonlight.app/Info.plist"))
    if app["CFBundleIdentifier"] != BUNDLE:
        raise SystemExit("The signed IPA does not belong to Moonlight Duo.")

    upload = api_request(token, "POST", "/buildUploads", {
        "type": "buildUploads",
        "attributes": {
            "cfBundleShortVersionString": app["CFBundleShortVersionString"],
            "cfBundleVersion": app["CFBundleVersion"],
            "platform": "IOS",
        },
        "relationships": {
            "app": {"data": {"type": "apps", "id": apps[0]["id"]}},
        },
    })
    print(f"Apple reserved Moonlight Duo build {app['CFBundleVersion']}.", flush=True)

    description = ipa.with_name("AppStoreInfo.plist")
    if description.is_file():
        with description.open("rb") as file:
            binary_plist = file.read(8) == b"bplist00"
        uti = "com.apple.binary-property-list" if binary_plist else "com.apple.xml-property-list"
        transfer_file(token, upload["id"], description, "ASSET_DESCRIPTION", uti)
    transfer_file(token, upload["id"], ipa, "ASSET", "com.apple.ipa")


if __name__ == "__main__":
    main()

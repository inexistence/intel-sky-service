#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd)"
project_directory="$(dirname "$script_directory")"
output_directory="${OUTPUT_DIRECTORY:-$project_directory/dist}"
app_path="$output_directory/Intel Sky Service.app"
temporary_directory="$(mktemp -d)"
temporary_app="$temporary_directory/Intel Sky Service.app"
requested_identity="${CODESIGN_IDENTITY:-Apple Development: 510229374@qq.com (YP98F3PUMT)}"

cleanup() {
  rm -rf "$temporary_directory"
}
trap cleanup EXIT

cd "$project_directory"
swift build -c release --arch x86_64 -Xswiftc -warnings-as-errors

mkdir -p "$temporary_app/Contents/MacOS"
cp "$project_directory/Packaging/Info.plist" "$temporary_app/Contents/Info.plist"
cp "$project_directory/.build/x86_64-apple-macosx/release/intel-sky-service" \
  "$temporary_app/Contents/MacOS/SkyComputerUseService"
chmod 755 "$temporary_app/Contents/MacOS/SkyComputerUseService"

signing_identity="-"
if security find-identity -v -p codesigning | grep -Fq "\"$requested_identity\""; then
  signing_identity="$requested_identity"
else
  echo "warning: requested signing identity is unavailable; using ad-hoc signing" >&2
fi
codesign --force --options runtime --sign "$signing_identity" "$temporary_app"
codesign --verify --deep --strict --verbose=2 "$temporary_app"

mkdir -p "$output_directory"
rm -rf "$app_path"
mv "$temporary_app" "$app_path"

echo "$app_path"
codesign -dvv "$app_path" 2>&1 | grep -E '^(Identifier|TeamIdentifier|Signature)='

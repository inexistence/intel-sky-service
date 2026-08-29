#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd)"
project_directory="$(dirname "$script_directory")"
source_app="${1:-$project_directory/dist/Intel Sky Service.app}"
install_directory="$HOME/Applications"
installed_app="$install_directory/Intel Sky Service.app"
agent_directory="$HOME/Library/LaunchAgents"
agent_path="$agent_directory/dev.huangjianbin.intel-sky-service.plist"
executable_path="$installed_app/Contents/MacOS/SkyComputerUseService"
service_target="gui/$UID/dev.huangjianbin.intel-sky-service"
temporary_directory=""

cleanup() {
  if [[ -n "$temporary_directory" ]]; then
    rm -rf "$temporary_directory"
  fi
}
trap cleanup EXIT

if [[ ! -x "$source_app/Contents/MacOS/SkyComputerUseService" ]]; then
  echo "built app not found: $source_app" >&2
  exit 66
fi

mkdir -p "$install_directory" "$agent_directory"
temporary_directory="$(mktemp -d "$install_directory/.intel-sky-install.XXXXXX")"
temporary_app="$temporary_directory/Intel Sky Service.app"
ditto "$source_app" "$temporary_app"
codesign --verify --deep --strict "$temporary_app"
lipo "$temporary_app/Contents/MacOS/SkyComputerUseService" -verify_arch x86_64

rm -rf "$installed_app"
mv "$temporary_app" "$installed_app"
cp "$project_directory/Packaging/dev.huangjianbin.intel-sky-service.plist" "$agent_path"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $executable_path" "$agent_path"
chmod 600 "$agent_path"

launchctl bootout "$service_target" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$agent_path"
launchctl kickstart -k "$service_target"

echo "installed: $installed_app"
echo "launch agent: $agent_path"

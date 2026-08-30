#!/bin/zsh

set -euo pipefail
umask 077

script_directory=${0:A:h}
project_directory=${script_directory:h}
default_source_app="$project_directory/dist/Intel Sky Service.app"
source_app="${1:-$default_source_app}"
source_was_explicit=false
if (( $# > 1 )); then
  print -u2 "usage: Scripts/install-managed-service.sh [/path/to/Intel Sky Service.app]"
  exit 64
elif (( $# == 1 )); then
  source_was_explicit=true
fi

if [[ "$source_app" == "--help" || "$source_app" == "-h" ]]; then
  print "usage: Scripts/install-managed-service.sh [/path/to/Intel Sky Service.app]"
  print "installs the signed x86_64 App for ChatGPT-managed Computer Use and native PIP"
  exit 0
fi

if [[ "$(/usr/bin/uname -s)" != "Darwin" ]]; then
  print -u2 "managed Computer Use installation requires macOS"
  exit 69
fi
if [[ "$(/usr/bin/uname -m)" != "x86_64" ]]; then
  print -u2 "managed Computer Use installation requires an Intel (x86_64) Mac"
  exit 65
fi
if [[ "$(/usr/sbin/sysctl -in sysctl.proc_translated 2>/dev/null || true)" == "1" ]]; then
  print -u2 "Rosetta on Apple Silicon is not a supported Intel installation target"
  exit 65
fi

macos_major="$(/usr/bin/sw_vers -productVersion | /usr/bin/awk -F. '{print $1}')"
if [[ ! "$macos_major" =~ '^[0-9]+$' ]] || (( macos_major < 14 )); then
  print -u2 "managed Computer Use requires macOS 14 or newer"
  exit 69
fi

if [[ ! -x "$source_app/Contents/MacOS/SkyComputerUseService" ]]; then
  if $source_was_explicit; then
    print -u2 "install source is not a built Computer Use App: $source_app"
    exit 66
  fi
  print "No built App found; building the signed x86_64 release bundle..."
  "$script_directory/build-app.sh"
fi

source_app=${source_app:A}
source_executable="$source_app/Contents/MacOS/SkyComputerUseService"
if [[ ! -x "$source_executable" ]]; then
  print -u2 "missing executable: $source_executable"
  exit 66
fi

sky_node_path="${SKY_NODE_PATH:-/Applications/ChatGPT.app/Contents/Resources/native/sky.node}"
pip_audit_script="${PIP_AUDIT_SCRIPT:-$script_directory/audit-pip-host.sh}"
if [[ ! -x "$pip_audit_script" ]]; then
  print -u2 "missing PIP compatibility audit: $pip_audit_script"
  exit 66
fi
"$pip_audit_script" "$sky_node_path"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$source_app"
/usr/bin/lipo "$source_executable" -verify_arch x86_64

codex_home="${CODEX_HOME:-$HOME/.codex}"
install_directory="$codex_home/computer-use"
installed_app="$install_directory/Codex Computer Use.app"
legacy_agent_path="${INTEL_SKY_LEGACY_LAUNCH_AGENT_PATH:-$HOME/Library/LaunchAgents/dev.huangjianbin.intel-sky-service.plist}"
legacy_service_target="${INTEL_SKY_LEGACY_SERVICE_TARGET:-gui/$UID/dev.huangjianbin.intel-sky-service}"
timestamp="$(/bin/date -u +%Y%m%d-%H%M%S)"
backup_app="$install_directory/Codex Computer Use.app.backup-$timestamp"
failed_app="$install_directory/Codex Computer Use.app.failed-$timestamp"
legacy_agent_backup="$legacy_agent_path.disabled-by-managed-installer-$timestamp"
legacy_service_domain="${legacy_service_target%/*}"
temporary_directory=""
legacy_service_loaded=false
legacy_service_stopped=false
legacy_agent_disabled=false
previous_app_backed_up=false
installed_new_app=false
installation_complete=false

cleanup() {
  local exit_status=$?
  if (( exit_status != 0 )) && ! $installation_complete; then
    if $installed_new_app && [[ -e "$installed_app" && ! -e "$failed_app" ]]; then
      /bin/mv "$installed_app" "$failed_app" || true
      print -u2 "preserved failed installation at: $failed_app"
    fi
    if $previous_app_backed_up && [[ -e "$backup_app" && ! -e "$installed_app" ]]; then
      /bin/mv "$backup_app" "$installed_app" || true
    fi
    if $legacy_agent_disabled && [[ -e "$legacy_agent_backup" && ! -e "$legacy_agent_path" ]]; then
      /bin/mv "$legacy_agent_backup" "$legacy_agent_path" || true
    fi
    if $legacy_service_stopped && [[ -f "$legacy_agent_path" ]]; then
      /bin/launchctl bootstrap "$legacy_service_domain" "$legacy_agent_path" 2>/dev/null || true
    fi
  fi
  if [[ -n "$temporary_directory" && -d "$temporary_directory" \
    && "$temporary_directory" == "$install_directory/.managed-install."* ]]; then
    /bin/rm -rf -- "$temporary_directory"
  fi
}
trap cleanup EXIT

if [[ -L "$install_directory" || -L "$installed_app" ]]; then
  print -u2 "refusing to install through a symbolic link: $installed_app"
  exit 73
fi
if [[ -e "$backup_app" || -e "$failed_app" || -e "$legacy_agent_backup" ]]; then
  print -u2 "timestamped backup path already exists; retry the installation"
  exit 73
fi
if /bin/launchctl print "$legacy_service_target" >/dev/null 2>&1; then
  legacy_service_loaded=true
fi

/bin/mkdir -p "$install_directory"
temporary_directory="$(/usr/bin/mktemp -d "$install_directory/.managed-install.XXXXXX")"
temporary_app="$temporary_directory/Codex Computer Use.app"
/usr/bin/ditto "$source_app" "$temporary_app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$temporary_app"
/usr/bin/lipo "$temporary_app/Contents/MacOS/SkyComputerUseService" -verify_arch x86_64

if $legacy_service_loaded; then
  if ! /bin/launchctl bootout "$legacy_service_target"; then
    print -u2 "the loaded legacy LaunchAgent could not be stopped; installation was not changed"
    exit 75
  fi
  legacy_service_stopped=true
fi
if [[ -f "$legacy_agent_path" ]]; then
  /bin/mv "$legacy_agent_path" "$legacy_agent_backup"
  legacy_agent_disabled=true
fi

if [[ -e "$installed_app" ]]; then
  /bin/mv "$installed_app" "$backup_app"
  previous_app_backed_up=true
fi
/bin/mv "$temporary_app" "$installed_app"
installed_new_app=true

/usr/bin/codesign --verify --deep --strict --verbose=2 "$installed_app"
/usr/bin/lipo "$installed_app/Contents/MacOS/SkyComputerUseService" -verify_arch x86_64
if ! capability_preparation="$($installed_app/Contents/MacOS/SkyComputerUseService --prepare-capability)"; then
  print -u2 "Computer Use capability preparation failed:"
  print -u2 "$capability_preparation"
  exit 78
fi
installed_hash="$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 \
  "$installed_app/Contents/MacOS/SkyComputerUseService" | /usr/bin/awk '{print $1}')"
installation_complete=true

print
print "Installed ChatGPT-managed Computer Use:"
print "  app=$installed_app"
print "  sha256=$installed_hash"
print "  capabilityPreparation=$capability_preparation"
if [[ -e "$backup_app" ]]; then
  print "  rollbackApp=$backup_app"
fi
if [[ -e "$legacy_agent_backup" ]]; then
  print "  disabledLegacyLaunchAgent=$legacy_agent_backup"
fi
print
print "Next steps:"
print "  1. Grant the installed App Accessibility, Screen & System Audio Recording, and Input Monitoring."
print "  2. Completely quit ChatGPT, then open it again."
print "  3. Verify runtime status at:"
print "     $HOME/Library/Group Containers/2DC432GLL2.com.openai.sky.CUAService/IPC/service-status.json"
print
print "Do not run the legacy LaunchAgent at the same time as the ChatGPT-managed service."

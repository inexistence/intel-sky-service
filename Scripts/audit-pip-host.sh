#!/bin/zsh

set -euo pipefail

sky_node_path="${1:-/Applications/ChatGPT.app/Contents/Resources/native/sky.node}"

if [[ ! -f "$sky_node_path" ]]; then
  print -u2 "missing Intel ChatGPT PIP host: $sky_node_path"
  exit 66
fi

architecture=$(/usr/bin/file "$sky_node_path")
if [[ "$architecture" != *"x86_64"* ]]; then
  print -u2 "PIP host is not x86_64: $architecture"
  exit 65
fi

team_identifier=$(/usr/bin/codesign -dv --verbose=4 "$sky_node_path" 2>&1 \
  | /usr/bin/sed -n 's/^TeamIdentifier=//p')
if [[ "$team_identifier" != "2DC432GLL2" ]]; then
  print -u2 "unexpected PIP host signing team: ${team_identifier:-missing}"
  exit 77
fi

required_selectors=(
  'publishPresentationWithID:threadID:turnID:contextID:width:height:withReply:'
  'setSourceProcessIdentifier:forPresentationWithID:withReply:'
  'prepareOperationWithPresentationID:operationID:kind:contextID:width:height:fencePayload:withReply:'
  'completeOperationWithPresentationID:operationID:withReply:'
  'willEndStreamWithPresentationID:withReply:'
  'invalidatePresentationWithID:withReply:'
  'noteInteractionWithPresentationID:withReply:'
  'setComputerUseCursorLocationWithX:y:isActive:withReply:'
  'connectWithReply:'
  'setMaxDisplaySize:withReply:'
  'performActionWithPresentationID:kind:withReply:'
  'didEndStreamWithPresentationID:withReply:'
)

selector_dump=$(/usr/bin/strings -a "$sky_node_path")
for selector in "${required_selectors[@]}"; do
  if [[ "$selector_dump" != *"$selector"* ]]; then
    print -u2 "missing required PIP selector: $selector"
    exit 69
  fi
done

host_hash=$(LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$sky_node_path" | /usr/bin/awk '{print $1}')
print "PIP host compatibility audit passed"
print "path=$sky_node_path"
print "architecture=x86_64"
print "teamIdentifier=$team_identifier"
print "sha256=$host_hash"
print "requiredSelectors=${#required_selectors[@]}"

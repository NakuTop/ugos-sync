#!/bin/bash
set -euo pipefail
domain="gui/$(id -u)"
for label in com.nakutop.ugos-sync.engine com.nakutop.ugos-sync.daemon com.nakutop.ugos-sync.ui; do
  if ! launchctl print "$domain/$label" >/dev/null 2>&1; then
    launchctl bootstrap "$domain" "$HOME/Library/LaunchAgents/$label.plist"
  fi
done

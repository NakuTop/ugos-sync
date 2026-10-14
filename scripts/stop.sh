#!/bin/bash
set -euo pipefail
domain="gui/$(id -u)"
for label in com.nakutop.ugos-sync.ui com.nakutop.ugos-sync.daemon com.nakutop.ugos-sync.engine; do
  launchctl bootout "$domain" "$HOME/Library/LaunchAgents/$label.plist" 2>/dev/null || true
done
# Preserve private settings, the vendor profile, and all synchronized files.

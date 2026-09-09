#!/bin/sh
# Runs the actual bundled renderers, SVG isolation/display, and PDF tests on macOS.
set -eu
cd "$(dirname "$0")/.."
xcodebuild -project QuickMD/QuickMD.xcodeproj -scheme QuickMD \
  -configuration Debug -destination 'platform=macOS' \
  -only-testing:QuickMDTests/DiagramRendererTests \
  CODE_SIGNING_ALLOWED=NO test "$@"

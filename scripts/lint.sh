#!/usr/bin/env bash
# Code-quality gate: build + SwiftLint + swift-format.
#   ./scripts/lint.sh        check everything (fails on any issue)
#   ./scripts/lint.sh --fix  auto-format + auto-correct in place
set -euo pipefail
cd "$(dirname "$0")/.."

# SwiftLint needs sourcekitdInProc; on a Command-Line-Tools-only Mac (no Xcode)
# it lives here and must be on the framework search path.
export DYLD_FRAMEWORK_PATH="/Library/Developer/CommandLineTools/usr/lib:${DYLD_FRAMEWORK_PATH:-}"

if [[ "${1:-}" == "--fix" ]]; then
  echo "▸ Formatting with swift-format…"
  swift-format format --in-place --recursive --configuration .swift-format Sources
  echo "▸ Auto-correcting with SwiftLint…"
  swiftlint --fix --quiet
  echo "✓ Formatted. Re-run ./scripts/lint.sh to verify."
  exit 0
fi

echo "▸ swift build…"
swift build

echo "▸ SwiftLint…"
swiftlint lint --quiet --strict

echo "▸ swift-format…"
swift-format lint --recursive --strict --configuration .swift-format Sources

echo "✓ All checks passed."

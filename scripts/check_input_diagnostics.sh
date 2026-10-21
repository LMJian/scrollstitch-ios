#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 1 || -e "$1" ]]; then
  echo 'Usage: bash scripts/check_input_diagnostics.sh /absolute/fresh/artifact-directory' >&2
  exit 2
fi
mkdir -p .build/input-diagnostic-smoke
xcrun swiftc -O -parse-as-library -swift-version 6 \
  Sources/ScrollStitchCore/*.swift Sources/ScrollStitchImaging/*.swift \
  App/PickerLoader.swift App/InputDiagnostics.swift Tools/InputDiagnosticSmoke/main.swift \
  -o .build/input-diagnostic-smoke/check
.build/input-diagnostic-smoke/check "$1"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
probe_output=".build/ios27-api-probe"
mkdir -p "$probe_output"
probe_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
xcodebuild -version > "$probe_output/toolchain.txt"
xcrun --sdk iphoneos --show-sdk-version >> "$probe_output/toolchain.txt"
# Compile and link with the iOS 27 deployment floor. No simulator or GUI is run.
xcrun --sdk iphoneos swiftc -swift-version 6 -warnings-as-errors \
  -sdk "$probe_sdk" -target arm64-apple-ios27.0 -parse-as-library -emit-library \
  -module-name ScreenCaptureKitAPIProbe \
  -module-cache-path "$probe_output/module-cache" \
  scripts/probes/ScreenCaptureKitAPIProbe.swift \
  -o "$probe_output/libScreenCaptureKitAPIProbe.dylib"
xcrun otool -l "$probe_output/libScreenCaptureKitAPIProbe.dylib" \
  > "$probe_output/load-commands.txt"
python3 - "$probe_output/load-commands.txt" <<'PY'
import pathlib, sys
commands = pathlib.Path(sys.argv[1]).read_text()
blocks = commands.split('Load command ')
sck = [b for b in blocks if 'ScreenCaptureKit.framework/ScreenCaptureKit' in b]
if len(sck) != 1 or 'LC_LOAD_DYLIB' not in sck[0]:
    raise SystemExit('ScreenCaptureKit must be linked for the iOS 27-only product')
print('PASS: iOS 27 APIs compile and link in Swift 6 at the iOS 27 floor.')
print('Scope: compile/link only; no iOS 27 capture session or background behavior was executed.')
PY

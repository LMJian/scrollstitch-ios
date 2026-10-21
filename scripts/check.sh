#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
  core)
    swift build --scratch-path .build/core --cache-path .build/cache --disable-sandbox
    ;;
  unit)
    swift test --scratch-path .build/tests --cache-path .build/cache --disable-sandbox
    python3 -m unittest discover -s Tests/OperatorTests
    ;;
  ios)
    xcodebuild -project ScrollStitch.xcodeproj -scheme ScrollStitch \
      -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build
    ;;
  device-build)
    xcodebuild -project ScrollStitch.xcodeproj -scheme ScrollStitch \
      -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' \
      -derivedDataPath .build/DeviceDerivedData CODE_SIGNING_ALLOWED=NO build
    python3 scripts/check_native_package.py --app .build/DeviceDerivedData/Build/Products/Debug-iphoneos/ScrollStitch.app
    ;;
  store-archive)
    build_revision="$(git rev-parse HEAD)"
    source_digest="$(python3 -c 'from scripts.check_release import source_digest; print(source_digest())')"
    xcodebuild -project ScrollStitch.xcodeproj -scheme ScrollStitchStore \
      -configuration Store -destination 'generic/platform=iOS' \
      -derivedDataPath .build/StoreDerivedData -archivePath .build/StoreArchive.xcarchive \
      CODE_SIGNING_ALLOWED=NO SCROLLSTITCH_BUILD_REVISION="$build_revision" \
      SCROLLSTITCH_SOURCE_DIGEST="$source_digest" archive
    ;;
  config)
    python3 scripts/check_config.py
    ;;
  *) echo 'Usage: bash scripts/check.sh {core|unit|ios|device-build|store-archive|config}' >&2; exit 2 ;;
esac

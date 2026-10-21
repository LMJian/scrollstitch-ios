#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/holiday-probe
swiftc -swift-version 6 -parse-as-library \
  Sources/ScrollStitchCore/WorkdayCalendar.swift \
  Sources/ScrollStitchCore/WorkdayHolidayStore.swift \
  scripts/probes/HolidayEndpointProbe.swift \
  -o .build/holiday-probe/endpoint
.build/holiday-probe/endpoint

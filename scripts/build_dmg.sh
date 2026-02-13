#!/usr/bin/env bash
set -euo pipefail

APP_NAME="PDFPO"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
DMG_PATH="${BUILD_DIR}/${APP_NAME}.dmg"

"${ROOT_DIR}/scripts/build_app.sh"

rm -f "${DMG_PATH}"
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${BUILD_DIR}/${APP_NAME}.app" \
  -ov -format UDZO \
  "${DMG_PATH}"

echo "Created ${DMG_PATH}"

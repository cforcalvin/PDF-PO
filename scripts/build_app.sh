#!/usr/bin/env bash
set -euo pipefail

APP_NAME="PDFPO"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
BIN_PATH="${ROOT_DIR}/.build/release/${APP_NAME}"

swift build -c release --package-path "${ROOT_DIR}"

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${ROOT_DIR}/Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
cp "${ROOT_DIR}/Resources/PDFPO.icns" "${APP_DIR}/Contents/Resources/PDFPO.icns"
cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

echo "Built ${APP_DIR}"

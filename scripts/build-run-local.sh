#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SCHEME="TypeWhisper"
PROJECT="TypeWhisper.xcodeproj"
APP_NAME="TypeWhisper"
BUILD_DIR="$PROJECT_DIR/build-run-local"
DESTINATION="platform=macOS,arch=arm64"

echo "=== TypeWhisper Local Optimized Build ==="
echo "Configuration: Release"
echo "Signing: Xcode project settings"
echo ""

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "--- Resolving Swift packages ---"
xcodebuild -resolvePackageDependencies \
  -project "$PROJECT_DIR/$PROJECT" \
  -scheme "$SCHEME"

echo "--- Building Release for local run ---"
set -o pipefail
xcodebuild -project "$PROJECT_DIR/$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  -destination "$DESTINATION" | tee "$BUILD_DIR/build.log"

bash "$PROJECT_DIR/scripts/check_first_party_warnings.sh" "$BUILD_DIR/build.log"

APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: App not found at $APP_PATH"
  exit 1
fi

echo ""
echo "=== Done ==="
echo "App: $APP_PATH"

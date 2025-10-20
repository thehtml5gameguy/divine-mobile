#!/bin/bash
# ABOUTME: Build script for OpenVine Android app (debug and release builds)
# ABOUTME: Handles both debug and signed release APKs for Android platform

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
BUILD_TYPE="debug"
VERBOSE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    debug|release)
      BUILD_TYPE="$1"
      shift
      ;;
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
    -h|--help)
      echo "Usage: ./build_android.sh [debug|release] [-v|--verbose]"
      echo ""
      echo "Build types:"
      echo "  debug    - Build debug APK (default, no signing required)"
      echo "  release  - Build signed release APK (requires keystore)"
      echo ""
      echo "Options:"
      echo "  -v, --verbose  Show detailed build output"
      echo "  -h, --help     Show this help message"
      exit 0
      ;;
    *)
      echo -e "${RED}Error: Unknown argument '$1'${NC}"
      echo "Run './build_android.sh --help' for usage information"
      exit 1
      ;;
  esac
done

echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}OpenVine Android Build${NC}"
echo -e "${GREEN}================================${NC}"
echo ""
echo -e "Build type: ${YELLOW}$BUILD_TYPE${NC}"
echo ""

# Change to mobile directory
cd "$(dirname "$0")"

# Clean previous builds
echo -e "${YELLOW}Cleaning previous builds...${NC}"
flutter clean
flutter pub get

# Verify keystore exists for release builds
if [ "$BUILD_TYPE" = "release" ]; then
  KEYSTORE_PATH="/Users/rabble/android-keys/openvine/upload-keystore.jks"
  if [ ! -f "$KEYSTORE_PATH" ]; then
    echo -e "${RED}Error: Keystore not found at $KEYSTORE_PATH${NC}"
    echo "Release builds require a valid keystore file."
    exit 1
  fi

  if [ ! -f "android/key.properties" ]; then
    echo -e "${RED}Error: android/key.properties not found${NC}"
    echo "Release builds require key.properties file with keystore credentials."
    exit 1
  fi

  echo -e "${GREEN}✓ Keystore verified${NC}"
  echo ""
fi

# Build APK
echo -e "${YELLOW}Building Android APK ($BUILD_TYPE)...${NC}"
echo ""

if [ "$VERBOSE" = true ]; then
  flutter build apk --$BUILD_TYPE -v
else
  flutter build apk --$BUILD_TYPE
fi

# Check build result
if [ $? -eq 0 ]; then
  echo ""
  echo -e "${GREEN}================================${NC}"
  echo -e "${GREEN}Build Successful!${NC}"
  echo -e "${GREEN}================================${NC}"
  echo ""

  if [ "$BUILD_TYPE" = "release" ]; then
    APK_PATH="build/app/outputs/flutter-apk/app-release.apk"
  else
    APK_PATH="build/app/outputs/flutter-apk/app-debug.apk"
  fi

  if [ -f "$APK_PATH" ]; then
    APK_SIZE=$(du -h "$APK_PATH" | cut -f1)
    echo -e "APK location: ${YELLOW}$APK_PATH${NC}"
    echo -e "APK size: ${YELLOW}$APK_SIZE${NC}"
    echo ""

    # Show installation instructions
    echo -e "${GREEN}To install on a connected device or emulator:${NC}"
    echo -e "  flutter install"
    echo ""
    echo -e "${GREEN}To install APK directly with adb:${NC}"
    echo -e "  adb install $APK_PATH"
    echo ""

    if [ "$BUILD_TYPE" = "release" ]; then
      echo -e "${GREEN}To distribute this APK:${NC}"
      echo -e "  - Upload to Google Play Console for testing"
      echo -e "  - Share directly with testers (sideloading)"
      echo ""
    fi
  else
    echo -e "${RED}Warning: APK file not found at expected location${NC}"
  fi
else
  echo ""
  echo -e "${RED}================================${NC}"
  echo -e "${RED}Build Failed!${NC}"
  echo -e "${RED}================================${NC}"
  echo ""
  echo "Run with -v flag for verbose output to diagnose issues."
  exit 1
fi

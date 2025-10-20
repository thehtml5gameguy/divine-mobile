#!/bin/bash
# ABOUTME: Fix hardcoded Homebrew library paths in macOS frameworks
# ABOUTME: Rewrites absolute paths to use @rpath for proper app distribution

set -e

APP_PATH="build/macos/Build/Products/Debug/divine.app"
FRAMEWORKS_PATH="$APP_PATH/Contents/Frameworks"

echo "🔧 Fixing library paths in macOS frameworks..."

# Check if frameworks exist
if [ ! -d "$FRAMEWORKS_PATH" ]; then
    echo "❌ Error: Frameworks directory not found at $FRAMEWORKS_PATH"
    echo "   Please build the app first with: flutter build macos"
    exit 1
fi

# Make frameworks writable
echo "🔓 Making frameworks writable..."
chmod -R u+w "$FRAMEWORKS_PATH" 2>/dev/null || true

# List of frameworks that might have hardcoded Homebrew paths
FRAMEWORKS=(
    "libavdevice.framework/Versions/A/libavdevice"
    "libavcodec.framework/Versions/A/libavcodec"
    "libavformat.framework/Versions/A/libavformat"
    "libavfilter.framework/Versions/A/libavfilter"
    "libavutil.framework/Versions/A/libavutil"
    "libswresample.framework/Versions/A/libswresample"
    "libswscale.framework/Versions/A/libswscale"
)

# Function to find a library (check Homebrew first, then system paths)
find_library() {
    local lib_name="$1"
    local homebrew_path="$2"

    # Special handling for zlib (system library)
    if [[ "$lib_name" == "libz.1.dylib" ]]; then
        if [ -f "/usr/lib/libz.1.dylib" ]; then
            echo "/usr/lib/libz.1.dylib"
            return 0
        fi
    fi

    # Check Homebrew path first
    if [ -f "$homebrew_path" ]; then
        echo "$homebrew_path"
        return 0
    fi

    # Check system paths
    if [ -f "/usr/lib/$lib_name" ]; then
        echo "/usr/lib/$lib_name"
        return 0
    fi

    return 1
}

# Function to copy library and fix dependencies recursively
copy_and_fix_library() {
    local source_path="$1"
    local lib_name=$(basename "$source_path")
    local dest_path="$FRAMEWORKS_PATH/$lib_name"

    # Skip if already copied
    if [ -f "$dest_path" ]; then
        return 0
    fi

    echo "   📥 Copying $lib_name"
    cp "$source_path" "$dest_path"
    chmod u+w "$dest_path"

    # Remove existing signature
    codesign --remove-signature "$dest_path" 2>/dev/null || true

    # Fix dependencies of the copied library
    local deps=$(otool -L "$dest_path" | grep "/opt/homebrew" | awk '{print $1}')
    for dep in $deps; do
        local dep_name=$(basename "$dep")
        local dep_source=$(find_library "$dep_name" "$dep" || echo "")

        if [ -n "$dep_source" ]; then
            # Recursively copy and fix this dependency
            copy_and_fix_library "$dep_source"
            # Rewrite the reference
            install_name_tool -change "$dep" "@rpath/$dep_name" "$dest_path" 2>/dev/null || true
        fi
    done

    # Ad-hoc sign the library (no identity required)
    codesign --force --sign - "$dest_path" 2>/dev/null || true
}

# Function to fix library paths in a framework
fix_framework_paths() {
    local framework_path="$1"
    local framework_file="$FRAMEWORKS_PATH/$framework_path"

    if [ ! -f "$framework_file" ]; then
        echo "⚠️  Skipping $framework_path (not found)"
        return
    fi

    echo "📦 Processing: $framework_path"

    # Make writable
    chmod u+w "$framework_file"

    # Get current library dependencies
    local deps=$(otool -L "$framework_file" | grep "/opt/homebrew" | awk '{print $1}')

    if [ -z "$deps" ]; then
        echo "   ✅ No Homebrew paths found"
        return
    fi

    # Rewrite each Homebrew path
    for dep in $deps; do
        local lib_name=$(basename "$dep")
        local lib_path=$(find_library "$lib_name" "$dep" || echo "")

        if [ -n "$lib_path" ]; then
            # Copy library and its dependencies
            copy_and_fix_library "$lib_path"

            # Change the reference to use @rpath
            install_name_tool -change "$dep" "@rpath/$lib_name" "$framework_file" 2>/dev/null || true
            echo "   ✅ Fixed: $lib_name"
        else
            echo "   ⚠️  Warning: $lib_name not found on system"
        fi
    done
}

# Process each framework
for framework in "${FRAMEWORKS[@]}"; do
    fix_framework_paths "$framework"
done

echo ""
echo "🔏 Re-signing frameworks and app bundle..."

# Sign all bundled dylibs
for dylib in "$FRAMEWORKS_PATH"/*.dylib; do
    if [ -f "$dylib" ]; then
        echo "   🔐 Signing $(basename "$dylib")"
        codesign --remove-signature "$dylib" 2>/dev/null || true
        codesign --force --sign - "$dylib" 2>/dev/null || true
    fi
done

# Sign all frameworks
for framework in "$FRAMEWORKS_PATH"/*.framework; do
    if [ -d "$framework" ]; then
        echo "   🔐 Signing $(basename "$framework")"
        codesign --remove-signature "$framework" 2>/dev/null || true
        codesign --force --sign - "$framework" 2>/dev/null || true
    fi
done

# Finally, sign the app bundle with deep signing
echo "   🔐 Signing app bundle..."
codesign --remove-signature "$APP_PATH" 2>/dev/null || true
codesign --force --deep --sign - "$APP_PATH" 2>/dev/null || true

echo ""
echo "✅ Library path fixes complete!"
echo ""
echo "To verify, run:"
echo "  otool -L $FRAMEWORKS_PATH/libavdevice.framework/Versions/A/libavdevice | grep -v '@rpath' | grep -v '/System' | grep -v '/usr/lib'"
echo ""
echo "To test the app:"
echo "  open $APP_PATH"

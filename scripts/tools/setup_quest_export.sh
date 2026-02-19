#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Quest Export Preset Setup Script
# =============================================================================
# Validates prerequisites and guides the user through configuring
# the Meta Quest export preset for Godot 4.5.
#
# Usage: ./scripts/tools/setup_quest_export.sh
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

PASS="${GREEN}✓${NC}"
FAIL="${RED}✗${NC}"
WARN="${YELLOW}!${NC}"

errors=0
warnings=0

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Meta Quest Export Setup — HOC (Godot 4.5)${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo ""

# ── 1. Check Java / JDK ─────────────────────────────────────────────────────
echo -e "${BLUE}[1/6] Checking JDK...${NC}"
if command -v java &>/dev/null; then
    JAVA_VERSION=$(java -version 2>&1 | head -1 | awk -F '"' '{print $2}')
    JAVA_MAJOR=$(echo "$JAVA_VERSION" | cut -d. -f1)
    if [ "$JAVA_MAJOR" -ge 17 ] 2>/dev/null; then
        echo -e "  ${PASS} JDK $JAVA_VERSION found"
    else
        echo -e "  ${FAIL} JDK $JAVA_VERSION found but 17+ required"
        echo "       Install: brew install openjdk@17  (macOS)"
        ((errors++))
    fi
else
    echo -e "  ${FAIL} Java not found"
    echo "       Install: brew install openjdk@17  (macOS)"
    echo "                sudo apt install openjdk-17-jdk  (Linux)"
    ((errors++))
fi

# ── 2. Check Android SDK ────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}[2/6] Checking Android SDK...${NC}"
ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$ANDROID_HOME" ]; then
    # Common default locations
    for candidate in \
        "$HOME/Library/Android/sdk" \
        "$HOME/Android/Sdk" \
        "/usr/local/lib/android/sdk" \
        "$HOME/.android/sdk"; do
        if [ -d "$candidate" ]; then
            ANDROID_HOME="$candidate"
            break
        fi
    done
fi

if [ -n "$ANDROID_HOME" ] && [ -d "$ANDROID_HOME" ]; then
    echo -e "  ${PASS} Android SDK found: $ANDROID_HOME"

    # Check for required SDK components
    if [ -d "$ANDROID_HOME/platform-tools" ]; then
        echo -e "  ${PASS} platform-tools present"
    else
        echo -e "  ${FAIL} platform-tools missing"
        echo "       Run: sdkmanager \"platform-tools\""
        ((errors++))
    fi

    if [ -d "$ANDROID_HOME/build-tools" ]; then
        LATEST_BT=$(ls "$ANDROID_HOME/build-tools" | sort -V | tail -1)
        echo -e "  ${PASS} build-tools present ($LATEST_BT)"
    else
        echo -e "  ${FAIL} build-tools missing"
        echo "       Run: sdkmanager \"build-tools;34.0.0\""
        ((errors++))
    fi

    # Check for platform API 29+ (required for Quest)
    if ls "$ANDROID_HOME/platforms/" 2>/dev/null | grep -q "android-[23][0-9]"; then
        echo -e "  ${PASS} Platform API 29+ present"
    else
        echo -e "  ${WARN} No Android platform API 29+ found"
        echo "       Run: sdkmanager \"platforms;android-34\""
        ((warnings++))
    fi
else
    echo -e "  ${FAIL} Android SDK not found"
    echo "       Install Android Studio or standalone SDK:"
    echo "       https://developer.android.com/studio"
    echo "       Then set ANDROID_HOME in your shell profile."
    ((errors++))
fi

# ── 3. Check ADB ────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}[3/6] Checking ADB...${NC}"
if command -v adb &>/dev/null; then
    ADB_VERSION=$(adb --version 2>&1 | head -1)
    echo -e "  ${PASS} $ADB_VERSION"

    # Check for connected Quest devices
    DEVICES=$(adb devices 2>/dev/null | grep -c "device$" || true)
    if [ "$DEVICES" -gt 0 ]; then
        echo -e "  ${PASS} Quest device connected ($DEVICES device(s))"
    else
        echo -e "  ${WARN} No Quest device detected (connect via USB or enable WiFi ADB)"
        ((warnings++))
    fi
else
    echo -e "  ${FAIL} ADB not found (install platform-tools)"
    ((errors++))
fi

# ── 4. Check debug keystore ─────────────────────────────────────────────────
echo ""
echo -e "${BLUE}[4/6] Checking debug keystore...${NC}"
DEBUG_KEYSTORE="$HOME/.android/debug.keystore"
if [ -f "$DEBUG_KEYSTORE" ]; then
    echo -e "  ${PASS} Debug keystore exists: $DEBUG_KEYSTORE"
else
    echo -e "  ${WARN} Debug keystore not found. Creating..."
    mkdir -p "$HOME/.android"
    keytool -genkey -v \
        -keystore "$DEBUG_KEYSTORE" \
        -storepass android \
        -alias androiddebugkey \
        -keypass android \
        -keyalg RSA \
        -keysize 2048 \
        -validity 10000 \
        -dname "CN=Android Debug,O=Android,C=US" 2>/dev/null
    if [ -f "$DEBUG_KEYSTORE" ]; then
        echo -e "  ${PASS} Debug keystore created"
    else
        echo -e "  ${FAIL} Failed to create debug keystore"
        ((errors++))
    fi
fi

# ── 5. Check Godot editor settings ──────────────────────────────────────────
echo ""
echo -e "${BLUE}[5/6] Checking Godot editor settings...${NC}"
EDITOR_SETTINGS=""
for candidate in \
    "$HOME/Library/Application Support/Godot/editor_settings-4.tres" \
    "$HOME/.config/godot/editor_settings-4.tres" \
    "$HOME/.local/share/godot/editor_settings-4.tres"; do
    if [ -f "$candidate" ]; then
        EDITOR_SETTINGS="$candidate"
        break
    fi
done

if [ -n "$EDITOR_SETTINGS" ]; then
    echo -e "  ${PASS} Editor settings found: $EDITOR_SETTINGS"

    if grep -q "android/android_sdk_path" "$EDITOR_SETTINGS" 2>/dev/null; then
        SDK_PATH=$(grep "android/android_sdk_path" "$EDITOR_SETTINGS" | sed 's/.*= "\(.*\)"/\1/')
        echo -e "  ${PASS} Android SDK configured in Godot: $SDK_PATH"
    else
        echo -e "  ${WARN} Android SDK path not set in Godot Editor Settings"
        echo "       Open Godot → Editor → Editor Settings → Export → Android"
        echo "       Set 'Android Sdk Path' to: ${ANDROID_HOME:-/path/to/android/sdk}"
        ((warnings++))
    fi

    if grep -q "android/debug_keystore" "$EDITOR_SETTINGS" 2>/dev/null; then
        echo -e "  ${PASS} Debug keystore configured in Godot"
    else
        echo -e "  ${WARN} Debug keystore not configured in Godot Editor Settings"
        echo "       Set 'Debug Keystore' to: $DEBUG_KEYSTORE"
        echo "       Password: android  |  User: androiddebugkey"
        ((warnings++))
    fi
else
    echo -e "  ${WARN} Godot editor settings file not found"
    echo "       Run Godot at least once to generate it."
    ((warnings++))
fi

# ── 6. Check export preset ──────────────────────────────────────────────────
echo ""
echo -e "${BLUE}[6/6] Checking export presets...${NC}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PRESETS_FILE="$PROJECT_DIR/export_presets.cfg"

if [ -f "$PRESETS_FILE" ]; then
    if grep -q "Meta Quest\|quest" "$PRESETS_FILE" 2>/dev/null; then
        echo -e "  ${PASS} Meta Quest export preset found in export_presets.cfg"
    else
        echo -e "  ${WARN} export_presets.cfg exists but no Quest preset found"
        echo "       Open Godot → Project → Export → Add → Android"
        echo "       Rename to 'Meta Quest' and configure XR features."
        ((warnings++))
    fi
else
    echo -e "  ${WARN} No export_presets.cfg found"
    echo "       Open Godot → Project → Export → Add → Android"
    echo "       Configure as described in docs/quest_export_guide.md"
    ((warnings++))
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
if [ "$errors" -eq 0 ] && [ "$warnings" -eq 0 ]; then
    echo -e "  ${GREEN}All checks passed! Ready to export.${NC}"
elif [ "$errors" -eq 0 ]; then
    echo -e "  ${YELLOW}$warnings warning(s) — review above items${NC}"
else
    echo -e "  ${RED}$errors error(s), $warnings warning(s) — fix errors before exporting${NC}"
fi
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo ""

# ── Quick Reference ──────────────────────────────────────────────────────────
echo -e "${BLUE}Quick Reference:${NC}"
echo "  Export debug APK:   godot --headless --export-debug \"Meta Quest\" builds/quest/hoc-debug.apk"
echo "  Install to Quest:   adb install -r builds/quest/hoc-debug.apk"
echo "  View logs:          adb logcat -s godot"
echo ""

exit $errors

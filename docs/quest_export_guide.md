# Meta Quest Export Guide

## Prerequisites

| Requirement | Version | Install |
|---|---|---|
| JDK | 17+ | `brew install openjdk@17` (macOS) / `sudo apt install openjdk-17-jdk` (Linux) |
| Android SDK | Latest | [Android Studio](https://developer.android.com/studio) or standalone `cmdline-tools` |
| ADB | Latest | Comes with Android SDK platform-tools |
| Godot | 4.5+ | Already installed if you're reading this |

## Quick Setup

Run the automated validation script:

```bash
chmod +x scripts/tools/setup_quest_export.sh
./scripts/tools/setup_quest_export.sh
```

This will check all prerequisites and tell you exactly what's missing.

## Manual Setup Steps

### 1. Install Android SDK

```bash
# macOS (via Homebrew)
brew install --cask android-commandlinetools

# Or install Android Studio which bundles the SDK
```

Install required SDK components:
```bash
sdkmanager "platform-tools" "build-tools;34.0.0" "platforms;android-34"
```

### 2. Set Environment Variables

Add to your `~/.zshrc` or `~/.bashrc`:
```bash
export ANDROID_HOME="$HOME/Library/Android/sdk"  # macOS default
export PATH="$PATH:$ANDROID_HOME/platform-tools"
```

### 3. Configure Godot Editor Settings

1. Open Godot Editor
2. Go to **Editor → Editor Settings → Export → Android**
3. Set **Android Sdk Path** to your SDK location (e.g., `~/Library/Android/sdk`)
4. Set **Debug Keystore** to `~/.android/debug.keystore`
   - Password: `android`
   - User: `androiddebugkey`

### 4. Create Export Preset

1. Go to **Project → Export**
2. Click **Add…** → **Android**
3. Rename to **"Meta Quest"**
4. Configure:
   - **Architectures**: arm64-v8a only
   - **Min SDK**: 29
   - **Target SDK**: 34
   - **XR Mode**: OpenXR
   - **XR Features**:
     - Hand Tracking: Enabled (High Frequency)
     - Passthrough: Enabled
   - **Package**: `com.hoc.app`

### 5. Debug Keystore (auto-created by setup script)

If you need to create manually:
```bash
keytool -genkey -v \
  -keystore ~/.android/debug.keystore \
  -storepass android \
  -alias androiddebugkey \
  -keypass android \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -dname "CN=Android Debug,O=Android,C=US"
```

## Building & Deploying

```bash
# Debug build
godot --headless --export-debug "Meta Quest" builds/quest/hoc-debug.apk

# Release build
godot --headless --export-release "Meta Quest" builds/quest/hoc-release.apk

# Install to Quest
adb install -r builds/quest/hoc-debug.apk

# Launch
adb shell am start -n com.hoc.app/com.godot.game.GodotApp

# View logs
adb logcat -s godot
```

## Troubleshooting

| Issue | Fix |
|---|---|
| "No export template found" | Download Android export templates in Editor → Manage Export Templates |
| "Android SDK not configured" | Set SDK path in Editor Settings (step 3) |
| "Keystore not found" | Run `./scripts/tools/setup_quest_export.sh` to auto-create |
| APK won't install | Enable Developer Mode on Quest, check `adb devices` |
| Black screen on Quest | Ensure XR Mode is set to OpenXR in export preset |

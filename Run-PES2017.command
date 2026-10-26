#!/bin/bash
# Double-clickable launcher script for macOS Finder.
# Just double-click this file in Finder to build (if not built yet) and run PES 2017!

set -e
cd "$(dirname "$0")"

echo "============================================================"
echo "          Pro Evolution Soccer 2017 - macOS Launcher"
echo "============================================================"

# If PES 2017.app is already built and ready, launch it immediately!
if [ -d "PES 2017.app" ] && [ -x "PES 2017.app/Contents/MacOS/PES2017_Runner" ]; then
    echo "==> Launching PES 2017.app..."
    open "PES 2017.app"
    exit 0
fi

if [ -f "build-macos/launcher/pes17-launcher" ] && [ -x "build-macos/launcher/pes17-launcher" ]; then
    echo "==> Packaging into PES 2017.app..."
    ./tools/package_macos.sh build-macos
    echo "==> Launching PES 2017.app..."
    open "PES 2017.app"
    exit 0
fi

# Otherwise, perform automated 1-click build
echo "==> PES 2017 is not built yet. Setting up build environment..."

# 1. Setup Homebrew path if present
if ! command -v brew >/dev/null 2>&1; then
    if [ -x "/opt/homebrew/bin/brew" ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x "/usr/local/bin/brew" ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    else
        echo "==> Homebrew is required to install build dependencies."
        echo "==> Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        if [ -x "/opt/homebrew/bin/brew" ]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [ -x "/usr/local/bin/brew" ]; then
            eval "$(/usr/local/bin/brew shellenv)"
        fi
    fi
fi

# 2. Install dependencies via Homebrew
echo "==> Ensuring required libraries are installed (cmake, ninja, molten-vk, sdl3, vulkan-headers)..."
brew install cmake ninja molten-vk sdl3 vulkan-headers python3 2>/dev/null || true

# 3. Build and package
echo "==> Building PES 2017 and creating PES 2017.app..."
./build-macos.sh --package

# 4. Launch the application
if [ -d "PES 2017.app" ]; then
    echo "============================================================"
    echo "    Build complete! Launching PES 2017..."
    echo "============================================================"
    open "PES 2017.app"
fi

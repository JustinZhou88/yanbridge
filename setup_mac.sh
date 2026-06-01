#!/bin/bash

# YanBridge Mac Setup Script

echo "--- Checking dependencies ---"

if ! command -v ffmpeg &> /dev/null; then
    echo "FFmpeg not found. Installing via Homebrew..."
    brew install ffmpeg
else
    echo "FFmpeg is already installed."
fi

echo "--- Setting up Backend ---"
cd backend
if [ ! -d ".venv" ]; then
    echo "Creating virtual environment..."
    python3 -m venv .venv
fi

source .venv/bin/activate
echo "Installing/Updating Python dependencies..."
pip install --upgrade pip
pip install -r requirements.txt
cd ..

echo "--- Setting up Frontend ---"
flutter pub get

echo "--- Setup Complete! ---"
echo "You can now run the project using './run_mac.sh'"

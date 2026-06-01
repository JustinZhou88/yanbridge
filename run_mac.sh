#!/bin/bash

# YanBridge Mac Run Script

# Kill background processes on exit
trap "kill 0" EXIT

echo "--- Starting Backend ---"
cd backend
source .venv/bin/activate

# Use MPS for Apple Silicon acceleration
export WHISPER_DEVICE="mps"
export WHISPER_DOWNLOAD_ROOT="$HOME/.cache/whisper"

# Start uvicorn in background
uvicorn main:app --host 0.0.0.0 --port 8000 &
BACKEND_PID=$!
cd ..

echo "Waiting for backend to start..."
until $(curl --output /dev/null --silent --head --fail http://localhost:8000/health); do
    printf '.'
    sleep 1
done
echo " Backend is UP!"

echo "--- Starting Frontend ---"
# Select 'macos' for desktop or 'chrome' for web
# Defaulting to macos desktop app for better experience
flutter run -d macos

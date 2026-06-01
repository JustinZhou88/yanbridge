# YanBridge — Realtime ASR (minimal)

Chrome Web: record → Stop → POST `/upload` → openai-whisper **small** → show text.

## Structure

```
yanbridge/
├── lib/
│   ├── main.dart
│   ├── pages/realtime_asr_page.dart
│   ├── services/
│   │   ├── audio_recorder_service.dart
│   │   └── websocket_asr_service.dart
│   └── widgets/transcript_box.dart
├── backend/
│   ├── main.py
│   ├── requirements.txt
│   └── runtime/          # uploads, temp, logs (gitignored)
├── setup_mac.sh          # Mac auto-setup
├── run_mac.sh            # Mac auto-run (Backend + UI)
├── pubspec.yaml
└── README.md
```

## Mac Quick Start (Optimized for Apple Silicon)

1. **Setup**:
   ```bash
   chmod +x setup_mac.sh run_mac.sh
   ./setup_mac.sh
   ```

2. **Run**:
   ```bash
   ./run_mac.sh
   ```
   *This will start the Python backend (with MPS acceleration) and launch the Flutter macOS Desktop app.*

## Backend (Manual)

```powershell
cd D:\code\code\yanbridge\backend
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\.venv\Scripts\Activate.ps1
uvicorn main:app --reload --host 0.0.0.0 --port 8000
```

- Health: http://127.0.0.1:8000/health → `{"status":"ok"}`
- Upload: http://127.0.0.1:8000/upload
- WebSocket: ws://127.0.0.1:8000/ws/transcribe (phase 2)

Optional env:

- `WHISPER_MODEL` — default `small`
- `WHISPER_DEVICE` — default `cpu` (set `cuda` when GPU ready)
- `WHISPER_DOWNLOAD_ROOT` — default `C:\Users\Lenovo\.cache\whisper`
- `WHISPER_LANGUAGE` — optional, e.g. `en`

## Frontend (Flutter Web)

```powershell
cd D:\code\code\yanbridge
flutter pub get
flutter run -d chrome
```

1. Start Recording → allow microphone  
2. Speak  
3. Stop Recording → Uploading / Transcribing  
4. Transcript shows recognized text  

Phase 2: Start Streaming sends webm chunks over WebSocket every ~2.5s.

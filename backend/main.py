"""
YanBridge backend — upload ASR + optional WebSocket chunks.
Run: uvicorn main:app --reload --host 0.0.0.0 --port 8000
"""

from __future__ import annotations

import logging
import os
import shutil
import time
import traceback
from datetime import datetime
from pathlib import Path

import whisper
from fastapi import FastAPI, File, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware

# ---------------------------------------------------------------------------
# Config (override via environment)
# ---------------------------------------------------------------------------
WHISPER_MODEL = os.getenv("WHISPER_MODEL", "small")
WHISPER_DEVICE = os.getenv("WHISPER_DEVICE", "cpu")
WHISPER_DOWNLOAD_ROOT = os.getenv(
    "WHISPER_DOWNLOAD_ROOT", r"C:\Users\Lenovo\.cache\whisper"
)
WHISPER_LANGUAGE = os.getenv("WHISPER_LANGUAGE")  # e.g. "en", "sw", or unset = auto

# ---------------------------------------------------------------------------
# Paths — all runtime files under backend/runtime/
# ---------------------------------------------------------------------------
BASE_DIR = Path(__file__).resolve().parent
RUNTIME_DIR = BASE_DIR / "runtime"
UPLOAD_DIR = RUNTIME_DIR / "uploads"
TEMP_DIR = RUNTIME_DIR / "temp"
LOG_DIR = RUNTIME_DIR / "logs"

for d in (UPLOAD_DIR, TEMP_DIR, LOG_DIR):
    d.mkdir(parents=True, exist_ok=True)

LOG_FILE = LOG_DIR / "backend.log"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(LOG_FILE, encoding="utf-8"),
    ],
)
logger = logging.getLogger("yanbridge")

_model = None


def get_whisper_model():
    global _model
    if _model is None:
        logger.info(
            "loading whisper model=%s device=%s download_root=%s",
            WHISPER_MODEL,
            WHISPER_DEVICE,
            WHISPER_DOWNLOAD_ROOT,
        )
        _model = whisper.load_model(
            WHISPER_MODEL,
            device=WHISPER_DEVICE,
            download_root=WHISPER_DOWNLOAD_ROOT,
        )
        logger.info("whisper model loaded")
    return _model


def transcribe_file(path: Path) -> str:
    model = get_whisper_model()
    kwargs: dict = {}
    if WHISPER_LANGUAGE:
        kwargs["language"] = WHISPER_LANGUAGE
    result = model.transcribe(str(path), **kwargs)
    return (result.get("text") or "").strip()


# ---------------------------------------------------------------------------
# FastAPI
# ---------------------------------------------------------------------------
app = FastAPI(title="YanBridge ASR")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

logger.info("backend started (model loads on first /upload or WebSocket chunk)")


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.post("/upload")
async def upload(file: UploadFile = File(...)):
    logger.info(
        "upload received filename=%s content_type=%s",
        file.filename,
        file.content_type,
    )

    suffix = ".webm"
    if file.filename and "." in file.filename:
        suffix = "." + file.filename.rsplit(".", 1)[-1].lower()

    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    saved_path = UPLOAD_DIR / f"upload_{stamp}{suffix}"

    try:
        with saved_path.open("wb") as out:
            shutil.copyfileobj(file.file, out)
        logger.info("saved file path=%s", saved_path)

        logger.info("transcribe started path=%s", saved_path)
        text = transcribe_file(saved_path)
        logger.info("TRANSCRIBE TEXT: %s", text)
        return {"text": text}

    except Exception as e:
        logger.error("upload/transcribe error: %s", e)
        logger.error(traceback.format_exc())
        return {"error": str(e)}


@app.websocket("/ws/transcribe")
async def ws_transcribe(websocket: WebSocket):
    await websocket.accept()
    logger.info("WebSocket connected")
    chunk_num = 0

    try:
        while True:
            data = await websocket.receive_bytes()
            chunk_num += 1
            logger.info("chunk received #%s size=%s bytes", chunk_num, len(data))

            if len(data) < 8000:
                logger.warning("skip tiny chunk #%s size=%s", chunk_num, len(data))
                await websocket.send_json({
                    "text": "",
                    "final": False,
                    "chunk": chunk_num,
                    "error": "chunk too small, skipped",
                })
                continue

            stamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
            chunk_path = TEMP_DIR / f"chunk_{chunk_num}_{stamp}.webm"
            chunk_path.write_bytes(data)

            start = time.perf_counter()
            try:
                text = transcribe_file(chunk_path)
                latency_ms = int((time.perf_counter() - start) * 1000)
                payload = {
                    "text": text,
                    "final": True,
                    "chunk": chunk_num,
                    "latency_ms": latency_ms,
                }
                logger.info("chunk #%s text=%s latency_ms=%s", chunk_num, text, latency_ms)
                await websocket.send_json(payload)
            except Exception as e:
                logger.error("chunk transcribe error: %s", e)
                await websocket.send_json({"error": str(e), "chunk": chunk_num})

    except WebSocketDisconnect:
        logger.info("WebSocket disconnected after %s chunks", chunk_num)

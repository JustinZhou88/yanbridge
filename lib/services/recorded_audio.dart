import 'dart:typed_data';

/// Platform-neutral audio payload for upload / WebSocket send.
class RecordedAudio {
  const RecordedAudio({
    required this.bytes,
    required this.filename,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String filename;
  final String mimeType;

  int get size => bytes.length;
}

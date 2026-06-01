import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../config/api_config.dart';
import 'mic_input_exception.dart';
import 'recorded_audio.dart';

/// Android/iOS: record plugin → file bytes → POST /upload.
class AudioRecorderService {
  static const int minBytes = 5000;
  static const int minRecordMs = 2000;

  final AudioRecorder _recorder = AudioRecorder();
  DateTime? _startedAt;
  bool _isRecording = false;

  bool get isRecording => _isRecording;

  Future<void> _ensureMicPermission() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      throw MicInputException(
        'Microphone permission denied. Enable it in system Settings.',
      );
    }
    if (!await _recorder.hasPermission()) {
      throw MicInputException('Microphone not available on this device.');
    }
  }

  Future<void> startRecording() async {
    if (_isRecording) return;

    await _ensureMicPermission();
    _startedAt = DateTime.now();

    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/recording_${DateTime.now().millisecondsSinceEpoch}.m4a';

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );

    _isRecording = true;
    debugPrint('Mobile recorder started: $path');
  }

  Future<RecordedAudio?> stopRecording() async {
    if (!_isRecording) return null;

    final elapsedMs = DateTime.now().difference(_startedAt!).inMilliseconds;
    debugPrint('recording wall time: ${elapsedMs}ms');

    final path = await _recorder.stop();
    _isRecording = false;

    if (path == null || path.isEmpty) {
      debugPrint('stopRecording: no path');
      return null;
    }

    final file = File(path);
    if (!await file.exists()) {
      debugPrint('stopRecording: file missing');
      return null;
    }

    final bytes = await file.readAsBytes();
    debugPrint('recorded file size: ${bytes.length}');

    try {
      await file.delete();
    } catch (_) {}

    if (elapsedMs < minRecordMs) {
      debugPrint('too short: ${elapsedMs}ms < $minRecordMs');
      return null;
    }

    if (bytes.length <= minBytes) {
      debugPrint('file too small (${bytes.length} <= $minBytes)');
      return null;
    }

    return RecordedAudio(
      bytes: bytes,
      filename: 'recording.m4a',
      mimeType: 'audio/mp4',
    );
  }

  Future<String> uploadAndTranscribe(
    RecordedAudio audio, {
    String? uploadUrl,
  }) async {
    final url = uploadUrl ?? ApiConfig.uploadUrl;
    debugPrint('upload bytes size: ${audio.size} → $url');

    final uri = Uri.parse(url);
    final request = await HttpClient().postUrl(uri);
    final boundary =
        '----yanbridge${DateTime.now().millisecondsSinceEpoch}';
    request.headers.set(
      HttpHeaders.contentTypeHeader,
      'multipart/form-data; boundary=$boundary',
    );

    final body = StringBuffer();
    body.writeln('--$boundary');
    body.writeln(
      'Content-Disposition: form-data; name="file"; filename="${audio.filename}"',
    );
    body.writeln('Content-Type: ${audio.mimeType}');
    body.writeln();

    final prefix = utf8.encode(body.toString());
    final suffixBytes = utf8.encode('\r\n--$boundary--\r\n');

    request.contentLength =
        prefix.length + audio.bytes.length + suffixBytes.length;

    request.add(prefix);
    request.add(audio.bytes);
    request.add(suffixBytes);

    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();

    if (response.statusCode >= 200 && response.statusCode < 300) {
      try {
        final map = jsonDecode(responseBody) as Map<String, dynamic>;
        if (map.containsKey('error')) {
          return map['error'].toString();
        }
        return (map['text'] ?? '').toString();
      } catch (e) {
        return 'Invalid JSON from server: $responseBody';
      }
    }

    return 'Server returned HTTP ${response.statusCode}. '
        '${responseBody.isNotEmpty ? responseBody : "No response body."}';
  }
}

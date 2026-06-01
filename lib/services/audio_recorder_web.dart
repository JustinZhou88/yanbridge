// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_util' as js_util;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../config/api_config.dart';
import 'recorded_audio.dart';
import 'web_mic_recorder.dart';

/// Chrome Web: mic ¡ú MediaRecorder ¡ú merge on stop ¡ú POST /upload.
class AudioRecorderService {
  static const int minBlobBytes = 5000;
  static const int minRecordMs = 2000;

  html.MediaStream? _stream;
  html.MediaRecorder? _recorder;
  String _mimeType = 'audio/webm';
  final List<html.Blob> _chunks = [];
  DateTime? _startedAt;
  bool _isRecording = false;

  bool get isRecording => _isRecording;

  Future<void> startRecording() async {
    if (_isRecording) return;

    _chunks.clear();
    _startedAt = DateTime.now();
    _stream = await WebMicRecorder.openMicrophone();

    _mimeType = WebMicRecorder.pickMimeType();
    _recorder = html.MediaRecorder(_stream!, {'mimeType': _mimeType});

    _recorder!.addEventListener('dataavailable', (event) {
      final data = js_util.getProperty(event, 'data');
      if (data == null) return;

      final blob = data as html.Blob;
      if (blob.size > 0) {
        _chunks.add(blob);
        debugPrint('stream chunk size: ${blob.size}');
      }
    });

    _recorder!.start();
    if (_recorder!.state != 'recording') {
      throw Exception('MediaRecorder did not enter recording state');
    }

    _isRecording = true;
    debugPrint('MediaRecorder started mime=$_mimeType');
  }

  Future<RecordedAudio?> stopRecording() async {
    if (!_isRecording || _recorder == null) return null;

    final elapsedMs = DateTime.now().difference(_startedAt!).inMilliseconds;
    debugPrint('recording wall time: ${elapsedMs}ms');

    final recorder = _recorder!;
    final stopCompleter = Completer<void>();

    void onStop(html.Event _) {
      recorder.removeEventListener('stop', onStop);
      if (!stopCompleter.isCompleted) stopCompleter.complete();
    }

    recorder.addEventListener('stop', onStop);

    try {
      if (recorder.state == 'recording') {
        recorder.requestData();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        recorder.stop();
      }
      await stopCompleter.future.timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('stopRecording wait error: $e');
    }

    _isRecording = false;
    _recorder = null;

    if (_chunks.isEmpty) {
      debugPrint('chunks: 0');
      WebMicRecorder.stopStream(_stream);
      _stream = null;
      return null;
    }

    final blob = html.Blob(_chunks, _mimeType);
    debugPrint('parts=${_chunks.length}');
    debugPrint('blob.size=${blob.size}');

    _chunks.clear();
    WebMicRecorder.stopStream(_stream);
    _stream = null;

    if (elapsedMs < minRecordMs) {
      debugPrint('too short: ${elapsedMs}ms < $minRecordMs');
      return null;
    }

    if (blob.size <= minBlobBytes) {
      debugPrint('blob too small (${blob.size} <= $minBlobBytes)');
      return null;
    }

    final bytes = await _blobToBytes(blob);
    return RecordedAudio(
      bytes: bytes,
      filename: 'recording.webm',
      mimeType: _mimeType,
    );
  }

  Future<String> uploadAndTranscribe(
    RecordedAudio audio, {
    String? uploadUrl,
  }) async {
    final url = uploadUrl ?? ApiConfig.uploadUrl;
    debugPrint('upload blob size: ${audio.size}');

    final blob = html.Blob([audio.bytes], audio.mimeType);
    final form = html.FormData();
    form.appendBlob('file', blob, audio.filename);

    final xhr = html.HttpRequest();
    final completer = Completer<String>();

    xhr.open('POST', url);

    xhr.onLoad.listen((_) {
      final code = xhr.status ?? 0;
      final body = xhr.responseText ?? '';

      if (code >= 200 && code < 300) {
        try {
          final map = jsonDecode(body) as Map<String, dynamic>;
          if (map.containsKey('error')) {
            completer.complete(map['error'].toString());
          } else {
            completer.complete((map['text'] ?? '').toString());
          }
        } catch (e) {
          completer.complete('Invalid JSON from server: $body');
        }
      } else {
        completer.complete(
          'Server returned HTTP $code. ${body.isNotEmpty ? body : "No response body."}',
        );
      }
    });

    xhr.onError.listen((event) {
      completer.complete(
        'Network error (${event.type}): cannot reach $url. '
        'Is the backend running? Check ${ApiConfig.healthUrl}',
      );
    });

    xhr.send(form);
    return completer.future;
  }

  Future<Uint8List> _blobToBytes(html.Blob blob) async {
    final reader = html.FileReader();
    final completer = Completer<Uint8List>();
    reader.onLoadEnd.listen((_) {
      final result = reader.result;
      if (result is ByteBuffer) {
        completer.complete(result.asUint8List());
      } else {
        completer.completeError('Failed to read blob');
      }
    });
    reader.onError.listen((_) {
      completer.completeError('FileReader error');
    });
    reader.readAsArrayBuffer(blob);
    return completer.future;
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/api_config.dart';
import 'mic_input_exception.dart';

/// Android: amplitude VAD → record segments → WebSocket binary send.
class WebSocketAsrService {
  static const int minBytes = 8000;
  static const int silenceMs = 1000;
  static const double amplitudeThresholdDb = -40.0;

  final AudioRecorder _recorder = AudioRecorder();
  WebSocketChannel? _channel;
  StreamSubscription<Amplitude>? _amplitudeSub;

  bool _isStreaming = false;
  bool _isSpeaking = false;
  bool _isFinalizing = false;
  DateTime? _silenceStart;

  bool get isStreaming => _isStreaming;

  void Function(String text)? onTranscript;
  void Function(String message)? onStatus;
  void Function(String error)? onError;

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

  Future<void> startStreaming({String? wsUrl}) async {
    if (_isStreaming) return;

    await _ensureMicPermission();

    final url = wsUrl ?? ApiConfig.wsUrl;
    debugPrint('Mobile WebSocketAsr connecting to $url');

    _channel = WebSocketChannel.connect(Uri.parse(url));
    await _channel!.ready.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw Exception('WebSocket connection timeout'),
    );

    onStatus?.call('WebSocket connected');
    debugPrint('WebSocket connected');

    _channel!.stream.listen(
      (data) {
        try {
          final text = data is String ? data : utf8.decode(data as List<int>);
          final map = jsonDecode(text) as Map<String, dynamic>;
          if (map.containsKey('error')) {
            final err = map['error'].toString();
            if (err.contains('chunk too small')) {
              debugPrint('Backend skipped tiny chunk');
              return;
            }
            onError?.call(err);
            return;
          }
          final transcript = (map['text'] ?? '').toString().trim();
          if (transcript.isNotEmpty) {
            debugPrint('WS transcript: $transcript');
            onTranscript?.call(transcript);
          }
        } catch (e) {
          onError?.call('Invalid WebSocket JSON: $e');
        }
      },
      onError: (_) {
        onError?.call('WebSocket error. Is the backend running?');
      },
      onDone: () {
        onStatus?.call('WebSocket closed');
      },
    );

    _isStreaming = true;
    await _startSegment();

    _amplitudeSub = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 100))
        .listen(_onAmplitude);

    onStatus?.call('Streaming VAD (speak, pause 1s to send)');
    debugPrint('Mobile VAD streaming started');
  }

  Future<void> _startSegment() async {
    if (!_isStreaming) return;

    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/seg_${DateTime.now().millisecondsSinceEpoch}.m4a';

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );
    debugPrint('Mobile segment recording: $path');
  }

  void _onAmplitude(Amplitude amplitude) {
    if (!_isStreaming || _isFinalizing) return;

    final db = amplitude.current;
    if (db > amplitudeThresholdDb) {
      if (!_isSpeaking) {
        debugPrint('detected speech start (dB=$db)');
      }
      _isSpeaking = true;
      _silenceStart = null;
    } else if (_isSpeaking) {
      _silenceStart ??= DateTime.now();
      final silentFor = DateTime.now().difference(_silenceStart!).inMilliseconds;
      if (silentFor >= silenceMs) {
        debugPrint('detected silence (${silentFor}ms)');
        unawaited(_finalizeUtterance());
      }
    }
  }

  Future<void> _finalizeUtterance() async {
    if (_isFinalizing || !_isStreaming) return;
    if (!await _recorder.isRecording()) return;

    _isFinalizing = true;
    _isSpeaking = false;
    _silenceStart = null;

    try {
      final path = await _recorder.stop();
      if (path != null && path.isNotEmpty) {
        final file = File(path);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          debugPrint('segment file size: ${bytes.length}');
          if (bytes.length > minBytes) {
            _channel?.sink.add(bytes);
            debugPrint('WebSocket send success (${bytes.length} bytes)');
          } else {
            debugPrint('Skip tiny segment: ${bytes.length}');
          }
          try {
            await file.delete();
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('finalize utterance error: $e');
    } finally {
      _isFinalizing = false;
      if (_isStreaming) {
        await _startSegment();
      }
    }
  }

  Future<void> stopStreaming() async {
    if (!_isStreaming) return;

    _isStreaming = false;
    await _amplitudeSub?.cancel();
    _amplitudeSub = null;

    if (await _recorder.isRecording()) {
      try {
        final path = await _recorder.stop();
        if (path != null) {
          try {
            await File(path).delete();
          } catch (_) {}
        }
      } catch (_) {}
    }

    await _channel?.sink.close();
    _channel = null;

    onStatus?.call('Streaming stopped');
    debugPrint('Mobile VAD streaming stopped');
  }
}

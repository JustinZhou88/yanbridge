// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_util' as js_util;

import 'package:flutter/foundation.dart';

import '../config/api_config.dart';
import 'web_mic_recorder.dart';

/// VAD pseudo-realtime: recorder.start() without timeslice, send full webm per utterance.
class WebSocketAsrService {
  static const int minBlobBytes = 8000;
  static const int silenceMs = 1000;
  static const int vadPollMs = 100;
  static const double volumeThreshold = 0.012;

  html.WebSocket? _socket;
  html.MediaStream? _stream;
  html.MediaRecorder? _recorder;
  String _mimeType = 'audio/webm';
  final List<html.Blob> _chunks = [];

  Object? _audioContext;
  Object? _analyser;
  Timer? _vadTimer;

  bool _isStreaming = false;
  bool _isSpeaking = false;
  bool _isFinalizing = false;
  DateTime? _silenceStart;
  int _volumeLogTick = 0;

  bool get isStreaming => _isStreaming;

  void Function(String text)? onTranscript;
  void Function(String message)? onStatus;
  void Function(String error)? onError;

  Future<void> startStreaming({String? wsUrl}) async {
    if (_isStreaming) return;

    final url = wsUrl ?? ApiConfig.wsUrl;
    debugPrint(
      'WebSocketAsrService VAD: utterance on silence>$silenceMs ms, '
      'min blob $minBlobBytes bytes',
    );

    _socket = html.WebSocket(url);
    final openCompleter = Completer<void>();

    _socket!.onOpen.listen((_) {
      onStatus?.call('WebSocket connected');
      debugPrint('WebSocket connected');
      if (!openCompleter.isCompleted) openCompleter.complete();
    });

    _socket!.onMessage.listen((event) {
      try {
        final map = jsonDecode(event.data as String) as Map<String, dynamic>;
        if (map.containsKey('error')) {
          final err = map['error'].toString();
          if (err.contains('chunk too small')) {
            debugPrint('Backend skipped tiny chunk');
            return;
          }
          onError?.call(err);
          return;
        }
        final text = (map['text'] ?? '').toString().trim();
        if (text.isNotEmpty) {
          debugPrint('WS transcript: $text');
          onTranscript?.call(text);
        }
      } catch (e) {
        onError?.call('Invalid WebSocket JSON: $e');
      }
    });

    _socket!.onError.listen((_) {
      onError?.call('WebSocket error. Is the backend running?');
    });

    _socket!.onClose.listen((_) {
      onStatus?.call('WebSocket closed');
    });

    await openCompleter.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw Exception('WebSocket connection timeout'),
    );

    _stream = await WebMicRecorder.openMicrophone();
    _setupAudioAnalyser(_stream!);
    _isStreaming = true;
    _startRecorder();
    _vadTimer = Timer.periodic(
      const Duration(milliseconds: vadPollMs),
      (_) => _pollVad(),
    );

    onStatus?.call('Streaming VAD (speak, pause 1s to send)');
    debugPrint('VAD streaming started');
  }

  void _setupAudioAnalyser(html.MediaStream stream) {
    final ctor = js_util.getProperty(js_util.globalThis, 'AudioContext') ??
        js_util.getProperty(js_util.globalThis, 'webkitAudioContext');
    _audioContext = js_util.callConstructor(ctor as Object, const []);

    final source = js_util.callMethod(
      _audioContext!,
      'createMediaStreamSource',
      [stream],
    );
    _analyser = js_util.callMethod(_audioContext!, 'createAnalyser', const []);
    js_util.setProperty(_analyser!, 'fftSize', 2048);
    js_util.callMethod(source, 'connect', [_analyser]);
    debugPrint('AudioContext + AnalyserNode ready');
  }

  double _readVolume() {
    if (_analyser == null) return 0;

    final length = js_util.getProperty(_analyser!, 'fftSize') as int;
    final uint8ArrayCtor =
        js_util.getProperty(js_util.globalThis, 'Uint8Array') as Object;
    final dataArray =
        js_util.callConstructor(uint8ArrayCtor, [length]);

    js_util.callMethod(_analyser!, 'getByteTimeDomainData', [dataArray]);

    double sum = 0;
    for (var i = 0; i < length; i++) {
      final sample = (js_util.getProperty(dataArray, i) as num) - 128;
      sum += sample * sample;
    }
    return (sum / length) / 128 / 128;
  }

  void _pollVad() {
    if (!_isStreaming || _isFinalizing) return;

    final volume = _readVolume();
    _volumeLogTick++;
    if (_volumeLogTick % 10 == 0) {
      debugPrint('volume: ${volume.toStringAsFixed(4)}');
    }

    if (volume > volumeThreshold) {
      if (!_isSpeaking) {
        debugPrint('detected speech start (volume=$volume)');
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

  void _startRecorder() {
    if (!_isStreaming || _stream == null) return;

    _chunks.clear();
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

    _recorder!.addEventListener('stop', (_) {
      unawaited(_onRecorderStop());
    });

    _recorder!.start();
    debugPrint('MediaRecorder started (no timeslice)');
  }

  Future<void> _finalizeUtterance() async {
    if (_isFinalizing || _recorder == null) return;
    if (_recorder!.state != 'recording') return;

    _isFinalizing = true;
    _isSpeaking = false;
    _silenceStart = null;

    try {
      _recorder!.requestData();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (_recorder?.state == 'recording') {
        _recorder!.stop();
      }
    } catch (e) {
      debugPrint('finalize utterance error: $e');
    } finally {
      _isFinalizing = false;
    }
  }

  Future<void> _onRecorderStop() async {
    if (_chunks.isEmpty) {
      debugPrint('onStop: no chunks');
      if (_isStreaming) _startRecorder();
      return;
    }

    final blob = html.Blob(_chunks, _mimeType);
    _chunks.clear();
    debugPrint('parts merged, blob.size=${blob.size}');

    if (blob.size <= minBlobBytes) {
      debugPrint('Skip tiny blob: ${blob.size}');
    } else {
      _sendAudioBlob(blob);
    }

    if (_isStreaming) {
      _startRecorder();
    }
  }

  void _sendAudioBlob(html.Blob blob) {
    if (_socket == null || _socket!.readyState != html.WebSocket.OPEN) {
      debugPrint('WebSocket not open, skip send');
      return;
    }
    debugPrint('WebSocket send blob.size=${blob.size}');
    _socket!.send(blob);
    debugPrint('WebSocket send success');
  }

  Future<void> stopStreaming() async {
    if (!_isStreaming) return;

    _isStreaming = false;
    _vadTimer?.cancel();
    _vadTimer = null;

    if (_recorder != null && _recorder!.state == 'recording') {
      try {
        _recorder!.requestData();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        _recorder!.stop();
        await Future<void>.delayed(const Duration(milliseconds: 500));
      } catch (_) {}
    }

    _recorder = null;
    _chunks.clear();

    if (_audioContext != null) {
      try {
        js_util.callMethod(_audioContext!, 'close', const []);
      } catch (_) {}
      _audioContext = null;
      _analyser = null;
    }

    WebMicRecorder.stopStream(_stream);
    _stream = null;

    _socket?.close();
    _socket = null;

    onStatus?.call('Streaming stopped');
    debugPrint('VAD streaming stopped');
  }
}

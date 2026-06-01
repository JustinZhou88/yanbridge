// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:html' as html;
import 'dart:js_util' as js_util;

import 'package:flutter/foundation.dart';

import 'mic_input_exception.dart';

/// Shared Chrome mic + MediaRecorder helpers for upload & WebSocket.
class WebMicRecorder {
  static bool _isVirtualMicLabel(String label) {
    final l = label.toLowerCase();
    return l.contains('virtual') ||
        l.contains('todesk') ||
        l.contains('stereo mix') ||
        l.contains('loopback') ||
        l.contains('cable output');
  }

  static String pickMimeType() {
    const candidates = ['audio/webm;codecs=opus', 'audio/webm'];
    for (final mime in candidates) {
      if (html.MediaRecorder.isTypeSupported(mime)) {
        return mime;
      }
    }
    return 'audio/webm';
  }

  static Future<String?> _pickPhysicalDeviceId() async {
    final devices = await html.window.navigator.mediaDevices!.enumerateDevices();
    final inputs =
        devices.where((d) => d.kind == 'audioinput' && d.deviceId != null);

    for (final d in inputs) {
      final label = d.label ?? '';
      if (label.isNotEmpty && !_isVirtualMicLabel(label)) {
        debugPrint('Picked physical mic: $label');
        return d.deviceId;
      }
    }
    return null;
  }

  static Future<html.MediaStream> openMicrophone() async {
    final warm = await html.window.navigator.mediaDevices!.getUserMedia({
      'audio': true,
    });
    stopStream(warm);

    final deviceId = await _pickPhysicalDeviceId();
    final Map<String, dynamic> constraints;
    if (deviceId != null) {
      constraints = {
        'audio': {
          'deviceId': {'exact': deviceId},
        },
      };
    } else {
      constraints = {'audio': true};
    }

    final stream =
        await html.window.navigator.mediaDevices!.getUserMedia(constraints);

    final tracks = stream.getAudioTracks();
    if (tracks.isEmpty) {
      throw MicInputException('No microphone audio track from getUserMedia.');
    }

    final track = tracks.first;
    track.enabled = true;
    final label = track.label ?? '';
    debugPrint(
      'MIC: label="$label" muted=${track.muted} readyState=${track.readyState}',
    );

    if (_isVirtualMicLabel(label)) {
      stopStream(stream);
      throw MicInputException(
        'Browser selected a virtual mic ("$label"). '
        'In Windows Sound → Input, choose your real microphone (not ToDesk Virtual Audio). '
        'In Chrome, click the lock icon → Microphone → pick the correct device.',
      );
    }

    if (track.muted == true) {
      stopStream(stream);
      throw MicInputException(
        'Microphone track is muted (label="$label"). '
        'Unmute in Windows Sound settings and Chrome site permissions, '
        'then reload the page.',
      );
    }

    return stream;
  }

  static void stopStream(html.MediaStream? stream) {
    stream?.getAudioTracks().forEach((t) => t.stop());
  }

  static void _onDataAvailable(Object event, List<html.Blob> chunks) {
    final data = js_util.getProperty(event, 'data');
    if (data == null) return;

    final blob = data as html.Blob;
    if (blob.size > 0) {
      chunks.add(blob);
      debugPrint('stream chunk size: ${blob.size}');
    }
  }

  /// Record [durationMs], return merged webm Blob (no timeslice on start).
  static Future<html.Blob?> recordForDuration(
    html.MediaStream stream,
    int durationMs,
  ) async {
    final chunks = <html.Blob>[];
    final mimeType = pickMimeType();
    final recorder = html.MediaRecorder(stream, {'mimeType': mimeType});

    recorder.addEventListener('dataavailable', (event) {
      _onDataAvailable(event, chunks);
    });

    final stopped = Completer<void>();
    void onStop(html.Event _) {
      recorder.removeEventListener('stop', onStop);
      if (!stopped.isCompleted) stopped.complete();
    }

    recorder.addEventListener('stop', onStop);

    recorder.start();
    if (recorder.state != 'recording') {
      debugPrint('WARN: MediaRecorder state=${recorder.state}');
    }

    await Future<void>.delayed(Duration(milliseconds: durationMs));

    if (recorder.state == 'recording') {
      recorder.requestData();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      recorder.stop();
    }

    try {
      await stopped.future.timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('recordForDuration stop timeout: $e');
    }

    if (chunks.isEmpty) {
      debugPrint('recordForDuration: chunks.isEmpty');
      return null;
    }

    final blob = html.Blob(chunks, mimeType);
    debugPrint('parts=${chunks.length}');
    debugPrint('blob.size=${blob.size}');
    return blob;
  }
}

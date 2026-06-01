import 'package:flutter/material.dart';

import '../config/api_config.dart';
import '../services/audio_recorder_service.dart';
import '../services/mic_input_exception.dart';
import '../services/websocket_asr_service.dart';
import '../widgets/transcript_box.dart';

class RealtimeASRPage extends StatefulWidget {
  const RealtimeASRPage({super.key});

  @override
  State<RealtimeASRPage> createState() => _RealtimeASRPageState();
}

class _RealtimeASRPageState extends State<RealtimeASRPage> {
  final AudioRecorderService _recorder = AudioRecorderService();
  final WebSocketAsrService _ws = WebSocketAsrService();

  String _status = 'Idle';
  String _transcript = '';

  @override
  void initState() {
    super.initState();
    _ws.onStatus = (msg) => setState(() => _status = msg);
    _ws.onError = (err) => setState(() {
      _status = 'Error';
      _transcript = err;
    });
    _ws.onTranscript = (text) => setState(() {
      _transcript = _transcript.isEmpty ? text : '$_transcript\n$text';
    });
  }

  @override
  void dispose() {
    _ws.stopStreaming();
    super.dispose();
  }

  Future<void> _startRecording() async {
    if (_recorder.isRecording) return;
    if (_ws.isStreaming) await _ws.stopStreaming();

    setState(() {
      _status = 'Recording...';
      _transcript = '';
    });

    try {
      await _recorder.startRecording();
      setState(() => _status = 'Recording...');
    } on MicInputException catch (e) {
      setState(() {
        _status = 'Error';
        _transcript = e.message;
      });
    } catch (e) {
      setState(() {
        _status = 'Error';
        _transcript = 'Microphone permission denied or unavailable: $e';
      });
    }
  }

  Future<void> _stopRecording() async {
    if (!_recorder.isRecording) return;

    setState(() => _status = 'Uploading...');

    final audio = await _recorder.stopRecording();
    if (audio == null) {
      setState(() {
        _status = 'Error';
        _transcript =
            'No valid audio. Hold Start Recording at least 2 seconds, speak clearly, '
            'then Stop. Check Console for recording wall time / blob size.';
      });
      return;
    }

    setState(() => _status = 'Transcribing...');

    final result = await _recorder.uploadAndTranscribe(audio);
    final isError = result.startsWith('Network error') ||
        result.startsWith('Server returned HTTP') ||
        result.startsWith('Invalid JSON');

    setState(() {
      _status = isError ? 'Error' : 'Done';
      _transcript = result;
    });
  }

  Future<void> _startStreaming() async {
    if (_recorder.isRecording || _ws.isStreaming) return;

    setState(() {
      _status = 'Connecting WebSocket...';
      _transcript = '(waiting for first segment...)';
    });

    try {
      await _ws.startStreaming();
    } on MicInputException catch (e) {
      setState(() {
        _status = 'Error';
        _transcript = e.message;
      });
    } catch (e) {
      setState(() {
        _status = 'Error';
        _transcript = 'Streaming failed: $e';
      });
    }
  }

  Future<void> _stopStreaming() async {
    await _ws.stopStreaming();
    setState(() => _status = 'Idle');
  }

  @override
  Widget build(BuildContext context) {
    final recording = _recorder.isRecording;
    final streaming = _ws.isStreaming;

    return Scaffold(
      appBar: AppBar(
        title: const Text('YanBridge Realtime ASR'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Backend Upload URL: ${ApiConfig.uploadUrl}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'WebSocket URL: ${ApiConfig.wsUrl}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Text('Status', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              _status,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed:
                        recording || streaming ? null : _startRecording,
                    child: const Text('Start Recording'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: recording ? _stopRecording : null,
                    child: const Text('Stop Recording'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonal(
                    onPressed:
                        recording || streaming ? null : _startStreaming,
                    child: const Text('Start Streaming'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: streaming ? _stopStreaming : null,
                    child: const Text('Stop Streaming'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text('Transcript', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Expanded(child: TranscriptBox(text: _transcript)),
          ],
        ),
      ),
    );
  }
}

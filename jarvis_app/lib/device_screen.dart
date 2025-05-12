// lib/device_screen.dart

import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'services/audio_stream_service.dart';
import 'services/whisper_service.dart';
import 'services/chat_service.dart';
import 'services/audio_player_service.dart';

class DeviceScreen extends StatefulWidget {
  final BluetoothDevice device;
  final String openaiApiKey;

  const DeviceScreen({
    required this.device,
    required this.openaiApiKey,
    super.key,
  });

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  late final AudioStreamService _streamSvc;
  late final AudioPlayerService  _playerSvc;
  late final WhisperService      _whisperSvc;
  late final ChatService         _chatSvc;

  bool    _connected    = false;
  bool    _isSending    = false;
  String  _statusMessage = '';

  @override
  void initState() {
    super.initState();

    _playerSvc  = AudioPlayerService();
    _whisperSvc = WhisperService(widget.openaiApiKey);
    _chatSvc    = ChatService(widget.openaiApiKey);

    _streamSvc = AudioStreamService(
      widget.device,
      onData: () {
        // update buffering UI
        setState(() {});
      },
      onDone: () {
        // once full WAV is in, fire off the pipeline
        _startProcessing();
      },
    );

    _initAll();
  }

  Future<void> _initAll() async {
    await _playerSvc.init();
    await _streamSvc.init();
    setState(() {
      _connected     = true;
      _statusMessage = '✅ Connected – waiting for audio…';
    });
  }

  @override
  void dispose() {
    _streamSvc.dispose();
    _playerSvc.dispose();
    super.dispose();
  }

  /// Called automatically when _streamSvc buffers a full WAV,
  /// or you can hook this to a button if you still want manual control.
  Future<void> _startProcessing() async {
    if (_isSending || _streamSvc.audioBuffer.isEmpty) return;
    setState(() {
      _isSending     = true;
      _statusMessage = '📝 Transcribing audio to text…';
    });

    //final wav = Uint8List.fromList(_streamSvc.audioBuffer);
    final wav = _streamSvc.getPcmWav();
    try {
      // 1) Whisper
      final text = await _whisperSvc.transcribe(wav);
      setState(() {
        _statusMessage = '🚀 Sending to ChatGPT…';
      });

      // 2) Chat
      final reply = await _chatSvc.chat(text);
      setState(() {
        _statusMessage = '🗣️ Speaking reply…';
      });

      // 3) TTS
      await _playerSvc.speak(reply);

      setState(() {
        _statusMessage = '✅ Done – ready for next message';
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
      setState(() {
        _statusMessage = '⚠️ Error: $e';
      });
    } finally {
      // clear buffer so the next WAV can be captured
      _streamSvc.audioBuffer.clear();
      _isSending = false;
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext ctx) {
    final bufLen = _streamSvc.audioBuffer.length;
    final total  = _streamSvc.expectedLength;
    final bufferStatus = !_connected
      ? '⏳ Connecting…'
      : bufLen == 0
        ? '⏳ Waiting for data…'
        : total == null
          ? '⏳ Waiting for header…'
          : bufLen < total
            ? '⏳ Buffering… $bufLen / $total bytes'
            : '✅ Buffered $total bytes';

    return Scaffold(
      appBar: AppBar(title: Text(widget.device.platformName)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(bufferStatus,   style: Theme.of(ctx).textTheme.bodyMedium),
            const SizedBox(height: 8),
            Text(_statusMessage, style: Theme.of(ctx).textTheme.bodyMedium),
            const Spacer(),
            // optional manual retry:
            ElevatedButton.icon(
              onPressed: (_isSending || !_connected || bufLen == 0) 
                  ? null 
                  : _startProcessing,
              icon: const Icon(Icons.send),
              label: Text(_isSending
                ? 'Working…'
                : 'Send to ChatGPT'),
            ),
          ],
        ),
      ),
    );
  }
}

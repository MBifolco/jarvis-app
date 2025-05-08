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
  late final AudioPlayerService _playerSvc;
  late final WhisperService _whisperSvc;
  late final ChatService _chatSvc;

  bool _connected = false;
  bool _isSending = false;
  bool _isPlaying  = false;

  @override
  void initState() {
    super.initState();
    _playerSvc  = AudioPlayerService();
    _whisperSvc = WhisperService(widget.openaiApiKey);
    _chatSvc    = ChatService(widget.openaiApiKey);

    // give us a hook so setState() is called on each chunk
    _streamSvc = AudioStreamService(
      widget.device,
      onData: () => setState(() {}),
    );

    _initAll();
  }

  Future<void> _initAll() async {
    await _playerSvc.init();
    await _streamSvc.init();
    setState(() => _connected = true);
  }

  @override
  void dispose() {
    _streamSvc.dispose();
    _playerSvc.dispose();
    super.dispose();
  }

  Future<void> _onSend() async {
    if (_isSending || _streamSvc.audioBuffer.isEmpty) return;
    setState(() => _isSending = true);

    try {
      final wav = Uint8List.fromList(_streamSvc.audioBuffer);

      // 1) play the full buffer
      setState(() => _isPlaying = true);
      await _playerSvc.playBuffer(wav);
      setState(() => _isPlaying = false);

      // 2) Whisper → Chat → TTS
      final text  = await _whisperSvc.transcribe(wav);
      final reply = await _chatSvc.chat(text);
      await _playerSvc.speak(reply);

      _streamSvc.audioBuffer.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext ctx) {
    final bufLen = _streamSvc.audioBuffer.length;
    final total  = _streamSvc.expectedLength;
    final status = !_connected
      ? '⏳ Connecting…'
      : _isPlaying
        ? '🔊 Playing buffered audio…'
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
            Text(status, style: Theme.of(ctx).textTheme.bodyMedium),
            const Spacer(),
            ElevatedButton.icon(
              onPressed: (_isSending || !_connected) ? null : _onSend,
              icon: const Icon(Icons.play_arrow),
              label: Text(_isSending ? 'Working…' : 'Play & Send to ChatGPT'),
            ),
          ],
        ),
      ),
    );
  }
}

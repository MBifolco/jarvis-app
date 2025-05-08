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
  late final AudioPlayerService _playerSvc;
  late final WhisperService _whisperSvc;
  late final ChatService _chatSvc;

  bool _connected = false;
  bool _isSending = false;

  @override
  void initState() {
    super.initState();
    _streamSvc  = AudioStreamService(widget.device);
    _playerSvc  = AudioPlayerService();
    _whisperSvc = WhisperService(widget.openaiApiKey);
    _chatSvc    = ChatService(widget.openaiApiKey);
    _initAll();
  }

  Future<void> _initAll() async {
    // 1) init the player
    await _playerSvc.init();
    // 2) connect & start buffering from your Jarvis device
    await _streamSvc.init();
    if (!mounted) return;
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
      // grab the full WAV (with header) that’s been buffered
      final wav = Uint8List.fromList(_streamSvc.audioBuffer);

      // play the entire buffer in one shot
      await _playerSvc.playBuffer(wav);

      // transcribe → chat → speak
      final text  = await _whisperSvc.transcribe(wav);
      final reply = await _chatSvc.chat(text);
      await _playerSvc.speak(reply);

      // clear for next round
      _streamSvc.audioBuffer.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext ctx) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.device.platformName)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(
              _connected
                ? '✅ Audio buffered and ready'
                : '⏳ Connecting to device…',
              style: Theme.of(ctx).textTheme.bodyMedium,
            ),
            const Spacer(),
            ElevatedButton.icon(
              onPressed: (_isSending || !_connected) ? null : _onSend,
              icon: const Icon(Icons.play_arrow),
              label: Text(
                _isSending ? 'Working…' : 'Play & Send to ChatGPT',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

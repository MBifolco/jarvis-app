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

  bool _connected = false;
  bool _isSending = false;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();

    _playerSvc  = AudioPlayerService();
    _whisperSvc = WhisperService(widget.openaiApiKey);
    _chatSvc    = ChatService(widget.openaiApiKey);

    // AudioStreamService now takes the device ID string as its first arg:
    _streamSvc = AudioStreamService(
      widget.device.remoteId.str,
      onData: _onData,
    );

    _initAll();
  }

  Future<void> _initAll() async {
    await _playerSvc.init();
    await _streamSvc.init();
    if (mounted) setState(() => _connected = true);
  }

  @override
  void dispose() {
    _streamSvc.dispose();
    _playerSvc.dispose();
    super.dispose();
  }

  /// Called on each chunk. Once the buffer is "full," fire off the send.
  void _onData() {
    setState(() {}); // rebuild to update progress
    final bufLen = _streamSvc.audioBuffer.length;
    final total  = _streamSvc.expectedLength;
    if (total != null && bufLen >= total && !_isSending) {
      _onSend();
    }
  }

  Future<void> _onSend() async {
    if (_isSending || _streamSvc.audioBuffer.isEmpty) return;
    setState(() => _isSending = true);

    try {
      final wav = Uint8List.fromList(_streamSvc.audioBuffer);

      // 1) Play it back in one shot
      setState(() => _isPlaying = true);
      await _playerSvc.playBuffer(wav);
      setState(() => _isPlaying = false);

      // 2) Transcribe (Whisper) → Chat → speak reply
      final text  = await _whisperSvc.transcribe(wav);
      final reply = await _chatSvc.chat(text);
      await _playerSvc.speak(reply);

      // 3) Clear + restart for next round
      _streamSvc.audioBuffer.clear();
      _streamSvc.expectedLength = null;
      await _streamSvc.init();
      if (mounted) setState(() {});
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

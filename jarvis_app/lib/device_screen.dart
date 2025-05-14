import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'services/audio_stream_service.dart';
import 'services/realtime_service.dart';
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
  late final AudioPlayerService _playerSvc;
  late final RealtimeService   _realtimeSvc;
  late AudioStreamService      _streamSvc;

  bool _connected    = false;
  bool _isSending    = false;
  bool _playOnDevice = true;
  bool _useOpus      = false;     // ← choose at startup
  String _statusMessage = '';

  @override
  void initState() {
    super.initState();
    _playerSvc = AudioPlayerService();
    _realtimeSvc = RealtimeService(
      widget.openaiApiKey,
      onAudio: _handleTtsAudio,
    );
    // instantiate with _useOpus flag
    _streamSvc = AudioStreamService(
      widget.device,
      useOpus: _useOpus,
      onData: () => setState(() {}),
      onDone: _startProcessing,
    );
    _initAll();
  }

  Future<void> _initAll() async {
    await _playerSvc.init();
    await _realtimeSvc.init();
    await _streamSvc.init();
    setState(() {
      _connected = true;
      _statusMessage = '✅ Connected – buffering (${_useOpus ? "Opus" : "ADPCM"})';
    });
  }

  @override
  void dispose() {
    _streamSvc.dispose();
    _playerSvc.dispose();
    _realtimeSvc.dispose();
    super.dispose();
  }

  Future<void> _handleTtsAudio(Uint8List wav) async {
    if (_playOnDevice) {
      setState(() => _statusMessage = '🔊 Sending TTS to device…');
      await _streamSvc.sendWavToDevice(wav);
      setState(() => _statusMessage = '✅ Played on device');
    } else {
      setState(() => _statusMessage = '🔊 Playing TTS on phone…');
      await _playerSvc.playBuffer(wav, onFinished: () {
        setState(() => _statusMessage = '✅ Done playing on phone');
      });
    }
  }

  Future<void> _startProcessing() async {
    if (_isSending || _streamSvc.audioBuffer.isEmpty) return;
    setState(() {
      _isSending = true;
      _statusMessage = '🎤 Sending to OpenAI…';
    });
    try {
      await _realtimeSvc.sendAudio(_streamSvc.getPcmWav());
      setState(() => _statusMessage = '⏳ Awaiting reply…');
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      setState(() => _statusMessage = '⚠️ Error: $e');
    } finally {
      _streamSvc.reset();
      _isSending = false;
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
            ? '⏳ Buffering… $bufLen / $total'
            : '✅ Buffered $total bytes';

    return Scaffold(
      appBar: AppBar(title: Text(widget.device.platformName)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // new toggle if you want to switch in UI before reconnect:
            SwitchListTile(
              title: const Text('Use Opus decoding'),
              value: _useOpus,
              onChanged: (v) {
                // note: this only takes effect on re-init
                setState(() => _useOpus = v);
              },
            ),
            const SizedBox(height: 8),

            Text(bufferStatus,   style: Theme.of(ctx).textTheme.bodyMedium),
            const SizedBox(height: 8),
            Text(_statusMessage, style: Theme.of(ctx).textTheme.bodyMedium),
            const Divider(height: 32),

            SwitchListTile(
              title: const Text('Play TTS on device speaker'),
              value: _playOnDevice,
              onChanged: (v) => setState(() => _playOnDevice = v),
            ),
            const Spacer(),
            ElevatedButton.icon(
              onPressed: (_isSending || !_connected || bufLen == 0)
                ? null
                : _startProcessing,
              icon: const Icon(Icons.send),
              label: Text(_isSending ? 'Working…' : 'Send to OpenAI'),
            ),
          ],
        ),
      ),
    );
  }
}

// lib/device_screen.dart

import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'services/bt_connection_service.dart';
import 'services/audio_stream_service.dart';
import 'services/realtime_service.dart';
import 'services/audio_player_service.dart';
import 'services/config_service.dart';

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
  late final RealtimeService _realtimeSvc;
  late final ConfigService _configSvc;

  bool _connected     = false;
  bool _isSending     = false;
  bool _playOnDevice  = true;  // <-- toggle default
  String _statusMessage = '';

  @override
  void initState() {
    super.initState();
    _playerSvc = AudioPlayerService();

    // onAudio will be called for each TTS WAV
    _realtimeSvc = RealtimeService(
      widget.openaiApiKey,
      onAudio: _handleTtsAudio,
    );

    _streamSvc = AudioStreamService(
      widget.device,
      onData: () => setState(() {}),
      onDone: _startProcessing,
    );

    _configSvc = ConfigService(
      widget.device,
      onConfigUpdate: _handleConfigUpdate,
    );

    _initAll();
  }

  Future<void> _initAll() async {
    await _playerSvc.init();
    await _realtimeSvc.init();
    final btService = BluetoothConnectionService(widget.device);
    await btService.initAll([_streamSvc, _configSvc]);

    setState(() {
      _connected     = true;
      _statusMessage = '✅ Connected – waiting for audio…';
    });
  }

  @override
  void dispose() {
    _streamSvc.dispose();
    _playerSvc.dispose();
    _realtimeSvc.dispose();
    _configSvc.dispose();
    super.dispose();
  }

  /// Routes incoming TTS WAV to the chosen output
  Future<void> _handleTtsAudio(Uint8List wav) async {
    if (_playOnDevice) {
      setState(() => _statusMessage = '🔊 Sending TTS to device speaker…');
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
      _isSending     = true;
      _statusMessage = '🎤 Sending your audio to OpenAI…';
    });

    final wav = _streamSvc.getPcmWav();
    try {
      await _realtimeSvc.sendAudio(wav);
      setState(() {
        _statusMessage = '⏳ Awaiting TTS reply…';
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Error: $e')));
      setState(() {
        _statusMessage = '⚠️ Error: $e';
      });
    } finally {
      _streamSvc.reset();
      _isSending = false;
    }
  }

  void _handleConfigUpdate(List<int> bytes) {
    // You can parse these however you'd like.
    debugPrint("📥 Received config: $bytes");
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

// lib/device_screen.dart

import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'services/bt_connection_service.dart';
import 'services/audio_stream_service.dart';
import 'services/realtime_service.dart';
import 'services/audio_player_service.dart';
import 'services/config_service.dart';
import 'services/transcript_service.dart';
import 'services/whisper_service.dart';
import 'widgets/transcript_widget.dart';
import '../models/device_config.dart';

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
  late final TranscriptService _transcriptSvc;
  late final WhisperService _whisperSvc;
  DeviceConfig get _config => _configSvc.config;

  bool _connected     = false;
  bool _isSending     = false;
  String _statusMessage = '';

  @override
  void initState() {
    super.initState();
    _playerSvc = AudioPlayerService();
    _transcriptSvc = TranscriptService();
    _whisperSvc = WhisperService(widget.openaiApiKey);

    // onAudio will be called for each TTS WAV
    _realtimeSvc = RealtimeService(
      widget.openaiApiKey,
      onAudio: _handleTtsAudio,
      transcriptService: _transcriptSvc,
    );


    _configSvc = ConfigService(
      widget.device,
      onConfigUpdated: () => setState(() {}),
    );

    _streamSvc = AudioStreamService(
      widget.device,
      onData: () => setState(() {}),
      onDone: _startProcessing,
      config: _configSvc.config,
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
    _transcriptSvc.dispose();
    super.dispose();
  }

  /// Send TTS audio to device (always - removed phone playback option)
  Future<void> _handleTtsAudio(Uint8List wav) async {
    setState(() => _statusMessage = '🔊 Sending TTS to device speaker…');
    await _streamSvc.sendWavToDevice(wav);
    setState(() => _statusMessage = '✅ Played on device');
  }

  Future<void> _startProcessing() async {
    if (_isSending || _streamSvc.audioBuffer.isEmpty) return;
    setState(() {
      _isSending     = true;
      _statusMessage = '🎤 Sending your audio to OpenAI…';
    });

    final wav = _streamSvc.getPcmWav();
    
    // Add placeholder user message immediately
    final placeholderMessageId = _transcriptSvc.addPlaceholderUserMessage();
    
    try {
      // Send to Realtime API immediately (don't wait for transcription)
      final realtimeTask = _realtimeSvc.sendAudio(wav);
      
      // Start Whisper transcription async (don't block the conversation)
      final transcriptionTask = _transcribeUserAudio(wav, placeholderMessageId);
      
      // Wait for realtime API to complete
      await realtimeTask;
      
      setState(() {
        _statusMessage = '⏳ Awaiting assistant reply…';
      });
      
      // Let transcription continue in background
      transcriptionTask.catchError((e) {
        // If transcription fails, update placeholder with error
        if (mounted) {
          _transcriptSvc.updateUserMessage(placeholderMessageId, "❌ Transcription failed");
        }
      });
      
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
      setState(() {
        _statusMessage = '⚠️ Error: $e';
      });
      // Update placeholder with error
      _transcriptSvc.updateUserMessage(placeholderMessageId, "❌ Error sending audio");
    } finally {
      _streamSvc.reset();
      _isSending = false;
    }
  }

  Future<void> _transcribeUserAudio(Uint8List wav, String messageId) async {
    try {
      final userTranscript = await _whisperSvc.transcribe(wav);
      if (mounted) {
        _transcriptSvc.updateUserMessage(messageId, userTranscript);
      }
    } catch (e) {
      if (mounted) {
        _transcriptSvc.updateUserMessage(messageId, "❌ Transcription failed");
      }
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
            const Divider(height: 32),
            SwitchListTile(
              title: const Text('Send Debug Drops'),
              value: _config.sendDebugDrops,
              onChanged: (v) => setState(() => _config.setSendDebugDrops(v)),
            ),
            ListTile(
              title: const Text('LED Brightness'),
              subtitle: Text('${_config.ledBrightness}'),
            ),
            const SizedBox(height: 16),
            TranscriptWidget(transcriptService: _transcriptSvc),
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

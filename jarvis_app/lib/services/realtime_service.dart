// lib/services/realtime_service.dart

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:openai_realtime_dart/openai_realtime_dart.dart';
import 'audio_player_service.dart';

class RealtimeService {
  final RealtimeClient _client;
  final AudioPlayerService _player;
  bool _connected = false;

  RealtimeService(String apiKey)
      : _client = RealtimeClient(apiKey: apiKey),
        _player = AudioPlayerService();

  Future<void> init() async {
    debugPrint('🚀 [RealtimeService] init()');

    // Bring up the audio player first
    await _player.init();

    // Ask for TTS audio back, with a server‐VAD threshold of 0.8
    await _client.updateSession(
      voice: Voice.alloy,
      turnDetection: TurnDetection(
        type: TurnDetectionType.serverVad,
        threshold: 0.8,
      ),
    );

    // Error handler
    _client.on(RealtimeEventType.error, (evt) {
      final err = (evt as RealtimeEventError).error;
      debugPrint('❌ Realtime API error: $err');
    });

    // Log partial transcripts
    _client.on(RealtimeEventType.conversationUpdated, (evt) {
      final t = (evt as RealtimeEventConversationUpdated)
          .result
          .delta
          ?.transcript;
      debugPrint('🗣 partial transcript: "${t ?? ''}"');
    });

    // Handle final messages (complete transcript + streamed PCM)
    _client.on(RealtimeEventType.conversationItemCompleted, (evt) {
      final wrapper = (evt as RealtimeEventConversationItemCompleted).item;
      final msg        = wrapper.item as ItemMessage;
      final rawPcm     = wrapper.formatted?.audio ?? <dynamic>[];
      final transcript = wrapper.formatted?.transcript ?? '';

      debugPrint('✅ completed id=${msg.id} role=${msg.role.name}');
      debugPrint('   • transcript          = "$transcript"');
      debugPrint('   • raw PCM byte count  = ${rawPcm.length}');

      if (rawPcm.isNotEmpty) {
        // Cast to List<int>
        final pcmBytes = rawPcm.cast<int>();
        // Build a 24 kHz WAV
        final wav = _buildPcmWav(pcmBytes);
        debugPrint('   • built 24 kHz WAV: ${wav.length} bytes');
        // Inspect the header
        debugPrint('WAV header hex: ' +
            wav
                .sublist(0, 32)
                .map((b) => b.toRadixString(16).padLeft(2, '0'))
                .join(' '));
        // Inspect the B64 prefix
        final b64 = base64Encode(wav);
        debugPrint('WAV b64 prefix: ${b64.substring(0, 80)}');

        _player.playBuffer(wav, onFinished: () {
          debugPrint('🔈 TTS playback finished');
        });
      } else {
        debugPrint('   • no audio payload');
      }
    });

    // Connect
    debugPrint('🌐 connecting RealtimeClient…');
    await _client.connect();
    _connected = true;
    debugPrint('🔗 connected');
  }

  Future<void> sendAudio(Uint8List wavBytes) async {
    if (!_connected) throw StateError('RealtimeService not initialized');
    final b64 = base64Encode(wavBytes);
    debugPrint(
      '🎵 sendAudio: rawBytes=${wavBytes.length}, b64Chars=${b64.length}'
    );
    await _client.sendUserMessageContent([
      ContentPart.inputAudio(audio: b64),
    ]);
  }

  Future<void> dispose() async {
    debugPrint('🛑 disposing RealtimeService');
    _player.dispose();
    try {
      await _client.disconnect();
    } catch (_) {}
    _connected = false;
  }

  // — WAV builder: 16-bit PCM @ 24 kHz mono —
  Uint8List _buildPcmWav(List<int> samples) {
    const sampleRate    = 24000;       // 24 kHz to match API output
    const numChannels   = 1;
    const bitsPerSample = 16;
    final byteRate   = sampleRate * numChannels * bitsPerSample ~/ 8;
    final blockAlign = numChannels * bitsPerSample ~/ 8;
    final dataSize   = samples.length;       // raw PCM bytes
    final fileSize   = 44 + dataSize;

    final b = BytesBuilder()
      // RIFF header
      ..add(ascii.encode('RIFF'))
      ..add(_u32(fileSize - 8))
      ..add(ascii.encode('WAVE'))
      // fmt chunk
      ..add(ascii.encode('fmt '))
      ..add(_u32(16))
      ..add(_u16(1))
      ..add(_u16(numChannels))
      ..add(_u32(sampleRate))
      ..add(_u32(byteRate))
      ..add(_u16(blockAlign))
      ..add(_u16(bitsPerSample))
      // data chunk
      ..add(ascii.encode('data'))
      ..add(_u32(dataSize))
      // PCM bytes
      ..add(samples);

    return Uint8List.fromList(b.toBytes());
  }

  List<int> _u16(int v) => [v & 0xFF, (v >> 8) & 0xFF];
  List<int> _u32(int v) => [
        v & 0xFF,
        (v >> 8) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 24) & 0xFF,
      ];
}

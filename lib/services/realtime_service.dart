// lib/services/realtime_service.dart

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:openai_realtime_dart/openai_realtime_dart.dart';
import 'audio_player_service.dart';

class RealtimeService {
  final RealtimeClient _client;
  final AudioPlayerService _player;
  final void Function(Uint8List wav)? onAudio;
  bool _connected = false;

  RealtimeService(
    String apiKey, {
    this.onAudio,
  }) : 
    _client = RealtimeClient(apiKey: apiKey),
    _player = AudioPlayerService();

  Future<void> init() async {
    debugPrint('🚀 [RealtimeService] init()');
    await _player.init();
    await _client.updateSession(
      voice: Voice.alloy,
      turnDetection: TurnDetection(
        type: TurnDetectionType.serverVad,
        threshold: 0.8,
      ),
    );
    _client.on(RealtimeEventType.error, (evt) {
      debugPrint('❌ Realtime API error: ${(evt as RealtimeEventError).error}');
    });
    _client.on(RealtimeEventType.conversationUpdated, (evt) {
      final t = (evt as RealtimeEventConversationUpdated)
        .result.delta?.transcript;
      debugPrint('🗣 partial transcript: "${t ?? ''}"');
    });

    _client.on(RealtimeEventType.conversationItemCompleted, (evt) {
      final wrapper = (evt as RealtimeEventConversationItemCompleted).item;
      final msg        = wrapper.item as ItemMessage;
      final rawPcm     = wrapper.formatted?.audio ?? <dynamic>[];
      final transcript = wrapper.formatted?.transcript ?? '';
      debugPrint('✅ completed id=${msg.id} role=${msg.role.name}');
      debugPrint('   • transcript         = "$transcript"');
      debugPrint('   • raw PCM byte count = ${rawPcm.length}');

      if (rawPcm.isNotEmpty) {
        final pcmBytes = rawPcm.cast<int>();
        final wav = _buildPcmWav(pcmBytes);
        debugPrint('   • built 24 kHz WAV: ${wav.length} bytes');
        if (onAudio != null) {
          onAudio!(wav);
        } else {
          _player.playBuffer(wav, onFinished: () {
            debugPrint('🔈 TTS playback finished');
          });
        }
      } else {
        debugPrint('   • no audio payload');
      }
    });

    debugPrint('🌐 connecting RealtimeClient…');
    await _client.connect();
    _connected = true;
    debugPrint('🔗 connected');
  }

  Future<void> sendAudio(Uint8List wavBytes) async {
    if (!_connected) throw StateError('RealtimeService not initialized');
    final b64 = base64Encode(wavBytes);
    debugPrint('🎵 sendAudio: rawBytes=${wavBytes.length}, b64Chars=${b64.length}');
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

  Uint8List _buildPcmWav(List<int> rawBytes) {
    const sampleRate    = 24000, // 24 kHz to match API
          numChannels   = 1,
          bitsPerSample = 16;
    final byteRate   = sampleRate * numChannels * bitsPerSample ~/ 8;
    final blockAlign = numChannels * bitsPerSample ~/ 8;
    
    // Convert raw bytes to 16-bit samples (little-endian)
    final samples = <int>[];
    for (int i = 0; i < rawBytes.length - 1; i += 2) {
      final lowByte = rawBytes[i] & 0xFF;
      final highByte = rawBytes[i + 1] & 0xFF;
      // Combine bytes into 16-bit signed sample (little-endian)
      final sample = (highByte << 8) | lowByte;
      // Convert to signed 16-bit
      final signed = sample > 32767 ? sample - 65536 : sample;
      samples.add(signed);
    }
    
    final dataSize = samples.length * 2;  // 2 bytes per 16-bit sample
    final fileSize = 44 + dataSize;

    final b = BytesBuilder()
      ..add(ascii.encode('RIFF'))
      ..add(_u32(fileSize - 8))
      ..add(ascii.encode('WAVE'))
      ..add(ascii.encode('fmt '))
      ..add(_u32(16))
      ..add(_u16(1))
      ..add(_u16(numChannels))
      ..add(_u32(sampleRate))
      ..add(_u32(byteRate))
      ..add(_u16(blockAlign))
      ..add(_u16(bitsPerSample))
      ..add(ascii.encode('data'))
      ..add(_u32(dataSize));
    
    // Add 16-bit samples as bytes (little-endian)
    for (final sample in samples) {
      b.add(_u16(sample & 0xFFFF));
    }

    return Uint8List.fromList(b.toBytes());
  }

  List<int> _u16(int v) => [v & 0xFF, v >> 8 & 0xFF];
  List<int> _u32(int v) => [
    v & 0xFF,
    v >> 8 & 0xFF,
    v >> 16 & 0xFF,
    v >> 24 & 0xFF,
  ];
}

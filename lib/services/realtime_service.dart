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
  
  // Buffer for accumulating small streaming chunks
  final List<int> _audioBuffer = [];
  static const int _minChunkSize = 48000; // ~1 second at 24kHz 16-bit
  bool _transmitting = false;

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
      instructions: 'You are a helpful assistant. Always respond in English only.',
    );
    _client.on(RealtimeEventType.error, (evt) {
      debugPrint('❌ Realtime API error: ${(evt as RealtimeEventError).error}');
    });
    _client.on(RealtimeEventType.conversationUpdated, (evt) {
      final event = (evt as RealtimeEventConversationUpdated);
      final transcript = event.result.delta?.transcript;
      final audioData = event.result.delta?.audio;
      
      debugPrint('🗣 partial transcript: "${transcript ?? ''}"');
      
      // Accumulate small audio chunks before sending
      if (audioData != null && audioData.isNotEmpty) {
        final pcmBytes = audioData.cast<int>();
        _audioBuffer.addAll(pcmBytes);
        debugPrint('📥 accumulated ${pcmBytes.length} bytes (total: ${_audioBuffer.length})');
        
        // Send chunk when we have enough data (1+ seconds)
        if (_audioBuffer.length >= _minChunkSize) {
          _flushAudioBuffer();
        }
      }
    });

    _client.on(RealtimeEventType.conversationItemCompleted, (evt) {
      final wrapper = (evt as RealtimeEventConversationItemCompleted).item;
      final msg        = wrapper.item as ItemMessage;
      final transcript = wrapper.formatted?.transcript ?? '';
      debugPrint('✅ completed response: "$transcript"');
      
      // Force flush any remaining audio buffer, even if transmitting
      if (_audioBuffer.isNotEmpty) {
        _forceFlushAudioBuffer();
      }
    });

    debugPrint('🌐 connecting RealtimeClient…');
    await _client.connect();
    _connected = true;
    debugPrint('🔗 connected');
  }

  Future<void> sendAudio(Uint8List wavBytes) async {
    if (!_connected) throw StateError('RealtimeService not initialized');
    
    // Clean up any remaining audio from previous response
    await _cleanupPreviousResponse();
    
    final b64 = base64Encode(wavBytes);
    debugPrint('🎵 sendAudio: rawBytes=${wavBytes.length}, b64Chars=${b64.length}');
    await _client.sendUserMessageContent([
      ContentPart.inputAudio(audio: b64),
    ]);
  }

  Future<void> _cleanupPreviousResponse() async {
    // Force flush any remaining audio from previous response
    if (_audioBuffer.isNotEmpty) {
      debugPrint('🧹 cleaning up ${_audioBuffer.length} bytes from previous response');
      await _forceFlushAudioBuffer();
    }
  }

  Future<void> dispose() async {
    debugPrint('🛑 disposing RealtimeService');
    _player.dispose();
    try {
      await _client.disconnect();
    } catch (_) {}
    _connected = false;
  }

  void _flushAudioBuffer() async {
    if (_audioBuffer.isEmpty || _transmitting) return;
    await _doFlushAudioBuffer();
  }

  Future<void> _forceFlushAudioBuffer() async {
    if (_audioBuffer.isEmpty) return;
    
    // Wait for any current transmission to finish, then flush
    while (_transmitting) {
      await Future.delayed(Duration(milliseconds: 50));
    }
    
    // Only flush if we have at least some meaningful audio data
    // Ensure we have an even number of bytes for 16-bit samples
    if (_audioBuffer.length >= 2 && _audioBuffer.length % 2 == 0) {
      await _doFlushAudioBuffer();
    } else {
      debugPrint('🚫 Skipping flush of incomplete audio data: ${_audioBuffer.length} bytes');
      _audioBuffer.clear();
    }
  }

  Future<void> _doFlushAudioBuffer() async {
    _transmitting = true;
    final wav = _buildPcmWav(_audioBuffer);
    debugPrint('🎵 flushing audio buffer: ${wav.length} bytes (${_audioBuffer.length} samples)');
    
    if (onAudio != null) {
      onAudio!(wav);
    } else {
      _player.playBuffer(wav, onFinished: () {
        debugPrint('🔈 TTS buffer playback finished');
      });
    }
    
    _audioBuffer.clear();
    
    // Wait before allowing next transmission to prevent header corruption
    await Future.delayed(Duration(milliseconds: 500));
    _transmitting = false;
  }

  Uint8List _buildPcmWav(List<int> rawBytes) {
    const sampleRate    = 24000, // 24 kHz to match API
          numChannels   = 1,
          bitsPerSample = 16;
    final byteRate   = sampleRate * numChannels * bitsPerSample ~/ 8;
    final blockAlign = numChannels * bitsPerSample ~/ 8;
    
    // Ensure we have valid audio data (even number of bytes for 16-bit samples)
    if (rawBytes.length < 2 || rawBytes.length % 2 != 0) {
      debugPrint('⚠️ Invalid audio data length: ${rawBytes.length} bytes');
      // Pad with a zero byte if odd length
      if (rawBytes.length % 2 != 0) {
        rawBytes.add(0);
      }
    }
    
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
    
    debugPrint('🎵 Built WAV: ${rawBytes.length} bytes → ${samples.length} samples');
    
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

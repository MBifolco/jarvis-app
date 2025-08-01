// lib/services/realtime_service.dart

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:openai_realtime_dart/openai_realtime_dart.dart';
import 'audio_player_service.dart';
import 'transcript_service.dart';

class RealtimeService {
  final RealtimeClient _client;
  final AudioPlayerService _player;
  final void Function(Uint8List pcm)? onAudio;
  final TranscriptService? transcriptService;
  bool _connected = false;
  
  // Buffer for accumulating small streaming chunks
  final List<int> _audioBuffer = [];
  static const int _minChunkSize = 48000; // ~1 second at 24kHz 16-bit - smaller for faster transmission
  static const int _minFinalChunkSize = 2400; // 0.1 second minimum for final chunks
  bool _transmitting = false;
  int _chunkCounter = 0;
  bool _responseInProgress = false;
  bool _forceFlushing = false;  // Track if we're in force flush mode
  Timer? _responseTimeoutTimer;

  RealtimeService(
    String apiKey, {
    this.onAudio,
    this.transcriptService,
  }) : 
    _client = RealtimeClient(apiKey: apiKey),
    _player = AudioPlayerService();

  Future<void> init() async {
    debugPrint('🚀 [RealtimeService] init()');
    
    // Reset connection state
    _connected = false;
    _responseInProgress = false;
    _transmitting = false;
    _forceFlushing = false;
    _audioBuffer.clear();
    
    await _player.init();
    await _client.updateSession(
      voice: Voice.shimmer,
      turnDetection: TurnDetection(
        type: TurnDetectionType.serverVad,
        threshold: 0.8,
      ),
      instructions: 'You are a helpful assistant. Always respond in English only.',
    );
    _client.on(RealtimeEventType.error, (evt) {
      final error = (evt as RealtimeEventError).error;
      debugPrint('❌ Realtime API error: $error');
      debugPrint('❌ Error details: ${error.message}');
      if (error.code != null) {
        debugPrint('❌ Error code: ${error.code}');
      }
      
      // Reset state on error
      _responseInProgress = false;
      _transmitting = false;
      _forceFlushing = false;
      
      // Clear any pending audio buffer
      if (_audioBuffer.isNotEmpty) {
        debugPrint('❌ Clearing ${_audioBuffer.length} bytes from buffer due to error');
        _audioBuffer.clear();
      }
    });
    _client.on(RealtimeEventType.conversationUpdated, (evt) {
      final event = (evt as RealtimeEventConversationUpdated);
      final transcript = event.result.delta?.transcript;
      final audioData = event.result.delta?.audio;
      
      debugPrint('🗣 partial transcript: "${transcript ?? ''}"');
      
      // Update transcript with partial response
      if (transcript != null && transcript.isNotEmpty && transcriptService != null) {
        transcriptService!.addPartialAssistantMessage(transcript);
      }
      
      // Accumulate small audio chunks before sending
      if (audioData != null && audioData.isNotEmpty) {
        _responseInProgress = true;  // Mark that we're receiving audio
        
        // Cancel timeout timer since we're receiving a response
        if (_responseTimeoutTimer != null && _responseTimeoutTimer!.isActive) {
          debugPrint('⏰ Cancelling timeout timer - response received');
          _responseTimeoutTimer!.cancel();
        }
        
        final pcmBytes = audioData.cast<int>();
        final beforeSize = _audioBuffer.length;
        _audioBuffer.addAll(pcmBytes);
        final afterSize = _audioBuffer.length;
        final bufferSeconds = afterSize / 48000.0; // 48KB per second
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        debugPrint('📥 accumulated ${pcmBytes.length} bytes: ${beforeSize} → ${afterSize} (${bufferSeconds.toStringAsFixed(1)}s buffered) at $timestamp');
        
        // Send chunk when we have enough data (1+ seconds)
        if (_audioBuffer.length >= _minChunkSize) {
          _flushAudioBuffer();
        }
      }
    });

    _client.on(RealtimeEventType.conversationItemCompleted, (evt) async {
      final wrapper = (evt as RealtimeEventConversationItemCompleted).item;
      final transcript = wrapper.formatted?.transcript ?? '';
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      debugPrint('✅ completed response at $timestamp: "$transcript"');
      debugPrint('✅ Audio buffer at completion: ${_audioBuffer.length} bytes (${(_audioBuffer.length / 48000.0).toStringAsFixed(2)}s)');
      
      // Finalize transcript with completed response
      if (transcript.isNotEmpty && transcriptService != null) {
        transcriptService!.finalizeAssistantMessage(transcript);
      }
      
      // Force flush any remaining audio buffer, even if transmitting
      if (_audioBuffer.isNotEmpty || _responseInProgress) {
        debugPrint('✅ Triggering force flush for completion (responseInProgress=$_responseInProgress)');
        // Add a small delay to ensure all streaming data has been accumulated
        await Future.delayed(Duration(milliseconds: 200));
        
        if (_audioBuffer.isNotEmpty) {
          debugPrint('✅ Force flushing ${_audioBuffer.length} bytes (${(_audioBuffer.length / 48000.0).toStringAsFixed(2)}s)');
          await _forceFlushAudioBuffer();
        }
        
        // Add delay after force flush to ensure device has time to play final chunk
        await Future.delayed(Duration(milliseconds: 500));
        debugPrint('✅ Force flush complete, final chunk should be playing');
      }
      
      _responseInProgress = false;  // Reset for next response
    });

    // Add session created event handler to confirm connection
    _client.on(RealtimeEventType.sessionCreated, (evt) {
      debugPrint('✅ Session created successfully');
      final session = (evt as RealtimeEventSessionCreated).session;
      debugPrint('✅ Session ID: ${session.id}');
      debugPrint('✅ Model: ${session.model}');
      _connected = true;  // Mark as truly connected only after session is created
    });
    
    // Add session updated event handler
    _client.on(RealtimeEventType.sessionUpdated, (evt) {
      debugPrint('🔄 Session updated');
    });
    
    // Monitor for disconnection or connection issues
    _client.on(RealtimeEventType.close, (evt) {
      debugPrint('⚠️ WebSocket connection closed');
      _connected = false;
      // Cancel any pending operations
      _responseTimeoutTimer?.cancel();
      _responseInProgress = false;
      _transmitting = false;
      _forceFlushing = false;
    });
    
    debugPrint('🌐 connecting RealtimeClient…');
    try {
      await _client.connect();
      _connected = true;
      debugPrint('🔗 connected');
    } catch (e) {
      debugPrint('❌ Failed to connect to RealtimeClient: $e');
      _connected = false;
      throw e;
    }
  }

  Future<void> sendAudio(Uint8List wavBytes, {String? userTranscript}) async {
    if (!_connected) {
      debugPrint('⚠️ RealtimeService not connected, attempting to reconnect...');
      try {
        await init();
      } catch (e) {
        debugPrint('❌ Failed to reconnect: $e');
        throw StateError('RealtimeService not initialized and reconnection failed');
      }
    }
    
    debugPrint('🎤 NEW USER REQUEST - buffer before cleanup: ${_audioBuffer.length} bytes');
    
    // Clean up any remaining audio from previous response
    await _cleanupPreviousResponse();
    
    // Add user message to transcript if provided
    if (userTranscript != null && userTranscript.isNotEmpty && transcriptService != null) {
      transcriptService!.addUserMessage(userTranscript);
    }
    
    // Cancel any existing timeout timer
    _responseTimeoutTimer?.cancel();
    
    // Set a timeout for the response (30 seconds - increased from 15)
    _responseTimeoutTimer = Timer(const Duration(seconds: 30), () {
      debugPrint('⏰ Response timeout! No response received within 30 seconds');
      
      // Reset state
      _responseInProgress = false;
      _transmitting = false;
      _forceFlushing = false;
      
      // Clear any pending audio buffer
      if (_audioBuffer.isNotEmpty) {
        debugPrint('⏰ Clearing ${_audioBuffer.length} bytes from buffer due to timeout');
        _audioBuffer.clear();
      }
      
      // Notify transcript service of timeout
      if (transcriptService != null) {
        transcriptService!.addPartialAssistantMessage('[Response timeout - no response received]');
        transcriptService!.finalizeAssistantMessage('[Response timeout - no response received]');
      }
    });
    
    final b64 = base64Encode(wavBytes);
    debugPrint('🎵 sendAudio: rawBytes=${wavBytes.length}, b64Chars=${b64.length}');
    debugPrint('🎵 Connection state: connected=$_connected');
    
    try {
      debugPrint('🎵 Sending audio to OpenAI...');
      await _client.sendUserMessageContent([
        ContentPart.inputAudio(audio: b64),
      ]);
      debugPrint('🎵 Audio sent successfully, waiting for response...');
    } catch (e) {
      debugPrint('❌ Error sending audio to OpenAI: $e');
      debugPrint('❌ Error type: ${e.runtimeType}');
      if (e is Exception) {
        debugPrint('❌ Exception details: ${e.toString()}');
      }
      _responseTimeoutTimer?.cancel();
      rethrow;
    }
  }

  Future<void> _cleanupPreviousResponse() async {
    // Force flush any remaining audio from previous response
    if (_audioBuffer.isNotEmpty) {
      debugPrint('🧹 cleaning up ${_audioBuffer.length} bytes from previous response');
      await _forceFlushAudioBuffer();
      // Extra delay to ensure last chunk plays
      await Future.delayed(Duration(milliseconds: 500));
    }
    
    // Reset state for new response
    _responseInProgress = false;
    _forceFlushing = false;
    _chunkCounter = 0;
    debugPrint('🧹 cleanup complete, ready for new response');
  }

  Future<void> dispose() async {
    debugPrint('🛑 disposing RealtimeService');
    
    // Cancel any active timers
    _responseTimeoutTimer?.cancel();
    
    // Reset all state
    _responseInProgress = false;
    _transmitting = false;
    _forceFlushing = false;
    _connected = false;
    
    // Clear any pending audio buffer
    if (_audioBuffer.isNotEmpty) {
      debugPrint('🛑 Clearing ${_audioBuffer.length} bytes from buffer on dispose');
      _audioBuffer.clear();
    }
    
    _player.dispose();
    
    try {
      await _client.disconnect();
      debugPrint('🛑 RealtimeClient disconnected');
    } catch (e) {
      debugPrint('❌ Error disconnecting RealtimeClient: $e');
    }
  }

  void _flushAudioBuffer() async {
    if (_audioBuffer.isEmpty) return;
    
    if (_transmitting) {
      debugPrint('⏳ Flush blocked - already transmitting (buffer: ${_audioBuffer.length} bytes = ${(_audioBuffer.length / 48000.0).toStringAsFixed(1)}s)');
      return;
    }
    
    await _doFlushAudioBuffer();
  }

  Future<void> _forceFlushAudioBuffer() async {
    if (_audioBuffer.isEmpty) return;
    
    debugPrint('🔥 FORCE FLUSH CALLED: ${_audioBuffer.length} bytes (${(_audioBuffer.length / 48000.0).toStringAsFixed(2)}s) buffered');
    
    _forceFlushing = true;  // Enter force flush mode
    
    // Wait for any current transmission to finish, then flush
    int waitCount = 0;
    while (_transmitting) {
      await Future.delayed(Duration(milliseconds: 50));
      waitCount++;
      if (waitCount % 10 == 0) {
        debugPrint('🔥 Still waiting for transmission to finish... (${waitCount * 50}ms)');
      }
    }
    
    // Force flush ALL remaining data in chunks
    while (_audioBuffer.isNotEmpty) {
      // Only flush if we have at least some meaningful audio data
      // Ensure we have an even number of bytes for 16-bit samples
      if (_audioBuffer.length >= 2 && _audioBuffer.length % 2 == 0) {
        debugPrint('🔥 FORCE FLUSHING ${_audioBuffer.length} bytes');
        await _doFlushAudioBuffer();
        // Small delay between chunks during force flush
        await Future.delayed(Duration(milliseconds: 50));
      } else {
        debugPrint('🚫 Skipping flush of incomplete audio data: ${_audioBuffer.length} bytes');
        _audioBuffer.clear();
        break;
      }
    }
    
    _forceFlushing = false;  // Exit force flush mode
  }

  Future<void> _doFlushAudioBuffer() async {
    _transmitting = true;
    _chunkCounter++;
    
    // Extract exactly _minChunkSize bytes (or all if less)
    final bytesToSend = _audioBuffer.length >= _minChunkSize ? _minChunkSize : _audioBuffer.length;
    final pcmData = Uint8List.fromList(_audioBuffer.take(bytesToSend).toList());
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final isFinalChunk = bytesToSend < _minChunkSize;  // This is a partial final chunk
    
    final bufferSeconds = _audioBuffer.length / 48000.0;
    final chunkSeconds = pcmData.length / 48000.0;
    debugPrint('🎵 CHUNK $_chunkCounter: START sending ${isFinalChunk ? "FINAL" : ""} at timestamp $timestamp: ${pcmData.length} bytes (${chunkSeconds.toStringAsFixed(1)}s) from buffer of ${_audioBuffer.length} bytes (${bufferSeconds.toStringAsFixed(1)}s)');
    debugPrint('🎵 CHUNK $_chunkCounter: PCM first 8 bytes: ${pcmData.take(8).map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(', ')}');
    debugPrint('🎵 CHUNK $_chunkCounter: PCM last 8 bytes: ${pcmData.skip(pcmData.length - 8).map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(', ')}');
    
    if (onAudio != null) {
      onAudio!(pcmData);
      // Note: onAudio is synchronous but it triggers async BLE operations
      // Add a small delay to ensure BLE transmission completes
      await Future.delayed(Duration(milliseconds: 100));
      final endTimestamp = DateTime.now().millisecondsSinceEpoch;
      debugPrint('🎵 CHUNK $_chunkCounter: FINISHED sending at timestamp $endTimestamp (took ${endTimestamp - timestamp}ms)');
    } else {
      // For phone playback, we still need WAV format
      final wav = _buildPcmWav(pcmData.cast<int>().toList());
      _player.playBuffer(wav, onFinished: () {
        debugPrint('🔈 TTS buffer playback finished');
      });
    }
    
    // Remove only the bytes we sent
    _audioBuffer.removeRange(0, bytesToSend);
    
    // Add delay to ensure device finishes processing before next chunk
    // This prevents header corruption from concurrent packets
    // With 48KB chunks (1 second of audio), transmission is faster (~300ms)
    // Device needs ~85ms to process, so 400ms total should be safe
    debugPrint('🎵 CHUNK $_chunkCounter: Starting 400ms delay before next chunk...');
    await Future.delayed(Duration(milliseconds: 400));
    
    final readyTimestamp = DateTime.now().millisecondsSinceEpoch;
    debugPrint('🎵 CHUNK $_chunkCounter: READY for next chunk at timestamp $readyTimestamp');
    _transmitting = false;
    
    // Check if we need to send more chunks
    if (_forceFlushing && _audioBuffer.length > 0) {
      // During force flush, send ANY remaining data
      final remainingSeconds = _audioBuffer.length / 48000.0;
      debugPrint('🔥 Force flush mode - will send remaining ${_audioBuffer.length} bytes (${remainingSeconds.toStringAsFixed(1)}s)');
      // Don't schedule, the force flush loop will handle it
    } else if (_audioBuffer.length >= _minChunkSize) {
      final remainingSeconds = _audioBuffer.length / 48000.0;
      debugPrint('🎵 Buffer still has ${_audioBuffer.length} bytes (${remainingSeconds.toStringAsFixed(1)}s) - scheduling next chunk');
      // Schedule next chunk with a small delay to avoid BLE corruption
      Future.delayed(Duration(milliseconds: 50), () {
        if (_audioBuffer.length >= _minChunkSize && !_transmitting) {
          _flushAudioBuffer();
        }
      });
    } else if (_audioBuffer.length > 0) {
      final remainingSeconds = _audioBuffer.length / 48000.0;
      debugPrint('🎵 Buffer has ${_audioBuffer.length} bytes (${remainingSeconds.toStringAsFixed(1)}s) remaining - waiting for more data');
    }
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

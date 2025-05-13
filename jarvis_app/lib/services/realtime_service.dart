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

    // Configure TTS voice, VAD, and Whisper in one call
    await _client.updateSession(instructions: 'You are a great, upbeat friend.');
    await _client.updateSession(voice: Voice.alloy);
    await _client.updateSession(
      turnDetection: TurnDetection(
        type: TurnDetectionType.serverVad,
      ),
      inputAudioTranscription: InputAudioTranscriptionConfig(
        model: 'gpt-4o-mini-realtime-preview',
      ),
    );

    // Partial transcripts (no audio here)
    _client.on(RealtimeEventType.conversationUpdated, (evt) {
      final ev = evt as RealtimeEventConversationUpdated;
      final t = ev.result.delta?.transcript;
      final items = _client.conversation.getItems();
      // print out entire message
      //print all items
      for (final item in items) {
        debugPrint('   • item: ${item.toString()}');
      }
      debugPrint(ev.result.toString());
      debugPrint('🗣 conversationUpdated: transcript="${t ?? ''}"');
    });

    // Final assistant messages (with audio)
    _client.on(RealtimeEventType.conversationItemCompleted, (evt) {
      final ev = evt as RealtimeEventConversationItemCompleted;
      final raw = ev.item.item;

      if (raw is ItemMessage) {
        // Now we can get raw.id safely
        debugPrint(
          '✅ completed id=${raw.id} role=${raw.role.name}'
        );
        // print out all data
        debugPrint('   • content: ${raw.content}');
        for (final part in raw.content) {
          if (part is ContentPartText) {
            debugPrint('   • text : "${part.text}"');
          } else if (part is ContentPartAudio) {
            final hasAudio = part.audio != null;
            debugPrint(
              '   • audio: transcript="${part.transcript}", hasAudio=$hasAudio'
            );
            if (hasAudio) {
              try {
                final bytes = base64Decode(part.audio!);
                debugPrint('     → playing ${bytes.length} bytes');
                _player.playBuffer(Uint8List.fromList(bytes));
              } catch (e) {
                debugPrint('     ❌ playback error: $e');
              }
            }
          } else {
            debugPrint('   • other: $part');
          }
        }
      } else {
        debugPrint('✅ completed non-ItemMessage: $raw');
      }
    });

    // Errors
    _client.on(RealtimeEventType.error, (evt) {
      final err = (evt as RealtimeEventError).error;
      debugPrint('❌ realtime error: $err');
    });

    // Connect
    debugPrint('🌐 connecting RealtimeClient…');
    await _client.connect();
    _connected = true;
    debugPrint('🔗 connected');

    await _client.sendUserMessageContent([
    const ContentPart.inputText(text: 'How are you?'),
  ]);
    debugPrint('🔗 sent initial message') ;
  }

  /// Send your full PCM-WAV buffer (Base64) to the Realtime API
  Future<void> sendAudio(Uint8List wavBytes) async {
    if (!_connected) throw StateError('RealtimeService not initialized');
    final b64 = base64Encode(wavBytes);
    debugPrint(
      '🎵 sendAudio: rawBytes=${wavBytes.length}, base64Chars=${b64.length}'
    );
    await _client.sendUserMessageContent([
      ContentPart.inputAudio(audio: b64),
    ]);
  }

  /// Disconnect & clean up
  Future<void> dispose() async {
    debugPrint('🛑 disposing RealtimeService');
    _player.dispose();
    try {
      await _client.disconnect();
    } catch (e) {
      debugPrint('⚠️ disconnect error: $e');
    }
    _connected = false;
  }
}

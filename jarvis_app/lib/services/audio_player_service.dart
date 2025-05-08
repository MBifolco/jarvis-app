// lib/services/audio_player_service.dart

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_sound/flutter_sound.dart';
import 'package:flutter_tts/flutter_tts.dart';

class AudioPlayerService {
  final FlutterSoundPlayer _player = FlutterSoundPlayer();
  final FlutterTts _tts = FlutterTts();

  /// Call once at app startup.
  Future<void> init() async {
    await _player.openPlayer();
  }

  /// Release resources.
  Future<void> dispose() async {
    if (_player.isPlaying) {
      await _player.stopPlayer();
    }
    await _player.closePlayer();
    await _tts.stop();
  }

  /// Play an in-memory WAV buffer in one shot and wait until it's done.
  Future<void> playBuffer(Uint8List wavData) async {
    // Stop any existing playback
    if (_player.isPlaying) {
      await _player.stopPlayer();
    }

    // We'll complete this when playback finishes.
    final completer = Completer<void>();

    // Start playback from buffer
    await _player.startPlayer(
      fromDataBuffer: wavData,
      codec: Codec.pcm16WAV,  // WAV container with 16-bit PCM
      numChannels: 1,
      sampleRate: 16000,
      whenFinished: () {
        completer.complete();
      },
    );

    // Wait for the callback
    await completer.future;
  }

  /// Speak a text reply via the platform TTS engine.
  Future<void> speak(String text) async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.speak(text);
    // If you need to wait until speaking is done:
    // await _tts.awaitSpeakCompletion(true);
  }
}

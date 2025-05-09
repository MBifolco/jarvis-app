// lib/services/audio_player_service.dart

import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:flutter_tts/flutter_tts.dart';

class AudioPlayerService {
  final FlutterTts _tts = FlutterTts();
  late final FlutterSoundPlayer _player;

  /// Initialize both the WAV player and the TTS engine.
  Future<void> init() async {
    _player = FlutterSoundPlayer();
    await _player.openPlayer();
    // (optional) tweak TTS defaults here:
    await _tts.setVolume(1.0);
    await _tts.setSpeechRate(0.5);
  }

  /// List available TTS voices, each as e.g. "en-US-JennyNeural (en-US)".
  Future<List<String>> getAvailableVoices() async {
    final voices = await _tts.getVoices; // List<Map<String,dynamic>>
    return voices
        .map((v) => "${v['name']} (${v['locale']})")
        .cast<String>()
        .toList();
  }

  /// Pick one of the above by its label.
  Future<void> setVoice(String voiceLabel) async {
    final name = voiceLabel.split(' ').first;
    final locale = voiceLabel.substring(
      voiceLabel.indexOf('(') + 1,
      voiceLabel.indexOf(')'),
    );
    await _tts.setVoice({'name': name, 'locale': locale});
  }

  /// Play a full WAV‐buffer in one shot.
  ///
  /// As soon as playback finishes, [onFinished] is invoked (if provided),
  /// so you can chain Whisper→Chat→TTS automatically.
  Future<void> playBuffer(
    Uint8List wav, {
    VoidCallback? onFinished,
  }) async {
    // stop any in-flight playback
    if (!_player.isStopped) {
      await _player.stopPlayer();
    }

    await _player.startPlayer(
      fromDataBuffer: wav,
      codec: Codec.pcm16WAV,
      whenFinished: onFinished,
    );
  }

  /// Speak arbitrary text via the selected TTS voice.
  Future<void> speak(String text) async {
    await _tts.speak(text);
  }

  /// Clean up both engines.
  void dispose() {
    try {
      _tts.stop();
    } catch (_) {}
    try {
      _player.closePlayer();
    } catch (_) {}
  }
}

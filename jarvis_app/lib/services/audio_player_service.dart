import 'dart:typed_data';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:flutter_tts/flutter_tts.dart';

class AudioPlayerService {
  late final FlutterSoundPlayer _player;
  late final FlutterTts _tts;

  Future<void> init() async {
    _player = FlutterSoundPlayer();
    await _player.openPlayer();
    _tts = FlutterTts();
  }

  /// Play the entire WAV buffer at once
  Future<void> playBuffer(Uint8List wav) async {
    await _player.startPlayer(
      fromDataBuffer: wav,
      codec: Codec.pcm16WAV,
      whenFinished: () {},
    );
  }

  /// Speak text using platform TTS
  Future<void> speak(String text) async {
    await _tts.speak(text);
  }

  void dispose() {
    _player.closePlayer();
    _tts.stop();
  }
}

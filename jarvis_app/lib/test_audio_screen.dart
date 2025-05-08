// lib/test_audio_screen.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:path_provider/path_provider.dart';

class TestAudioScreen extends StatefulWidget {
  const TestAudioScreen({Key? key}) : super(key: key);

  @override
  State<TestAudioScreen> createState() => _TestAudioScreenState();
}

class _TestAudioScreenState extends State<TestAudioScreen> {
  late final FlutterSoundPlayer _player;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _player = FlutterSoundPlayer();
    _openPlayer();
  }

  Future<void> _openPlayer() async {
    await _player.openPlayer();
  }

  @override
  void dispose() {
    _player.closePlayer();
    super.dispose();
  }

  Future<void> _playAsset() async {
    setState(() => _isPlaying = true);

    // 1) load asset bytes
    final data = await rootBundle.load('assets/test.mp3');
    final bytes = data.buffer.asUint8List();

    // 2) write to tmp file
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/test.mp3');
    await file.writeAsBytes(bytes, flush: true);

    // 3) play it
    await _player.startPlayer(
      fromURI: file.path,
      codec: Codec.mp3,
      whenFinished: () {
        setState(() => _isPlaying = false);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('🔊 Test Audio')),
      body: Center(
        child: ElevatedButton(
          onPressed: _isPlaying ? null : _playAsset,
          child: Text(_isPlaying ? 'Playing…' : 'Play test.mp3'),
        ),
      ),
    );
  }
}

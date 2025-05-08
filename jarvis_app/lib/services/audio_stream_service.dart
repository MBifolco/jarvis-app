import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../constants.dart'; // ← your UUIDs

class AudioStreamService {
  final BluetoothDevice _device;
  final List<int> audioBuffer = [];
  final _audioController = StreamController<Uint8List>.broadcast();
  final _wakeController  = StreamController<String>.broadcast();

  Stream<Uint8List> get audioStream => _audioController.stream;
  Stream<String>    get wakeStream  => _wakeController.stream;

  StreamSubscription<List<int>>? _audioSub;
  StreamSubscription<List<int>>? _wakeSub;

  AudioStreamService(this._device);

  Future<void> init() async {
    // connect & discover
    await _device.connect(autoConnect: false).catchError((_) {});
    final services = await _device.discoverServices();

    for (final svc in services) {
      for (final chr in svc.characteristics) {
        if (!chr.properties.notify) continue;
        await chr.setNotifyValue(true);
        final uuid = chr.uuid.toString().toLowerCase();

        if (uuid == audioCharUuid) {
          _audioSub = chr.lastValueStream.listen((bytes) {
            // buffer & re-emit as Uint8List
            audioBuffer.addAll(bytes);
            _audioController.add(Uint8List.fromList(bytes));
          });
        } else if (uuid == wakeCharUuid) {
          _wakeSub = chr.lastValueStream.listen((bytes) {
            final msg = utf8.decode(bytes);
            _wakeController.add(msg);
          });
        }
      }
    }
  }

  void dispose() {
    _audioSub?.cancel();
    _wakeSub?.cancel();
    _audioController.close();
    _wakeController.close();
    _device.disconnect();
  }
}

// lib/services/audio_stream_service.dart

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Your 128-bit UUID for the audio-WAV characteristic:
const String audioCharUuid = '99887766-5544-3322-1100-ffeeddccbbaa';

/// Buffers precisely one WAV file from the device:
///  • fires `onData` for every chunk (so your UI can update progress)
///  • fires `onDone` once the full file is in.
///  • stays subscribed so when you `reset()` it will pick up the next file.
class AudioStreamService {
  final BluetoothDevice device;

  /// Called on every incoming chunk (for UI progress).
  final VoidCallback? onData;

  /// Called once, the moment we have the full WAV buffer.
  final VoidCallback? onDone;

  StreamSubscription<List<int>>? _sub;
  final List<int> audioBuffer = [];
  int? expectedLength;

  AudioStreamService(this.device, {this.onData, this.onDone});

  Future<void> init() async {
    // 1) connect (ignore if already)
    try {
      await device.connect(autoConnect: false);
    } catch (_) {}

    // 2) discover & hook up
    final svcs = await device.discoverServices();
    for (var svc in svcs) {
      for (var chr in svc.characteristics) {
        if (chr.uuid.toString().toLowerCase() == audioCharUuid
            && (chr.properties.notify || chr.properties.indicate)) {
          await chr.setNotifyValue(true);
          _sub = chr.lastValueStream.listen(_handleChunk);
          return;
        }
      }
    }
    throw Exception('Audio characteristic $audioCharUuid not found');
  }

  void _handleChunk(List<int> bytes) {
    audioBuffer.addAll(bytes);
    // parse header once we have 44 bytes
    if (expectedLength == null && audioBuffer.length >= 44) {
      final header = Uint8List.fromList(audioBuffer.sublist(40, 44));
      expectedLength =
          44 + ByteData.sublistView(header).getUint32(0, Endian.little);
    }
    onData?.call();

    // once full file arrived…
    if (expectedLength != null && audioBuffer.length >= expectedLength!) {
      onDone?.call();
    }
  }

  /// Clear out the old WAV so the *next* one starts fresh.
  void reset() {
    audioBuffer.clear();
    expectedLength = null;
    onData?.call();
  }

  void dispose() {
    _sub?.cancel();
    try {
      device.disconnect();
    } catch (_) {}
  }
}

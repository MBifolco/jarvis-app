// lib/services/audio_stream_service.dart

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Your 128-bit UUID for the audio WAV characteristic:
const String audioCharUuid = '99887766-5544-3322-1100-ffeeddccbbaa';

/// Buffers a full WAV file from the device, firing [onData] on every chunk.
class AudioStreamService {
  final BluetoothDevice device;

  /// Called on each chunk so the UI can rebuild and show progress.
  final VoidCallback? onData;

  StreamSubscription<List<int>>? _audioSub;

  /// Accumulates header + data bytes.
  final List<int> audioBuffer = [];

  /// 44 + data-chunk-size (once parsed).
  int? expectedLength;

  AudioStreamService(this.device, {this.onData});

  Future<void> init() async {
    // 1) Connect (ignore if already connected).
    try {
      await device.connect(autoConnect: false);
    } catch (_) {}

    // 2) Discover & subscribe.
    final svcs = await device.discoverServices();
    bool found = false;

    for (var svc in svcs) {
      for (var chr in svc.characteristics) {
        final u = chr.uuid.toString().toLowerCase();
        if (u == audioCharUuid &&
            (chr.properties.notify || chr.properties.indicate)) {
          // enable notifications/indications
          await chr.setNotifyValue(true);
          audioBuffer.clear();
          expectedLength = null;

          // listen on the new, non-deprecated stream:
          _audioSub = chr.lastValueStream.listen((data) {
            _handleChunk(Uint8List.fromList(data));
          });
          found = true;
          break;
        }
      }
      if (found) break;
    }

    if (!found) {
      throw Exception('Audio characteristic $audioCharUuid not found');
    }
  }

  void _handleChunk(Uint8List chunk) {
    audioBuffer.addAll(chunk);

    // parse WAV header once we have 44 bytes
    if (expectedLength == null && audioBuffer.length >= 44) {
      final header = Uint8List.fromList(audioBuffer.sublist(40, 44));
      expectedLength = 44 +
          ByteData.sublistView(header).getUint32(0, Endian.little);
    }

    // notify UI of progress
    onData?.call();

    // if full file received, stop listening
    if (expectedLength != null && audioBuffer.length >= expectedLength!) {
      _audioSub?.cancel();
      _audioSub = null;
    }
  }

  void dispose() {
    _audioSub?.cancel();
    try {
      device.disconnect();
    } catch (_) {}
  }
}

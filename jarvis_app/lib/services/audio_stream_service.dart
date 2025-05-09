// lib/services/audio_stream_service.dart

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:blev/ble.dart';           // exports Peripheral & L2CapChannel
import 'package:blev/ble_central.dart';  // exports BleCentral

/// L2CAP PSM for the Jarvis device’s audio WAV stream.
const int audioPSM = 0x0040;

/// Buffers a full WAV file over an L2CAP channel (PSM 0x0040), firing
/// [onData] on every chunk for UI updates, and [onDone] when complete.
class AudioStreamService {
  /// The BLE central (created via `await BleCentral.create()`).
  final BleCentral ble;

  /// The peripheral identifier, e.g. the `.id.id` you got from `scanForPeripherals`.
  final String peripheralId;

  /// Called on each incoming chunk so the UI can rebuild.
  final VoidCallback? onData;

  /// Called once the full WAV file has been received.
  final VoidCallback? onDone;

  Peripheral?       _peripheral;
  L2CapChannel?     _channel;
  StreamSubscription<Uint8List>? _sub;

  /// Raw bytes of header + data.
  final List<int> audioBuffer = [];

  /// 44 bytes WAV header + data length (parsed once we have ≥44 bytes).
  int? expectedLength;

  AudioStreamService({
    required this.ble,
    required this.peripheralId,
    this.onData,
    this.onDone,
  });

  /// Connects, opens the L2CAP channel, and starts listening.
  Future<void> init() async {
    // 1) connect to the peripheral
    _peripheral = await ble.connectToPeripheral(peripheralId);

    // 2) open the L2CAP channel
    _channel = await _peripheral!.openL2CapChannel(psm: audioPSM);

    // reset buffer state
    audioBuffer.clear();
    expectedLength = null;

    // 3) subscribe to incoming data
    _sub = _channel!.stream.listen(_handleChunk);
  }

  void _handleChunk(Uint8List chunk) {
    audioBuffer.addAll(chunk);

    // parse WAV header once we have at least 44 bytes
    if (expectedLength == null && audioBuffer.length >= 44) {
      final headerBytes = Uint8List.sublistView(
        Uint8List.fromList(audioBuffer),
        40,
        44,
      );
      final dataSize = ByteData.sublistView(headerBytes)
          .getUint32(0, Endian.little);
      expectedLength = 44 + dataSize;
    }

    onData?.call();

    // if full file received, cancel and fire onDone
    if (expectedLength != null &&
        audioBuffer.length >= expectedLength!) {
      _sub?.cancel();
      _sub = null;
      onDone?.call();
    }
  }

  /// Clears the buffer and re-subscribes for the next incoming WAV.
  void reset() {
    audioBuffer.clear();
    expectedLength = null;
    if (_sub == null && _channel != null) {
      _sub = _channel!.stream.listen(_handleChunk);
    }
  }

  /// Cleans up connections.
  Future<void> dispose() async {
    await _sub?.cancel();
    await _channel?.close();
    await _peripheral?.disconnect();
  }
}

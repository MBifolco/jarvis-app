import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

const String audioCharUuid = '99887766-5544-3322-1100-ffeeddccbbaa';

class AudioStreamService {
  final BluetoothDevice device;
  final VoidCallback? onData;
  final VoidCallback? onDone;

  StreamSubscription<List<int>>? _sub;
  final List<int> audioBuffer = [];
  int? expectedLength;
  Uint8List? decodedPcmWav;

  AudioStreamService(this.device, {this.onData, this.onDone});

  Future<void> init() async {
    try {
      await device.connect(autoConnect: false);
    } catch (_) {}

    await device.requestMtu(500);
    final mtu = await device.mtu.first;
    debugPrint("📏 MTU negotiated: $mtu");

    final svcs = await device.discoverServices();
    for (var svc in svcs) {
      for (var chr in svc.characteristics) {
        if (chr.uuid.toString().toLowerCase() == audioCharUuid &&
            (chr.properties.notify || chr.properties.indicate)) {
          await chr.setNotifyValue(true);
          _sub = chr.value.listen(_handleChunk);
          return;
        }
      }
    }
    throw Exception('Audio characteristic $audioCharUuid not found');
  }

  void _handleChunk(List<int> bytes) {
    debugPrint("Audio buffer length: ${bytes.length}");
    audioBuffer.addAll(bytes);
    // Parse WAV header length once
    if (expectedLength == null && audioBuffer.length >= 46) {
      final header = Uint8List.fromList(audioBuffer.sublist(42, 46));
      expectedLength =
          46 + ByteData.sublistView(header).getUint32(0, Endian.little);
      debugPrint("📦 Expected total length: $expectedLength bytes");
    }

    onData?.call();

    // Process once full buffer received
    if (expectedLength != null && audioBuffer.length >= expectedLength!) {
      debugPrint(
          "🎵 Processing complete audio buffer (${audioBuffer.length} bytes)");
      final adpcmBody =
          Uint8List.fromList(audioBuffer.sublist(46, expectedLength));
      debugPrint("🎵 ADPCM body length: ${adpcmBody.length} bytes");

      final pcm = decodeAdpcmToPcm(adpcmBody);
      debugPrint("🎵 Decoded to ${pcm.length} PCM samples");

      decodedPcmWav = _buildPcmWav(pcm);
      debugPrint("🎵 Built WAV file: ${decodedPcmWav!.length} bytes");

      onDone?.call();

      // Automatically reset buffer state for next message
      reset();
    }
  }

  /// Whisper-ready WAV buffer
  Uint8List getPcmWav() {
    if (decodedPcmWav == null) {
      throw Exception("No audio decoded");
    }
    return decodedPcmWav!;
  }

  /// Reset stream state
  void reset() {
    audioBuffer.clear();
    expectedLength = null;
    decodedPcmWav = null;
    onData?.call();
  }

  void dispose() {
    _sub?.cancel();
    try {
      device.disconnect();
    } catch (_) {}
  }

  /// Decodes IMA ADPCM → PCM 16-bit samples
  List<int> decodeAdpcmToPcm(Uint8List input) {
    const blockAlign = 256;
    final samples = <int>[];
    int offset = 0;
    while (offset + blockAlign <= input.length) {
      final block = input.sublist(offset, offset + blockAlign);
      final predictor = ByteData.sublistView(block).getInt16(0, Endian.little);
      int index = block[2] & 0x7F;
      int step = _stepTable[index];
      int val = predictor;
      samples.add(val);
      int byteIndex = 4;

      for (int i = 0; i < (blockAlign - 4) * 2; i++) {
        int nibble;
        if (i.isEven) {
          nibble = block[byteIndex] & 0x0F;
        } else {
          nibble = block[byteIndex++] >> 4;
        }
        int diff = step >> 3;
        if ((nibble & 1) != 0) diff += step >> 2;
        if ((nibble & 2) != 0) diff += step >> 1;
        if ((nibble & 4) != 0) diff += step;
        if ((nibble & 8) != 0) diff = -diff;
        val = (val + diff).clamp(-32768, 32767);
        samples.add(val);
        index = (index + _indexTable[nibble & 0x0F]).clamp(0, 88);
        step = _stepTable[index];
      }
      offset += blockAlign;
    }
    return samples;
  }

  /// Build 16-bit PCM WAV from samples
  Uint8List _buildPcmWav(List<int> samples) {
    const sampleRate = 16000;
    const numChannels = 1;
    const bitsPerSample = 16;
    final byteRate = sampleRate * numChannels * bitsPerSample ~/ 8;
    final blockAlign = numChannels * bitsPerSample ~/ 8;
    final dataSize = samples.length * 2;
    final fileSize = 44 + dataSize;

    final header = BytesBuilder()
      ..add(utf8.encode('RIFF'))
      ..add(_uint32le(fileSize - 8))
      ..add(utf8.encode('WAVE'))
      ..add(utf8.encode('fmt '))
      ..add(_uint32le(16))
      ..add(_uint16le(1))
      ..add(_uint16le(numChannels))
      ..add(_uint32le(sampleRate))
      ..add(_uint32le(byteRate))
      ..add(_uint16le(blockAlign))
      ..add(_uint16le(bitsPerSample))
      ..add(utf8.encode('data'))
      ..add(_uint32le(dataSize));

    final audioBytes = BytesBuilder();
    for (final s in samples) {
      audioBytes.add(_int16le(s));
    }

    return Uint8List.fromList([
      ...header.toBytes(),
      ...audioBytes.toBytes(),
    ]);
  }

  List<int> _uint16le(int v) => [v & 0xFF, (v >> 8) & 0xFF];
  List<int> _uint32le(int v) => [
        v & 0xFF,
        (v >> 8) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 24) & 0xFF,
      ];
  List<int> _int16le(int v) => _uint16le(v & 0xFFFF);

  static const List<int> _stepTable = [
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
    34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143,
    157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544,
    598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
    2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845,
    8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
  ];

  static const List<int> _indexTable = [
    -1, -1, -1, -1, 2, 4, 6, 8,
    -1, -1, -1, -1, 2, 4, 6, 8
  ];
}

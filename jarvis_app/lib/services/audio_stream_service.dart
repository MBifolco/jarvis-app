// lib/services/audio_stream_service.dart

import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:opus_dart/opus_dart.dart';  // initOpus & SimpleOpusDecoder

/// UUID for the characteristic streaming Opus from device → phone
const String audioNotifyUuid = '99887766-5544-3322-1100-ffeeddccbbaa';
/// UUID for the characteristic to write TTS from phone → device
const String audioWriteUuid  = 'ab907856-3412-de90-ab4f-12cd8b6a5f4e';

class AudioStreamService {
  final BluetoothDevice device;
  final bool useOpus;
  final VoidCallback? onData;
  final VoidCallback? onDone;

  StreamSubscription<List<int>>? _audioSub;
  BluetoothCharacteristic?   _writeChr;
  late final SimpleOpusDecoder _opusDecoder;

  static bool _opusInitialized = false;

  final List<int> audioBuffer = [];
  int? expectedLength;
  Uint8List? decodedPcmWav;

  AudioStreamService(
    this.device, {
    this.useOpus = false,
    this.onData,
    this.onDone,
  });

  /// Initialize BLE and Opus (if enabled)
  Future<void> init() async {
    if (useOpus) {
      final dylib = await opus_flutter.load();
      if (!AudioStreamService._opusInitialized) {
        initOpus(dylib);
        AudioStreamService._opusInitialized = true;
      }
      _opusDecoder = SimpleOpusDecoder.new(
        sampleRate: 16000,
        channels: 1,
      );
      debugPrint('🎛️ Opus decoder initialized');
    }

    try {
      await device.connect(autoConnect: false);
    } catch (_) {}
    await device.requestMtu(500);
    final mtu = await device.mtu.first;
    debugPrint('📏 MTU negotiated: $mtu');

    final services = await device.discoverServices();
    for (var svc in services) {
      for (var chr in svc.characteristics) {
        final id = chr.uuid.toString().toLowerCase();
        if (id == audioNotifyUuid &&
            (chr.properties.notify || chr.properties.indicate)) {
          await chr.setNotifyValue(true);
          _audioSub = chr.lastValueStream.listen(_handleChunk);
        }
        if (id == audioWriteUuid &&
            (chr.properties.write || chr.properties.writeWithoutResponse)) {
          _writeChr = chr;
        }
      }
    }

    if (_audioSub == null) {
      throw Exception('Notify characteristic $audioNotifyUuid not found');
    }
    if (_writeChr == null) {
      throw Exception('Write characteristic $audioWriteUuid not found');
    }
  }

  /// Handle each incoming BLE chunk
  void _handleChunk(List<int> bytes) {
    audioBuffer.addAll(bytes);
    onData?.call();

    // --- HEADER PARSE ---
    if (expectedLength == null && audioBuffer.length >= 46) {
      final header = Uint8List.fromList(audioBuffer.sublist(42, 46));
      final payloadLen = ByteData.sublistView(header).getUint32(0, Endian.little);
      expectedLength = 46 + payloadLen;
      debugPrint('🔍 Parsed WAV header: payloadLen=$payloadLen, totalExpected=$expectedLength');
    }

    // --- WAIT FOR FULL PAYLOAD ---
    if (expectedLength != null) {
      debugPrint('📥 Received ${audioBuffer.length} of $expectedLength bytes');
    }

    // --- WHEN FULL PACKET BUFFERED, DECODE ---
    if (expectedLength != null && audioBuffer.length >= expectedLength!) {
      final raw = Uint8List.fromList(audioBuffer.sublist(46, expectedLength!));
      List<int> pcmBytes = [];

      int offset = 0;
      while (offset + 2 <= raw.length) {
        final len = ByteData.sublistView(raw, offset, offset + 2)
            .getUint16(0, Endian.little);
        offset += 2;
        if (offset + len > raw.length) break;
        final frame = raw.sublist(offset, offset + len);
        offset += len;

        if (useOpus) {
          final samples = _opusDecoder.decode(input: frame);
          pcmBytes.addAll(Uint8List.view(samples.buffer));
        } else {
          pcmBytes.addAll(_decodeAdpcm(frame));
        }
      }

      decodedPcmWav = _buildPcmWavFromBytes(pcmBytes);
      onDone?.call();
      reset();
    }
  }

  /// Decodes IMA ADPCM (256-byte blocks, mono, 16-bit PCM)
  List<int> _decodeAdpcm(Uint8List input) {
    const blockAlign = 256;
    final samples = <int>[];
    int offset = 0;
    while (offset + blockAlign <= input.length) {
      final block = input.sublist(offset, offset + blockAlign);
      final predictor = ByteData.sublistView(block).getInt16(0, Endian.little);
      final index = block[2];
      final stepTable = _stepTable;
      final indexTable = _indexTable;

      int step = stepTable[index];
      int val = predictor;
      samples.add(val);

      int idx = index;
      int byteIndex = 4;
      for (int i = 0; i < (blockAlign - 4) * 2; i++) {
        int nibble = (i.isEven) ? (block[byteIndex] & 0x0F)
                                : (block[byteIndex++] >> 4);
        int diff = step >> 3;
        if ((nibble & 1) != 0) diff += step >> 2;
        if ((nibble & 2) != 0) diff += step >> 1;
        if ((nibble & 4) != 0) diff += step;
        if ((nibble & 8) != 0) diff = -diff;
        val = (val + diff).clamp(-32768, 32767);
        samples.add(val);
        idx = (idx + indexTable[nibble]).clamp(0, 88);
        step = stepTable[idx];
      }
      offset += blockAlign;
    }
    return samples;
  }

  /// Send a WAV buffer back to device in MTU-sized chunks
  Future<void> sendWavToDevice(Uint8List wav) async {
    final chr = _writeChr;
    if (chr == null) throw StateError('Write characteristic not ready');
    final mtu = await device.mtu.first;
    final chunkSize = mtu - 3;
    for (var i = 0; i < wav.length; i += chunkSize) {
      final end = (i + chunkSize).clamp(0, wav.length);
      await chr.write(wav.sublist(i, end), withoutResponse: true);
    }
  }

  /// Retrieve the decoded PCM-WAV buffer
  Uint8List getPcmWav() {
    final wav = decodedPcmWav;
    if (wav == null) throw Exception('No audio decoded');
    return wav;
  }

  /// Clear buffers for next packet
  void reset() {
    audioBuffer.clear();
    expectedLength = null;
    decodedPcmWav = null;
    onData?.call();
  }

  void dispose() {
    _audioSub?.cancel();
    try {
      device.disconnect();
    } catch (_) {}
  }

  /// Build 16-bit PCM WAV from samples
  Uint8List _buildPcmWavFromBytes(List<int> samples) {
    const sampleRate    = 16000;
    const numChannels   = 1;
    const bitsPerSample = 16;
    final byteRate      = sampleRate * numChannels * bitsPerSample ~/ 8;
    final blockAlign    = numChannels * bitsPerSample ~/ 8;
    final dataSize      = samples.length * 2;
    final fileSize      = 44 + dataSize;

    final header = BytesBuilder()
      ..add(ascii.encode('RIFF'))
      ..add(_uint32le(fileSize - 8))
      ..add(ascii.encode('WAVE'))
      ..add(ascii.encode('fmt '))
      ..add(_uint32le(16)) // fmt chunk size
      ..add(_uint16le(1))  // PCM format
      ..add(_uint16le(numChannels))
      ..add(_uint32le(sampleRate))
      ..add(_uint32le(byteRate))
      ..add(_uint16le(blockAlign))
      ..add(_uint16le(bitsPerSample))
      ..add(ascii.encode('data'))
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
    598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878,
    2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894,
    6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818,
    18500, 20350, 22385, 24623, 27086, 29794, 32767
  ];

  static const List<int> _indexTable = [
    -1, -1, -1, -1, 2, 4, 6, 8,
    -1, -1, -1, -1, 2, 4, 6, 8
  ];
}

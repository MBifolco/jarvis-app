import 'dart:async';
import 'dart:typed_data';
import 'dart:math';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'bt_connection_service.dart';
import '../models/device_config.dart';

const String audioNotifyUuid = '99887766-5544-3322-1100-ffeeddccbbaa';
const String audioWriteUuid  = 'ab907856-3412-de90-ab4f-12cd8b6a5f4e';

class AudioStreamService implements BlePeripheralService {
  final BluetoothDevice device;
  final VoidCallback? onData;
  final VoidCallback? onDone;

  final List<int> audioBuffer = [];
  StreamSubscription<List<int>>? _sub;
  BluetoothCharacteristic? _writeChr;
  
  Uint8List? decodedPcmWav;
  Uint8List? _outgoingWav;
  int? expectedLength;

  late final BluetoothConnectionService _connSvc;
  final DeviceConfig config;
  AudioStreamService(this.device, {required this.config, this.onData, this.onDone});

  @override
  Future<void> initWithServices(List<BluetoothService> svcs) async {
    for (var svc in svcs) {
      for (var chr in svc.characteristics) {
        final id = chr.uuid.toString().toLowerCase();
        debugPrint("🔌 Characteristic: $id");
        if (id == audioNotifyUuid &&
            (chr.properties.notify || chr.properties.indicate)) {
          await chr.setNotifyValue(true);
          _sub = chr.value.listen(_handleChunk);
        }
        if (id == audioWriteUuid &&
            (chr.properties.write || chr.properties.writeWithoutResponse)) {
          _writeChr = chr;
        }
      }
    }

    if (_sub == null) throw Exception('Audio notify characteristic $audioNotifyUuid not found');
    if (_writeChr == null) throw Exception('Audio write characteristic $audioWriteUuid not found');
  }

  void _handleChunk(List<int> bytes) {
    debugPrint("Audio buffer length: ${bytes.length}");
    audioBuffer.addAll(bytes);
    if (expectedLength == null && audioBuffer.length >= 46) {
      final header = Uint8List.fromList(audioBuffer.sublist(42, 46));
      expectedLength = 46 + ByteData.sublistView(header).getUint32(0, Endian.little);
      debugPrint("📦 Expected total length: $expectedLength bytes");
    }
    onData?.call();

    if (expectedLength != null && audioBuffer.length >= expectedLength!) {
      debugPrint("🎵 Processing complete audio buffer (${audioBuffer.length} bytes)");
      final adpcmBody = Uint8List.fromList(audioBuffer.sublist(46, expectedLength));
      final pcm = decodeAdpcmToPcm(adpcmBody);
      decodedPcmWav = _buildPcmWav(pcm);
      _outgoingWav = decodedPcmWav;
      debugPrint("🎵 Built WAV file: ${decodedPcmWav!.length} bytes");
      _inspectRoundTrip();
      onDone?.call();
      reset();
    }
  }

  void _inspectRoundTrip() {
    final orig = _outgoingWav!;
    final rt = decodedPcmWav!;
    final origBytes = orig.sublist(44);
    final rtBytes = rt.sublist(44);
    final origBd = ByteData.sublistView(origBytes);
    final rtBd = ByteData.sublistView(rtBytes);
    final sampleCount = min(origBytes.length, rtBytes.length) ~/ 2;
    int diffs = 0;
    int maxErr = 0;
    for (var i = 0; i < sampleCount; i++) {
      final o = origBd.getInt16(i * 2, Endian.little);
      final r = rtBd.getInt16(i * 2, Endian.little);
      final e = (r - o).abs();
      if (e != 0) diffs++;
      if (e > maxErr) maxErr = e;
    }
    debugPrint('🔍 Round-trip compare: $sampleCount samples; differences: $diffs; max sample-error: $maxErr');
  }

  Future<void> sendPcmToDevice(Uint8List pcmData) async {
    if (_writeChr == null) throw StateError('Audio write characteristic not initialized');
    final mtu = await device.mtu.first;
    final chunkSize = mtu - 3;

    // Add sync pattern (0xAA 0x55) + 4-byte length header for robustness
    final header = ByteData(6);
    header.setUint8(0, 0xAA);  // Sync byte 1
    header.setUint8(1, 0x55);  // Sync byte 2
    header.setUint32(2, pcmData.length, Endian.little);
    final packet = Uint8List.fromList([...header.buffer.asUint8List(), ...pcmData]);
    
    final startTime = DateTime.now().millisecondsSinceEpoch;
    debugPrint("📤 BLE START: Sending raw PCM audio: ${packet.length} bytes (${pcmData.length} PCM + 6 header)");
    debugPrint("📤 Sync+Header: [0xAA, 0x55] + length=${pcmData.length} bytes");

    int bleChunks = 0;
    for (var offset = 0; offset < packet.length; offset += chunkSize) {
      final end = min(offset + chunkSize, packet.length);
      final chunk = packet.sublist(offset, end);
      
      // Log exactly what we're sending to BLE for first few chunks
      if (offset == 0 || offset == chunkSize) {
        debugPrint("📤 BLE chunk at offset $offset: ${chunk.take(min(12, chunk.length)).map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(', ')}${chunk.length > 12 ? '...' : ''}");
      }
      
      await _writeChr!.write(chunk, withoutResponse: true);
      bleChunks++;
    }
    
    final endTime = DateTime.now().millisecondsSinceEpoch;
    debugPrint("📤 BLE COMPLETE: Sent $bleChunks BLE chunks in ${endTime - startTime}ms");
    debugPrint("📤 Complete packet header: ${packet.take(8).map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(', ')} (first 8 bytes)");
  }

  Future<void> sendWavToDevice(Uint8List wav) async {
    // Extract PCM from WAV and delegate to sendPcmToDevice
    final pcmData = wav.sublist(44); // Skip 44-byte WAV header
    await sendPcmToDevice(pcmData);
  }

  Uint8List getPcmWav() {
    if (decodedPcmWav == null) throw Exception("No audio decoded");
    return decodedPcmWav!;
  }

  void reset() {
    audioBuffer.clear();
    expectedLength = null;
    decodedPcmWav = null;
    onData?.call();
  }

  void dispose() {
    _sub?.cancel();
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

  // _encodePcmToAdpcm removed - no longer compressing outgoing audio

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

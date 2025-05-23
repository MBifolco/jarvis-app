import 'dart:async';
import 'dart:typed_data';
import 'dart:math';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// UUID of the characteristic streaming ADPCM from device → phone
const String audioNotifyUuid = '99887766-5544-3322-1100-ffeeddccbbaa';
/// UUID of the characteristic for writing TTS back phone → device
const String audioWriteUuid  = 'ab907856-3412-de90-ab4f-12cd8b6a5f4e';
/// UUID for “config flag
const String configUuid = 'f47ac10b-58cc-4372-a567-0e02b2c3d479';

class AudioStreamService {
  final BluetoothDevice device;
  final VoidCallback? onData;
  final VoidCallback? onDone;

  StreamSubscription<List<int>>? _sub;
  BluetoothCharacteristic? _writeChr;
  BluetoothCharacteristic? _configChr;
  final List<int> audioBuffer = [];
  int? expectedLength;
  Uint8List? decodedPcmWav;
  Uint8List? _outgoingWav;

  AudioStreamService(this.device, {this.onData, this.onDone});

  /// Connects, negotiates MTU, discovers services, hooks up notify + writes
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
        final id = chr.uuid.toString().toLowerCase();
        // subscribe for incoming audio
        debugPrint("🔌 Characteristic: $id");
        if (id == audioNotifyUuid &&
            (chr.properties.notify || chr.properties.indicate)) {
          await chr.setNotifyValue(true);
          _sub = chr.value.listen(_handleChunk);
        }
        // capture write-capable char for TTS back to device
        if (id == audioWriteUuid &&
            (chr.properties.write || chr.properties.writeWithoutResponse)) {
          _writeChr = chr;
        }
        // config flag
        if (id == configUuid &&
            (chr.properties.write || chr.properties.writeWithoutResponse)) {  
          _configChr = chr;
        }
      }
    }

    if (_sub == null) {
      throw Exception('Audio notify characteristic $audioNotifyUuid not found');
    }
    if (_writeChr == null) {
      throw Exception('Audio write characteristic $audioWriteUuid not found');
    }
    if (_configChr == null) {
      throw Exception('Config characteristic $configUuid not found');
    }
  }

  void _handleChunk(List<int> bytes) {
    debugPrint("Audio buffer length: ${bytes.length}");
    audioBuffer.addAll(bytes);
    if (expectedLength == null && audioBuffer.length >= 46) {
      final header = Uint8List.fromList(audioBuffer.sublist(42, 46));
      expectedLength =
        46 + ByteData.sublistView(header).getUint32(0, Endian.little);
      debugPrint("📦 Expected total length: $expectedLength bytes");
    }
    onData?.call();

    if (expectedLength != null && audioBuffer.length >= expectedLength!) {
      debugPrint("🎵 Processing complete audio buffer (${audioBuffer.length} bytes)");
      final adpcmBody = Uint8List.fromList(audioBuffer.sublist(46, expectedLength));
      debugPrint("🎵 ADPCM body length: ${adpcmBody.length} bytes");

      final pcm = decodeAdpcmToPcm(adpcmBody);
      debugPrint("🎵 Decoded to ${pcm.length} PCM samples");

      decodedPcmWav = _buildPcmWav(pcm);
      _outgoingWav = decodedPcmWav;
      debugPrint("🎵 Built WAV file: ${decodedPcmWav!.length} bytes");

      _inspectRoundTrip();
      onDone?.call();
      reset();  // prepare for next message
    }
  }

  void _inspectRoundTrip() {
  final orig = _outgoingWav!;
  final rt   = decodedPcmWav!;
  // strip 44-byte WAV header, work only on the raw PCM data
  final origBytes = orig.sublist(44);
  final rtBytes   = rt.sublist(44);
  final origBd = ByteData.sublistView(origBytes);
  final rtBd   = ByteData.sublistView(rtBytes);
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
  debugPrint('🔍 Round-trip compare: $sampleCount samples; '
             'differences: $diffs; max sample-error: $maxErr');
  debugPrint('   orig[0..10]: ${origBytes.sublist(0, 10)}');
  debugPrint('     rt[0..10]: ${rtBytes.sublist(0, 10)}');
}

  /// Call this to send a raw PCM‐WAV back to the device speaker,
  /// but first compress it to IMA ADPCM to reduce payload size.
  Future<void> sendWavToDevice(Uint8List wav) async {
    if (_writeChr == null) {
      throw StateError('Audio write characteristic not initialized');
    }
    // Compress PCM WAV to ADPCM
    // 1) Compress PCM WAV to ADPCM
    final adpcm = _encodePcmToAdpcm(wav);

    // 2) Build a 4-byte little-endian header of the ADPCM length
    final header = ByteData(4)..setUint32(0, adpcm.length, Endian.little);

    // 3) Concatenate header + payload
    final packet = Uint8List.fromList([
      ...header.buffer.asUint8List(),
      ...adpcm,
    ]);

    final mtu = await device.mtu.first;
    final chunkSize = mtu - 3; // ATT overhead
    for (var offset = 0; offset < packet.length; offset += chunkSize) {
      final end = min(offset + chunkSize, packet.length);
      final chunk = packet.sublist(offset, end);
      await _writeChr!.write(chunk, withoutResponse: true);
    }
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

  /// Encodes PCM WAV data into IMA ADPCM blocks (blockAlign=256)
  Uint8List _encodePcmToAdpcm(Uint8List wav) {
    // Parse WAV header and extract raw 16-bit samples
    if (wav.length < 44) throw Exception('Invalid WAV buffer');
    final byteData = ByteData.sublistView(wav);
    final sampleCount = (wav.length - 44) ~/ 2;
    final samples = List<int>.generate(sampleCount,
      (i) => byteData.getInt16(44 + i * 2, Endian.little));
    const blockAlign = 256;
    final out = <int>[];
    int offset = 0;

    while (offset < samples.length) {
      final endSample = min(offset + (blockAlign - 4) * 2, samples.length);
      final blockSamples = samples.sublist(offset, endSample);

      // Block header: initial predictor + index + reserved
      final predictor = blockSamples[0];
      out.addAll(_uint16le(predictor));
      int index = 0;
      out.add(index);
      out.add(0);  // reserved byte
      int step = _stepTable[index];
      int predVal = predictor;
      int nibblePair = 0;
      bool hasHigh = false;

      // Encode samples into 4-bit codes
      for (int i = 1; i < blockSamples.length; i++) {
        int val = blockSamples[i];
        int diff = val - predVal;
        int code = 0;
        if (diff < 0) { code = 8; diff = -diff; }
        int tempStep = step;
        if (diff >= tempStep) { code |= 4; diff -= tempStep; }
        tempStep >>= 1;
        if (diff >= tempStep) { code |= 2; diff -= tempStep; }
        tempStep >>= 1;
        if (diff >= tempStep) { code |= 1; }

        int delta = step >> 3;
        if ((code & 1) != 0) delta += step >> 2;
        if ((code & 2) != 0) delta += step >> 1;
        if ((code & 4) != 0) delta += step;
        if ((code & 8) != 0) delta = -delta;

        predVal = (predVal + delta).clamp(-32768, 32767);
        index = (index + _indexTable[code]).clamp(0, 88);
        step = _stepTable[index];

        // Pack two 4-bit codes into one byte
        if (!hasHigh) {
          nibblePair = code & 0x0F;
          hasHigh = true;
        } else {
          nibblePair |= (code & 0x0F) << 4;
          out.add(nibblePair);
          nibblePair = 0;
          hasHigh = false;
        }
      }
      // If there's an odd leftover nibble
      if (hasHigh) {
        out.add(nibblePair);
      }
      // Pad block up to blockAlign
      while (out.length % blockAlign != 0) {
        out.add(0);
      }
      offset += (blockAlign - 4) * 2;
    }
    return Uint8List.fromList(out);
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

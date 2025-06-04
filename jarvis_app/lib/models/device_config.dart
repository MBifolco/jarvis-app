import '../services/config_service.dart';
import 'package:flutter/foundation.dart';
class DeviceConfig {
  bool compressIncoming = false;
  bool sendDebugDrops = false;
  bool playOnDevice = true;
  int ledBrightness = 0;

  late ConfigService _service;

  void bindService(ConfigService service) {
    _service = service;
  }

  void updateFromPacket(List<int> bytes) {
    if (bytes.length < 2) return;

    final id = bytes[0];
    final len = bytes[1];
    final data = bytes.sublist(2);

    switch (id) {
      case 0x01:
        if (len >= 1) compressIncoming = data[0] != 0;
        break;
      case 0x02:
        if (len >= 1) sendDebugDrops = data[0] != 0;
        break;
      case 0x03:
        if (len >= 2) {
          ledBrightness = data[0] | (data[1] << 8);
        }
        break;
      case 0x04:
        if (len >= 1) playOnDevice = data[0] != 0;
        break;
      default:
        break;
    }
  }

  void setCompressIncoming(bool enabled) {
    compressIncoming = enabled;
    _service.sendConfigUpdate(0x01, [enabled ? 1 : 0]);
    debugPrint('🛠️ Compress Incoming set to $enabled');
  }

  void setSendDebugDrops(bool enabled) {
    sendDebugDrops = enabled;
    _service.sendConfigUpdate(0x02, [enabled ? 1 : 0]);
    debugPrint('🛠️ Send Debug Drops set to $enabled');
  }

  void setPlayOnDevice(bool enabled) {
    playOnDevice = enabled;
    _service.sendConfigUpdate(0x04, [enabled ? 1 : 0]);
    debugPrint('🛠️ Play on Device set to $enabled');
  }

  void setLedBrightness(int value) {
    ledBrightness = value.clamp(0, 65535);
    _service.sendConfigUpdate(0x03, [value & 0xFF, (value >> 8) & 0xFF]);
    debugPrint('🛠️ LED Brightness set to $ledBrightness');
  }
}

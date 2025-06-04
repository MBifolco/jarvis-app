import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../models/device_config.dart';
import 'bt_connection_service.dart';

const String configCharUuid = 'f47ac10b-58cc-4372-a567-0e02b2c3d479';

class ConfigService implements BlePeripheralService {
  final BluetoothDevice device;
  final void Function()? onConfigUpdated;

  final DeviceConfig config = DeviceConfig();
  StreamSubscription<List<int>>? _sub;
  BluetoothCharacteristic? _writeChr;

  ConfigService(this.device, {this.onConfigUpdated}) {
    config.bindService(this);
  }

  @override
  Future<void> initWithServices(List<BluetoothService> services) async {
    for (final svc in services) {
      for (final chr in svc.characteristics) {
        final id = chr.uuid.toString().toLowerCase();
        if (id == configCharUuid) {
          if (chr.properties.write || chr.properties.writeWithoutResponse) {
            _writeChr = chr;
          }
          if (chr.properties.notify || chr.properties.indicate) {
            _sub = chr.lastValueStream.listen((value) {
              if (value.isEmpty) return;
              config.updateFromPacket(value);
              onConfigUpdated?.call();
            });
            await chr.setNotifyValue(true);
          }
        }
      }
    }
    if (_writeChr == null) {
      debugPrint("⚠️ Config write characteristic not found");
    }
  }

  Future<void> sendConfigUpdate(int id, List<int> payload) async {
    if (_writeChr == null) {
      debugPrint("⚠️ No write characteristic available");
      return;
    }
    final buffer = Uint8List.fromList([id, payload.length, ...payload]);
    await _writeChr!.write(buffer, withoutResponse: false);
    debugPrint("📤 Sent config [$id] = $payload");
  }

  void dispose() {
    _sub?.cancel();
  }
}

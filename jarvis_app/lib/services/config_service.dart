import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'bt_connection_service.dart';

const String configCharUuid = 'f47ac10b-58cc-4372-a567-0e02b2c3d479';

class ConfigService implements BlePeripheralService {
  final BluetoothDevice device;
  final void Function(List<int> bytes)? onConfigUpdate;

  StreamSubscription<List<int>>? _sub;

  ConfigService(this.device, {this.onConfigUpdate});

  @override
  Future<void> initWithServices(List<BluetoothService> services) async {
    for (final svc in services) {
      for (final chr in svc.characteristics) {
        final id = chr.uuid.toString().toLowerCase();
        if (id == configCharUuid &&
            (chr.properties.notify || chr.properties.indicate)) {
          
          // Subscribe to the value stream BEFORE enabling notifications
          _sub = chr.lastValueStream.listen((value) {
            if (value.isEmpty) return; // ignore empty emissions
            final safeCopy = List<int>.from(value);
            debugPrint("🛠️ Config update received: $safeCopy");
            onConfigUpdate?.call(safeCopy);
          });

          // Enable notifications
          await chr.setNotifyValue(true);

          return;
        }
      }
    }
    throw Exception("Config notify characteristic $configCharUuid not found");
  }

  void dispose() {
    _sub?.cancel();
  }
}

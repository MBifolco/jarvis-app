import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Services that rely on BLE characteristics should implement this interface
abstract class BlePeripheralService {
  Future<void> initWithServices(List<BluetoothService> services);
}

class BluetoothConnectionService {
  final BluetoothDevice device;

  BluetoothConnectionService(this.device);

  /// Handles connecting, MTU negotiation, service discovery,
  /// and delegating to peripheral services.
  Future<void> initAll(List<BlePeripheralService> services, {int mtu = 500}) async {
    try {
      await device.connect(autoConnect: false);
    } catch (_) {}

    await device.requestMtu(mtu);
    final negotiated = await device.mtu.first;
    debugPrint("📏 MTU negotiated: $negotiated");

    final bleServices = await device.discoverServices();

    for (final svc in services) {
      await svc.initWithServices(bleServices);
    }
  }

  Future<void> dispose() async {
    try {
      await device.disconnect();
    } catch (_) {}
  }
}

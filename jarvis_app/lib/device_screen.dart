// lib/device_screen.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class DeviceScreen extends StatefulWidget {
  final BluetoothDevice device;
  const DeviceScreen({required this.device, super.key});

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  List<BluetoothService> _services = [];
  final Map<Guid, List<int>> _values = {};
  final Map<Guid, bool> _notifying = {};
  final Map<Guid, List<String>> _logs = {};

  @override
  void initState() {
    super.initState();
    _connectAndSubscribe();
  }

  Future<void> _connectAndSubscribe() async {
    // 1) Connect
    try {
      await widget.device.connect(autoConnect: false);
    } catch (_) {
      // already connected
    }

    // 2) Discover services
    final svcs = await widget.device.discoverServices();
    setState(() => _services = svcs);

    // 3) Auto‐subscribe to all notify characteristics
    for (var s in _services) {
      for (var c in s.characteristics) {
        if (c.properties.notify) {
          await c.setNotifyValue(true);
          _notifying[c.uuid] = true;

          c.lastValueStream.listen((bytes) {
            // keep raw bytes
            _values[c.uuid] = bytes;

            // decode as UTF-8 (or fall back to hex)
            String msg;
            try {
              msg = utf8.decode(bytes);
            } catch (_) {
              msg = bytes
                  .map((b) => b.toRadixString(16).padLeft(2, '0'))
                  .join(' ');
            }

            // log up to 5 recent entries
            final log = _logs.putIfAbsent(c.uuid, () => []);
            log.insert(0, msg);
            if (log.length > 5) log.removeLast();

            setState(() {}); // refresh UI
          });
        }
      }
    }
  }

  @override
  void dispose() {
    // turn off notifications, then disconnect
    for (var s in _services) {
      for (var c in s.characteristics) {
        if (_notifying[c.uuid] == true) {
          c.setNotifyValue(false);
        }
      }
    }
    widget.device.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.device.platformName)),
      body: _services.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: _services.map((s) {
                return ExpansionTile(
                  title: Text('Service ${s.uuid}'),
                  children: s.characteristics.map((c) {
                    final uuid = c.uuid;
                    final raw = _values[uuid]
                            ?.map((b) => b.toRadixString(16).padLeft(2, '0'))
                            .join(' ') ??
                        '─';
                    final log = _logs[uuid] ?? [];

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ListTile(
                            title: Text('Char ${uuid.toString()}'),
                            subtitle: Text('Last bytes: $raw'),
                            trailing: Icon(
                              _notifying[uuid] == true
                                  ? Icons.notifications_active
                                  : Icons.notifications_off,
                            ),
                          ),
                          if (log.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(left: 72.0, bottom: 8.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children:
                                    log.map((msg) => Text('• $msg')).toList(),
                              ),
                            ),
                          const Divider(),
                        ],
                      ),
                    );
                  }).toList(),
                );
              }).toList(),
            ),
    );
  }
}

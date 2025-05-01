// lib/main.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'device_screen.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Jarvis Connector',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const ScanPage(),
    );
  }
}

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final List<BluetoothDevice> _devices = [];
  StreamSubscription<List<ScanResult>>? _scanSub;

  @override
  void initState() {
    super.initState();
    _prepareAndScan();
  }

  Future<void> _prepareAndScan() async {
    // 1. Make sure Bluetooth is on
    final btState = await FlutterBluePlus.adapterState.first;
    if (btState != BluetoothAdapterState.on) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please turn on Bluetooth')),
      );
      return;
    }

    // 2. Request runtime permissions on Android
    if (Platform.isAndroid) {
      final status = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();

      if (status[Permission.bluetoothScan]   != PermissionStatus.granted ||
          status[Permission.bluetoothConnect]!= PermissionStatus.granted ||
          status[Permission.locationWhenInUse]!= PermissionStatus.granted) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Permissions denied')),
        );
        return;
      }
    }

    // 3. Start scanning
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));

    // 4. Listen for results
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (var r in results) {
        final d = r.device;
        final name = d.platformName;
        if (name.contains('Jarvis') && !_devices.contains(d)) {
          setState(() => _devices.add(d));
        }
      }
    });
  }

  @override
  void dispose() {
    // stop scan and cancel listener
    FlutterBluePlus.stopScan();
    _scanSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan for Jarvis')),
      body: _devices.isEmpty
          ? const Center(child: Text('No Jarvis devices found'))
          : ListView.builder(
              itemCount: _devices.length,
              itemBuilder: (ctx, i) {
                final device = _devices[i];
                return ListTile(
                  title: Text(device.platformName),
                  subtitle: Text(device.remoteId.str),
                  onTap: () async {
                    try {
                      await device.connect(timeout: const Duration(seconds: 5));
                    } catch (_) {
                      // already connected or timeout
                    }
                    if (!context.mounted) return;
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => DeviceScreen(device: device),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}

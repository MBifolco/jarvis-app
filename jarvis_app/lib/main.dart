import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Jarvis Connector',
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
  final List<BluetoothDevice> devices = [];

  @override
  void initState() {
    super.initState();
    // Start scanning
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
    // Listen for scan results
    FlutterBluePlus.scanResults.listen((List<ScanResult> results) {
      for (var result in results) {
        final device = result.device;
        final name = device.platformName;
        if (name.contains('Jarvis') && !devices.contains(device)) {
          setState(() {
            devices.add(device);
          });
        }
      }
    });
  }

  @override
  void dispose() {
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan for Jarvis')),
      body: ListView.builder(
        itemCount: devices.length,
        itemBuilder: (context, index) {
          final device = devices[index];
          final name = device.platformName;
          final String id = device.remoteId.str; 
          return ListTile(
            title: Text(name),
            subtitle: Text(id),
            onTap: () async {
              await device.connect();
              // TODO: Discover services or navigate to details
            },
          );
        },
      ),
    );
  }
}
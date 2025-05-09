// ignore_for_file: avoid_print, public_member_api_docs
import 'dart:async';
import 'package:blev/ble.dart';
import 'package:blev/ble_central.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:typed_data';
import 'dart:convert';
List<String> lines = [];

void main() {
  runZoned(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      Permission.bluetoothScan.request().then((_) =>
          Permission.bluetoothConnect.request()).then((_) {
        BleCentral.create().then((ble) {
          final stateStream = ble.getState();
          late StreamSubscription<AdapterState> streamSub;
          streamSub = stateStream.listen((state) {
            if (state == AdapterState.poweredOn) {
              streamSub.cancel();
              scanAndConnectToJarvis(ble);
            }
          });
        }).catchError((error) {
          print('error requesting bluetooth permissions: $error');
        });
      });

      runApp(const MyApp());
    },
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) async {
        if (lines.length > 30) {
          lines.removeAt(0);
        }
        lines.add('${DateTime.now()}: $line');
        parent.print(zone, line);
      },
    ),
  );
}

Future<void> scanAndConnectToJarvis(BleCentral ble) async {
  const int jarvisPsm = 0x0040;

  print('Scanning for Jarvis device...');

  ble.scanForPeripherals([]).listen(
    (periphInfo) async {
      final name = periphInfo.name ?? '';
      final id = periphInfo.id;

      if (!name.toLowerCase().contains('jarvis')) return;

      print('🟢 Found Jarvis device: $name [$id]');
      //await ble.stopScan();

      try {
        final periph = await ble.connectToPeripheral(id);
        print('✅ Connected to Jarvis');

        final chan = await periph.connectToL2CapChannel(jarvisPsm);
        print('📡 L2CAP channel opened on PSM $jarvisPsm');

        const message = 'Hello from Flutter';
        await chan.write(Uint8List.fromList(message.codeUnits));
        print('✉️ Sent: $message');

        final response = await chan.read(256);
        if (response == null) {
          print('⚠️ No response from device');
        } else {
          print('📥 Received: ${utf8.decode(response)}');
        }

        await chan.close();
        print('✅ Channel closed');
        await periph.disconnect();
        print('🔌 Disconnected');

      } catch (e) {
        print('❌ Error during connect or L2CAP exchange: $e');
      }
    },
    onError: (e) => print('Scan error: $e'),
  );
}


class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Flutter BLE Scanner',
      home: MyHomePage(title: 'BLE Scanner'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});
  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  _MyHomePageState() {
    loadData();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: ListView.builder(
        itemCount: lines.length,
        itemBuilder: (BuildContext context, int index) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2.0, horizontal: 8.0),
            child: Text(lines[index]),
          );
        },
      ),
    );
  }

  Future<void> loadData() async {
    while (true) {
      await Future<void>.delayed(const Duration(seconds: 1));
      setState(() {});
    }
  }
}

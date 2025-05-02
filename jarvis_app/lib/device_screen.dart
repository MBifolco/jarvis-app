// lib/device_screen.dart
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:audioplayers/audioplayers.dart';

/// Your 128-bit UUIDs (little-endian → standard form)
const String wakeCharUuid  = '01234567-89ab-cdef-1032-547698badcfe';
const String audioCharUuid = '99887766-5544-3322-1100-ffeeddccbbaa';

class DeviceScreen extends StatefulWidget {
  final BluetoothDevice device;
  const DeviceScreen({required this.device, super.key});

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  late final AudioPlayer _player;
  StreamSubscription<List<int>>? _audioSub;
  Timer? _playTimer;

  List<BluetoothService> _services = [];
  final Map<Guid, List<String>> _wakeLogs  = {};
  final Map<Guid, List<int>>    _rawValues = {};
  final Map<Guid, bool>         _notifying = {};

  bool _buffering = false;
  bool _isPlayingAudio = false;
  final List<int> _audioBuffer = [];

  @override
  void initState() {
    super.initState();
    _setupAudioPlayer();
    _connectAndSubscribe();
  }

  Future<void> _setupAudioPlayer() async {
    _player = AudioPlayer();
    // Stop automatically when the clip finishes
    await _player.setReleaseMode(ReleaseMode.stop);
  }

  Future<void> _connectAndSubscribe() async {
    // CONNECT
    try {
      await widget.device.connect(autoConnect: false);
    } catch (_) {}
    // DISCOVER SERVICES
    final svcs = await widget.device.discoverServices();
    setState(() => _services = svcs);

    // SUBSCRIBE & ROUTE NOTIFICATIONS
    for (var svc in svcs) {
      for (var chr in svc.characteristics) {
        if (!chr.properties.notify) continue;
        await chr.setNotifyValue(true);
        _notifying[chr.uuid] = true;

        final uuid = chr.uuid.toString().toLowerCase();
        if (uuid == audioCharUuid) {
          // ▸ AUDIO: buffer the first 5s then play
          _audioSub = chr.value.listen((bytes) {
            if (!_buffering) {
              _buffering = true;
              _playTimer = Timer(const Duration(seconds: 5), () async {
                final data = Uint8List.fromList(_audioBuffer);
                await _player.play(BytesSource(data));
                setState(() => _isPlayingAudio = true);
              });
            }
            _audioBuffer.addAll(bytes);
          });
        } else if (uuid == wakeCharUuid) {
          // ▸ WAKE: decode UTF-8, keep last 10
          chr.value.listen((bytes) {
            final msg = utf8.decode(bytes);
            final log = _wakeLogs.putIfAbsent(chr.uuid, () => []);
            log.insert(0, msg);
            if (log.length > 10) log.removeLast();
            setState(() {});
          });
        } else {
          // ▸ OTHER: show raw hex
          chr.value.listen((bytes) {
            _rawValues[chr.uuid] = bytes;
            setState(() {});
          });
        }
      }
    }
  }

  @override
  void dispose() {
    // CANCEL NOTIFICATIONS
    for (var svc in _services) {
      for (var chr in svc.characteristics) {
        if (_notifying[chr.uuid] == true) {
          chr.setNotifyValue(false);
        }
      }
    }
    _audioSub?.cancel();
    _playTimer?.cancel();
    widget.device.disconnect();
    _player.stop();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.device.platformName)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: _services.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Audio status
                  Text(
                    _buffering
                      ? (_isPlayingAudio
                          ? '🔊 Playing audio…'
                          : '⏳ Buffering audio…')
                      : '⏳ Waiting for audio…',
                    style: t.bodyMedium,
                  ),
                  const SizedBox(height: 16),

                  // Wake logs
                  if (_wakeLogs.isNotEmpty) ...[
                    Text('🔔 Wake Messages:', style: t.titleLarge),
                    const SizedBox(height: 8),
                    for (var entry in _wakeLogs.entries)
                      for (var msg in entry.value)
                        Text('• $msg', style: t.bodyMedium),
                    const Divider(height: 24),
                  ],

                  // Services & characteristics
                  Expanded(
                    child: ListView(
                      children: _services.map((svc) {
                        return ExpansionTile(
                          title: Text('Service ${svc.uuid}'),
                          children: svc.characteristics.map((chr) {
                            final uuid = chr.uuid;
                            final u = uuid.toString().toLowerCase();
                            final isAudio = (u == audioCharUuid);
                            final isWake  = (u == wakeCharUuid);
                            final notifying = _notifying[uuid] ?? false;
                            final hex = (_rawValues[uuid] ?? [])
                                .map((b) => b.toRadixString(16).padLeft(2,'0'))
                                .join(' ');

                            return ListTile(
                              leading: isAudio
                                ? const Icon(Icons.volume_up, color: Colors.green)
                                : isWake
                                    ? const Icon(Icons.notifications, color: Colors.orange)
                                    : const Icon(Icons.memory),
                              title: Text(
                                isAudio
                                  ? 'Audio Stream'
                                  : isWake
                                      ? 'Wake Notifications'
                                      : 'Characteristic ${uuid.toString()}',
                              ),
                              subtitle: isAudio
                                ? Text(_isPlayingAudio
                                    ? 'Playing'
                                    : _buffering
                                        ? 'Buffered, waiting to play'
                                        : 'Waiting…')
                                : isWake
                                    ? Text('last: ${_wakeLogs[uuid]?.first ?? '—'}')
                                    : Text(hex.isEmpty ? 'no data' : 'raw: $hex'),
                              trailing: Icon(
                                notifying
                                  ? Icons.notifications_active
                                  : Icons.notifications_off,
                                color: notifying ? Colors.blue : Colors.grey,
                              ),
                            );
                          }).toList(),
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

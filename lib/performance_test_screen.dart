import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'services/l2cap_service.dart';

class PerformanceTestScreen extends StatefulWidget {
  final BluetoothDevice device;
  
  const PerformanceTestScreen({
    required this.device,
    super.key,
  });
  
  @override
  State<PerformanceTestScreen> createState() => _PerformanceTestScreenState();
}

class _PerformanceTestScreenState extends State<PerformanceTestScreen> {
  final L2capService _l2capService = L2capService();
  
  bool _connected = false;
  int? _psm;
  bool _testing = false;
  
  // Test parameters
  int _packetSize = 512;
  int _packetCount = 100;
  int _testDuration = 10; // seconds
  
  // Test results
  int _packetsSent = 0;
  int _packetsReceived = 0;
  int _bytesSent = 0;
  int _bytesReceived = 0;
  double _throughputMbps = 0.0;
  Duration _testTime = Duration.zero;
  List<String> _testLog = [];
  
  StreamSubscription<String>? _messageSubscription;
  Timer? _testTimer;
  Stopwatch _stopwatch = Stopwatch();
  
  @override
  void initState() {
    super.initState();
    _init();
  }
  
  Future<void> _init() async {
    await _l2capService.init();
    
    // Subscribe to incoming messages for throughput measurement
    _messageSubscription = _l2capService.messageStream.listen((message) {
      if (_testing && mounted) {
        _packetsReceived++;
        _bytesReceived += message.length;
        
        // Calculate throughput
        final elapsed = _stopwatch.elapsedMilliseconds / 1000.0;
        if (elapsed > 0) {
          final bitsPerSecond = (_bytesReceived * 8) / elapsed;
          _throughputMbps = bitsPerSecond / 1000000.0;
        }
        
        setState(() {});
      }
    });
    
    await _readPsmFromGatt();
  }
  
  Future<void> _readPsmFromGatt() async {
    try {
      const psmUuid = '88776655-4433-2211-f0de-bc9a78563412';
      
      final services = await widget.device.discoverServices();
      
      for (final service in services) {
        for (final char in service.characteristics) {
          if (char.uuid.toString().toLowerCase() == psmUuid) {
            final value = await char.read();
            if (value.length >= 2) {
              _psm = value[0] | (value[1] << 8);
              if (mounted) {
                setState(() {});
              }
              debugPrint('Read PSM from GATT: $_psm');
              _connectL2cap();
              return;
            }
          }
        }
      }
      
      _psm = 0x40;
      if (mounted) {
        setState(() {});
      }
      debugPrint('Using default PSM: $_psm');
      _connectL2cap();
    } catch (e) {
      debugPrint('Error reading PSM: $e');
      _psm = 0x40;
      if (mounted) {
        setState(() {});
      }
      _connectL2cap();
    }
  }
  
  Future<void> _connectL2cap() async {
    if (_psm == null) return;
    
    final success = await _l2capService.connect(
      widget.device.remoteId.toString(),
      _psm!,
    );
    
    if (mounted) {
      setState(() {
        _connected = success;
      });
    }
    
    _addLog(success ? 'L2CAP connected' : 'L2CAP connection failed');
  }
  
  void _addLog(String message) {
    if (mounted) {
      final timestamp = DateTime.now();
      setState(() {
        _testLog.add('${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}:${timestamp.second.toString().padLeft(2, '0')} - $message');
      });
    }
  }
  
  void _resetResults() {
    if (mounted) {
      setState(() {
        _packetsSent = 0;
        _packetsReceived = 0;
        _bytesSent = 0;
        _bytesReceived = 0;
        _throughputMbps = 0.0;
        _testTime = Duration.zero;
        _testLog.clear();
      });
    }
  }
  
  Future<void> _startThroughputTest() async {
    if (!_connected) return;
    
    if (mounted) {
      setState(() {
        _testing = true;
      });
    }
    
    _resetResults();
    _addLog('Starting throughput test');
    _addLog('Packet size: $_packetSize bytes');
    _addLog('Duration: $_testDuration seconds');
    
    _stopwatch.reset();
    _stopwatch.start();
    
    // Create test data
    final testData = Uint8List(_packetSize);
    for (int i = 0; i < testData.length; i++) {
      testData[i] = i % 256;
    }
    
    // Start test timer
    _testTimer = Timer.periodic(const Duration(milliseconds: 10), (timer) async {
      if (_stopwatch.elapsedMilliseconds >= _testDuration * 1000) {
        _stopThroughputTest();
        return;
      }
      
      // Send packet
      final success = await _l2capService.sendBytes(testData);
      if (success && mounted) {
        _packetsSent++;
        _bytesSent += testData.length;
        setState(() {});
      }
    });
  }
  
  void _stopThroughputTest() {
    _testTimer?.cancel();
    _stopwatch.stop();
    
    if (mounted) {
      setState(() {
        _testing = false;
        _testTime = _stopwatch.elapsed;
      });
    }
    
    final seconds = _testTime.inMilliseconds / 1000.0;
    final sentMbps = (_bytesSent * 8) / (seconds * 1000000.0);
    final receivedMbps = (_bytesReceived * 8) / (seconds * 1000000.0);
    
    _addLog('Test completed');
    _addLog('Duration: ${seconds.toStringAsFixed(2)}s');
    _addLog('Packets sent: $_packetsSent');
    _addLog('Packets received: $_packetsReceived');
    _addLog('Sent throughput: ${sentMbps.toStringAsFixed(2)} Mbps');
    _addLog('Received throughput: ${receivedMbps.toStringAsFixed(2)} Mbps');
    _addLog('Packet loss: ${((_packetsSent - _packetsReceived) / _packetsSent * 100).toStringAsFixed(1)}%');
  }
  
  Future<void> _startLatencyTest() async {
    if (!_connected) return;
    
    if (mounted) {
      setState(() {
        _testing = true;
      });
    }
    
    _resetResults();
    _addLog('Starting latency test');
    _addLog('Packet count: $_packetCount');
    
    final latencies = <int>[];
    
    for (int i = 0; i < _packetCount; i++) {
      final stopwatch = Stopwatch()..start();
      final message = 'PING_$i';
      
      // Send message and wait for echo
      final completer = Completer<void>();
      late StreamSubscription subscription;
      
      subscription = _l2capService.messageStream.listen((received) {
        if (received.contains('PING_$i')) {
          stopwatch.stop();
          latencies.add(stopwatch.elapsedMicroseconds);
          subscription.cancel();
          completer.complete();
        }
      });
      
      await _l2capService.sendMessage(message);
      
      // Wait for response with timeout
      try {
        await completer.future.timeout(const Duration(seconds: 1));
        _packetsReceived++;
      } catch (e) {
        _addLog('Timeout for packet $i');
        subscription.cancel();
      }
      
      _packetsSent++;
      if (mounted) {
        setState(() {});
      }
      
      // Small delay between packets
      await Future.delayed(const Duration(milliseconds: 10));
    }
    
    if (mounted) {
      setState(() {
        _testing = false;
      });
    }
    
    if (latencies.isNotEmpty) {
      final avgLatency = latencies.reduce((a, b) => a + b) / latencies.length;
      final minLatency = latencies.reduce((a, b) => a < b ? a : b);
      final maxLatency = latencies.reduce((a, b) => a > b ? a : b);
      
      _addLog('Latency test completed');
      _addLog('Packets sent: $_packetsSent');
      _addLog('Packets received: $_packetsReceived');
      _addLog('Average latency: ${(avgLatency / 1000).toStringAsFixed(2)}ms');
      _addLog('Min latency: ${(minLatency / 1000).toStringAsFixed(2)}ms');
      _addLog('Max latency: ${(maxLatency / 1000).toStringAsFixed(2)}ms');
    }
  }
  
  @override
  void dispose() {
    _testTimer?.cancel();
    _messageSubscription?.cancel();
    _l2capService.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('L2CAP Performance Test'),
        actions: [
          if (_psm != null)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Chip(
                label: Text('PSM: 0x${_psm!.toRadixString(16).toUpperCase()}'),
              ),
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Connection status
            Card(
              color: _connected ? Colors.green.shade100 : Colors.red.shade100,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(
                      _connected ? Icons.check_circle : Icons.error,
                      color: _connected ? Colors.green : Colors.red,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _connected ? 'L2CAP Connected' : 'L2CAP Disconnected',
                      style: TextStyle(
                        color: _connected ? Colors.green.shade800 : Colors.red.shade800,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            
            const SizedBox(height: 16),
            
            // Test parameters
            const Text('Test Parameters', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            
            Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(
                      labelText: 'Packet Size (bytes)',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    controller: TextEditingController(text: _packetSize.toString()),
                    onChanged: (value) => _packetSize = int.tryParse(value) ?? 512,
                    enabled: !_testing,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(
                      labelText: 'Test Duration (s)',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    controller: TextEditingController(text: _testDuration.toString()),
                    onChanged: (value) => _testDuration = int.tryParse(value) ?? 10,
                    enabled: !_testing,
                  ),
                ),
              ],
            ),
            
            const SizedBox(height: 16),
            
            TextField(
              decoration: const InputDecoration(
                labelText: 'Latency Test Packets',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              controller: TextEditingController(text: _packetCount.toString()),
              onChanged: (value) => _packetCount = int.tryParse(value) ?? 100,
              enabled: !_testing,
            ),
            
            const SizedBox(height: 16),
            
            // Test buttons
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: (_connected && !_testing) ? _startThroughputTest : null,
                    child: _testing 
                        ? const Text('Testing...') 
                        : const Text('Throughput Test'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton(
                    onPressed: (_connected && !_testing) ? _startLatencyTest : null,
                    child: const Text('Latency Test'),
                  ),
                ),
              ],
            ),
            
            if (_testing)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: ElevatedButton(
                  onPressed: _stopThroughputTest,
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  child: const Text('Stop Test'),
                ),
              ),
            
            const SizedBox(height: 16),
            
            // Test results
            if (_packetsSent > 0 || _testing) ...[
              const Text('Test Results', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Packets Sent: $_packetsSent'),
                      Text('Packets Received: $_packetsReceived'),
                      Text('Bytes Sent: $_bytesSent'),
                      Text('Bytes Received: $_bytesReceived'),
                      if (_throughputMbps > 0)
                        Text('Throughput: ${_throughputMbps.toStringAsFixed(2)} Mbps'),
                      if (_testTime != Duration.zero)
                        Text('Test Duration: ${_testTime.inMilliseconds / 1000.0}s'),
                    ],
                  ),
                ),
              ),
            ],
            
            const SizedBox(height: 16),
            
            // Test log
            const Text('Test Log', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: _testLog.length,
                  itemBuilder: (context, index) {
                    return Text(
                      _testLog[index],
                      style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
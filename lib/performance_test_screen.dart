// lib/performance_test_screen.dart

import 'dart:async';
import 'dart:math';
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
  
  bool _l2capConnected = false;
  bool _gattConnected = false;
  int? _psm;
  
  // Test parameters
  int _messageSize = 100; // bytes
  int _messageCount = 100;
  int _testDuration = 10; // seconds
  
  // Test results
  TestResults? _l2capResults;
  TestResults? _gattResults;
  bool _testing = false;
  String _currentTest = '';
  
  @override
  void initState() {
    super.initState();
    _init();
  }
  
  Future<void> _init() async {
    // Initialize L2CAP service
    await _l2capService.init();
    
    // Initialize GATT connection - we don't need services, just basic connection
    try {
      await widget.device.connect();
      setState(() {
        _gattConnected = true;
      });
    } catch (e) {
      debugPrint('Error connecting to device: $e');
    }
    
    // Read PSM from GATT and connect L2CAP
    await _readPsmAndConnectL2cap();
  }
  
  Future<void> _readPsmAndConnectL2cap() async {
    try {
      const psmUuid = '88776655-4433-2211-f0de-bc9a78563412';
      
      final services = await widget.device.discoverServices();
      
      for (final service in services) {
        for (final char in service.characteristics) {
          if (char.uuid.toString().toLowerCase() == psmUuid) {
            final value = await char.read();
            if (value.length >= 2) {
              _psm = value[0] | (value[1] << 8);
              
              // Connect to L2CAP
              final success = await _l2capService.connect(
                widget.device.remoteId.toString(),
                _psm!,
              );
              
              setState(() {
                _l2capConnected = success;
              });
              
              return;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Error connecting L2CAP: $e');
    }
  }
  
  Future<void> _runThroughputTest(String protocol) async {
    setState(() {
      _testing = true;
      _currentTest = '$protocol Throughput Test';
    });
    
    final results = TestResults();
    final stopwatch = Stopwatch()..start();
    final random = Random();
    
    int messagesSent = 0;
    int messagesReceived = 0;
    int totalBytes = 0;
    
    // Generate test data - use same ASCII text payload for both protocols
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ';
    final testMessage = List.generate(min(_messageSize, 200), (i) => chars[random.nextInt(chars.length)]).join();
    
    // Subscribe to responses if using L2CAP
    StreamSubscription<String>? subscription;
    BluetoothCharacteristic? testCharacteristic;
    
    if (protocol == 'L2CAP') {
      subscription = _l2capService.messageStream.listen((message) {
        if (message.startsWith('ECHO: ')) {
          messagesReceived++;
        }
      });
    } else if (protocol == 'GATT') {
      // Find a writable characteristic for GATT testing (prefer writeWithoutResponse)
      try {
        final services = await widget.device.discoverServices();
        BluetoothCharacteristic? fallbackChar;
        
        for (final service in services) {
          for (final char in service.characteristics) {
            if (char.properties.writeWithoutResponse) {
              testCharacteristic = char;
              break;
            } else if (char.properties.write && fallbackChar == null) {
              fallbackChar = char; // Keep as fallback
            }
          }
          if (testCharacteristic != null) break;
        }
        
        // Use fallback if no writeWithoutResponse found
        testCharacteristic ??= fallbackChar;
        
        if (testCharacteristic != null) {
          debugPrint('Using GATT characteristic: ${testCharacteristic.uuid} '
                    '(writeWithoutResponse: ${testCharacteristic.properties.writeWithoutResponse}, '
                    'write: ${testCharacteristic.properties.write})');
        }
      } catch (e) {
        debugPrint('Error finding GATT test characteristic: $e');
      }
    }
    
    // Send messages for the test duration
    while (stopwatch.elapsedMilliseconds < _testDuration * 1000 && messagesSent < _messageCount) {
      try {
        if (protocol == 'L2CAP' && _l2capConnected) {
          await _l2capService.sendMessage(testMessage);
        } else if (protocol == 'GATT' && _gattConnected && testCharacteristic != null) {
          // Send same text data via GATT characteristic as UTF-8 bytes
          final utf8Bytes = testMessage.codeUnits;
          final data = utf8Bytes.take(min(_messageSize, 20)).toList(); // GATT has smaller MTU
          try {
            if (testCharacteristic.properties.writeWithoutResponse) {
              await testCharacteristic.write(data, withoutResponse: true);
            } else if (testCharacteristic.properties.write) {
              await testCharacteristic.write(data, withoutResponse: false);
            } else {
              // Skip this characteristic if it doesn't support writes
              continue;
            }
            messagesReceived++; // For GATT, count as received since operation succeeded
          } catch (e) {
            debugPrint('GATT write failed: $e');
            // Continue trying other messages
          }
        }
        
        messagesSent++;
        totalBytes += _messageSize;
        
        // Small delay to prevent overwhelming the connection
        await Future.delayed(const Duration(milliseconds: 10));
        
      } catch (e) {
        debugPrint('Error sending message: $e');
        break;
      }
    }
    
    stopwatch.stop();
    subscription?.cancel();
    
    // Wait a bit for remaining responses
    await Future.delayed(const Duration(seconds: 1));
    
    results.messagesSent = messagesSent;
    results.messagesReceived = messagesReceived;
    results.totalBytes = totalBytes;
    results.durationMs = stopwatch.elapsedMilliseconds;
    results.throughputBytesPerSecond = (totalBytes * 1000) / stopwatch.elapsedMilliseconds;
    results.throughputMessagesPerSecond = (messagesSent * 1000) / stopwatch.elapsedMilliseconds;
    results.successRate = messagesReceived / messagesSent;
    
    setState(() {
      if (protocol == 'L2CAP') {
        _l2capResults = results;
      } else {
        _gattResults = results;
      }
      _testing = false;
      _currentTest = '';
    });
  }
  
  Future<void> _runLatencyTest(String protocol) async {
    setState(() {
      _testing = true;
      _currentTest = '$protocol Latency Test';
    });
    
    final latencies = <int>[];
    const testMessage = 'LATENCY_TEST';
    
    if (protocol == 'L2CAP' && _l2capConnected) {
      // Subscribe to responses
      late StreamSubscription<String> subscription;
      final responseCompleter = Completer<void>();
      
      subscription = _l2capService.messageStream.listen((message) {
        if (message.startsWith('ECHO: LATENCY_TEST')) {
          responseCompleter.complete();
        }
      });
      
      // Run multiple latency tests
      for (int i = 0; i < 10; i++) {
        final stopwatch = Stopwatch()..start();
        
        await _l2capService.sendMessage(testMessage);
        
        try {
          await responseCompleter.future.timeout(const Duration(seconds: 5));
          stopwatch.stop();
          latencies.add(stopwatch.elapsedMilliseconds);
        } catch (e) {
          debugPrint('Timeout waiting for response: $e');
        }
        
        await Future.delayed(const Duration(milliseconds: 100));
      }
      
      subscription.cancel();
    }
    
    // Calculate latency statistics
    if (latencies.isNotEmpty) {
      latencies.sort();
      final results = _l2capResults ?? TestResults();
      results.minLatencyMs = latencies.first;
      results.maxLatencyMs = latencies.last;
      results.avgLatencyMs = latencies.reduce((a, b) => a + b) / latencies.length;
      results.medianLatencyMs = latencies[latencies.length ~/ 2].toDouble();
      
      setState(() {
        _l2capResults = results;
      });
    }
    
    setState(() {
      _testing = false;
      _currentTest = '';
    });
  }
  
  @override
  void dispose() {
    _l2capService.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Performance Test'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Connection Status
            _buildConnectionStatus(),
            const SizedBox(height: 20),
            
            // Test Parameters
            _buildTestParameters(),
            const SizedBox(height: 20),
            
            // Test Controls
            _buildTestControls(),
            const SizedBox(height: 20),
            
            // Test Results
            _buildTestResults(),
          ],
        ),
      ),
    );
  }
  
  Widget _buildConnectionStatus() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Connection Status', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  _gattConnected ? Icons.check_circle : Icons.error,
                  color: _gattConnected ? Colors.green : Colors.red,
                ),
                const SizedBox(width: 8),
                Text('GATT: ${_gattConnected ? "Connected" : "Disconnected"}'),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(
                  _l2capConnected ? Icons.check_circle : Icons.error,
                  color: _l2capConnected ? Colors.green : Colors.red,
                ),
                const SizedBox(width: 8),
                Text('L2CAP: ${_l2capConnected ? "Connected" : "Disconnected"}'),
                if (_psm != null) Text(' (PSM: 0x${_psm!.toRadixString(16)})'),
              ],
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildTestParameters() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Test Parameters', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Message Size: '),
                SizedBox(
                  width: 80,
                  child: TextFormField(
                    initialValue: _messageSize.toString(),
                    keyboardType: TextInputType.number,
                    onChanged: (value) {
                      _messageSize = int.tryParse(value) ?? _messageSize;
                    },
                  ),
                ),
                const Text(' bytes'),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Message Count: '),
                SizedBox(
                  width: 80,
                  child: TextFormField(
                    initialValue: _messageCount.toString(),
                    keyboardType: TextInputType.number,
                    onChanged: (value) {
                      _messageCount = int.tryParse(value) ?? _messageCount;
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Test Duration: '),
                SizedBox(
                  width: 80,
                  child: TextFormField(
                    initialValue: _testDuration.toString(),
                    keyboardType: TextInputType.number,
                    onChanged: (value) {
                      _testDuration = int.tryParse(value) ?? _testDuration;
                    },
                  ),
                ),
                const Text(' seconds'),
              ],
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildTestControls() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Test Controls', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (_testing) 
              Text('Running: $_currentTest', style: const TextStyle(fontStyle: FontStyle.italic)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                ElevatedButton(
                  onPressed: _testing || !_l2capConnected ? null : () => _runThroughputTest('L2CAP'),
                  child: const Text('L2CAP Throughput'),
                ),
                ElevatedButton(
                  onPressed: _testing || !_l2capConnected ? null : () => _runLatencyTest('L2CAP'),
                  child: const Text('L2CAP Latency'),
                ),
                ElevatedButton(
                  onPressed: _testing || !_gattConnected ? null : () => _runThroughputTest('GATT'),
                  child: const Text('GATT Throughput'),
                ),
                ElevatedButton(
                  onPressed: _testing ? null : () {
                    setState(() {
                      _l2capResults = null;
                      _gattResults = null;
                    });
                  },
                  child: const Text('Clear Results'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildTestResults() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Test Results', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _buildResultColumn('L2CAP', _l2capResults)),
                  const SizedBox(width: 16),
                  Expanded(child: _buildResultColumn('GATT', _gattResults)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildResultColumn(String title, TestResults? results) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (results != null) ...[
          Text('Messages Sent: ${results.messagesSent}'),
          Text('Messages Received: ${results.messagesReceived}'),
          Text('Success Rate: ${(results.successRate * 100).toStringAsFixed(1)}%'),
          Text('Duration: ${results.durationMs}ms'),
          Text('Throughput: ${results.throughputBytesPerSecond.toStringAsFixed(0)} B/s'),
          Text('Message Rate: ${results.throughputMessagesPerSecond.toStringAsFixed(1)} msg/s'),
          if (results.avgLatencyMs != null) ...[
            const SizedBox(height: 8),
            Text('Min Latency: ${results.minLatencyMs}ms'),
            Text('Max Latency: ${results.maxLatencyMs}ms'),
            Text('Avg Latency: ${results.avgLatencyMs!.toStringAsFixed(1)}ms'),
            Text('Median Latency: ${results.medianLatencyMs!.toStringAsFixed(1)}ms'),
          ],
        ] else ...[
          const Text('No results yet'),
        ],
      ],
    );
  }
}

class TestResults {
  int messagesSent = 0;
  int messagesReceived = 0;
  int totalBytes = 0;
  int durationMs = 0;
  double throughputBytesPerSecond = 0;
  double throughputMessagesPerSecond = 0;
  double successRate = 0;
  
  // Latency metrics
  int? minLatencyMs;
  int? maxLatencyMs;
  double? avgLatencyMs;
  double? medianLatencyMs;
}
// lib/services/l2cap_service.dart

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

class L2capService {
  static const MethodChannel _channel = MethodChannel('jarvis_app/l2cap');
  static const EventChannel _eventChannel = EventChannel('jarvis_app/l2cap_events');
  
  StreamController<String>? _messageController;
  StreamSubscription? _eventSubscription;
  
  bool _connected = false;
  String? _deviceAddress;
  int? _psm;
  
  bool get connected => _connected;
  
  /// Initialize the L2CAP service
  Future<void> init() async {
    debugPrint('🔌 [L2capService] Initializing...');
    
    // Set up event channel for incoming messages
    _messageController = StreamController<String>.broadcast();
    _eventSubscription = _eventChannel.receiveBroadcastStream().listen(
      (dynamic event) {
        if (event is Map) {
          final type = event['type'];
          final data = event['data'];
          
          switch (type) {
            case 'message':
              debugPrint('📨 [L2CAP] Received: $data');
              _messageController?.add(data as String);
              break;
            case 'connected':
              _connected = true;
              debugPrint('✅ [L2CAP] Connected');
              break;
            case 'disconnected':
              _connected = false;
              debugPrint('❌ [L2CAP] Disconnected');
              break;
            case 'error':
              debugPrint('⚠️ [L2CAP] Error: $data');
              break;
          }
        }
      },
      onError: (error) {
        debugPrint('❌ [L2CAP] Stream error: $error');
      },
    );
  }
  
  /// Connect to L2CAP channel
  Future<bool> connect(String deviceAddress, int psm) async {
    try {
      debugPrint('🔗 [L2CAP] Connecting to $deviceAddress PSM: $psm');
      
      _deviceAddress = deviceAddress;
      _psm = psm;
      
      final result = await _channel.invokeMethod<bool>('connect', {
        'address': deviceAddress,
        'psm': psm,
      });
      
      _connected = result ?? false;
      return _connected;
    } catch (e) {
      debugPrint('❌ [L2CAP] Connect error: $e');
      return false;
    }
  }
  
  /// Send text message over L2CAP
  Future<bool> sendMessage(String message) async {
    if (!_connected) {
      debugPrint('⚠️ [L2CAP] Not connected');
      return false;
    }
    
    try {
      debugPrint('📤 [L2CAP] Sending: $message');
      
      final result = await _channel.invokeMethod<bool>('sendMessage', {
        'message': message,
      });
      
      return result ?? false;
    } catch (e) {
      debugPrint('❌ [L2CAP] Send error: $e');
      return false;
    }
  }
  
  /// Send raw bytes over L2CAP
  Future<bool> sendBytes(Uint8List data) async {
    if (!_connected) {
      debugPrint('⚠️ [L2CAP] Not connected');
      return false;
    }
    
    try {
      debugPrint('📤 [L2CAP] Sending ${data.length} bytes');
      
      // Add defensive check for corrupted data
      if (data.length > 65535) {
        debugPrint('❌ [L2CAP] ERROR: Data size ${data.length} is unreasonably large!');
        debugPrint('❌ [L2CAP] First 10 bytes: ${data.take(10).toList()}');
        return false;
      }
      
      final result = await _channel.invokeMethod<bool>('sendBytes', {
        'data': data,
      });
      
      return result ?? false;
    } catch (e) {
      debugPrint('❌ [L2CAP] Send bytes error: $e');
      return false;
    }
  }
  
  /// Get message stream
  Stream<String> get messageStream => _messageController?.stream ?? const Stream.empty();
  
  /// Disconnect L2CAP channel
  Future<void> disconnect() async {
    try {
      await _channel.invokeMethod('disconnect');
      _connected = false;
      _deviceAddress = null;
      _psm = null;
    } catch (e) {
      debugPrint('❌ [L2CAP] Disconnect error: $e');
    }
  }
  
  /// Dispose resources
  void dispose() {
    _eventSubscription?.cancel();
    _messageController?.close();
    disconnect();
  }
}
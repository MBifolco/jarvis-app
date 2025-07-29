// lib/l2cap_test_screen.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'services/l2cap_service.dart';

class L2capTestScreen extends StatefulWidget {
  final BluetoothDevice device;
  
  const L2capTestScreen({
    required this.device,
    super.key,
  });
  
  @override
  State<L2capTestScreen> createState() => _L2capTestScreenState();
}

class _L2capTestScreenState extends State<L2capTestScreen> {
  final L2capService _l2capService = L2capService();
  final TextEditingController _messageController = TextEditingController();
  final List<ChatMessage> _messages = [];
  final ScrollController _scrollController = ScrollController();
  
  bool _connected = false;
  int? _psm;
  StreamSubscription<String>? _messageSubscription;
  
  @override
  void initState() {
    super.initState();
    _init();
  }
  
  Future<void> _init() async {
    // Initialize L2CAP service
    await _l2capService.init();
    
    // Subscribe to incoming messages
    _messageSubscription = _l2capService.messageStream.listen((message) {
      setState(() {
        _messages.add(ChatMessage(
          text: message,
          isMe: false,
          timestamp: DateTime.now(),
        ));
      });
      _scrollToBottom();
    });
    
    // Read PSM from GATT characteristic
    await _readPsmFromGatt();
  }
  
  Future<void> _readPsmFromGatt() async {
    try {
      // PSM characteristic UUID (matches ESP32 l2cap_psm_uuid)
      const psmUuid = '88776655-4433-2211-f0de-bc9a78563412';
      
      final services = await widget.device.discoverServices();
      
      for (final service in services) {
        for (final char in service.characteristics) {
          if (char.uuid.toString().toLowerCase() == psmUuid) {
            final value = await char.read();
            if (value.length >= 2) {
              // PSM is 16-bit little-endian
              _psm = value[0] | (value[1] << 8);
              setState(() {});
              debugPrint('Read PSM from GATT: $_psm');
              
              // Auto-connect to L2CAP
              _connectL2cap();
              return;
            }
          }
        }
      }
      
      // If PSM not found in GATT, use default
      _psm = 0x80;
      setState(() {});
      debugPrint('Using default PSM: $_psm');
    } catch (e) {
      debugPrint('Error reading PSM: $e');
      _psm = 0x80;
      setState(() {});
    }
  }
  
  Future<void> _connectL2cap() async {
    if (_psm == null) return;
    
    final success = await _l2capService.connect(
      widget.device.remoteId.toString(),
      _psm!,
    );
    
    setState(() {
      _connected = success;
    });
    
    if (success) {
      _addSystemMessage('Connected to L2CAP channel');
    } else {
      _addSystemMessage('Failed to connect to L2CAP');
    }
  }
  
  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty || !_connected) return;
    
    // Add to chat
    setState(() {
      _messages.add(ChatMessage(
        text: text,
        isMe: true,
        timestamp: DateTime.now(),
      ));
    });
    
    // Send via L2CAP
    _l2capService.sendMessage(text);
    
    // Clear input
    _messageController.clear();
    _scrollToBottom();
  }
  
  void _addSystemMessage(String text) {
    setState(() {
      _messages.add(ChatMessage(
        text: text,
        isMe: false,
        timestamp: DateTime.now(),
        isSystem: true,
      ));
    });
    _scrollToBottom();
  }
  
  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }
  
  @override
  void dispose() {
    _messageSubscription?.cancel();
    _l2capService.dispose();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('L2CAP Test'),
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
      body: Column(
        children: [
          // Connection status
          Container(
            padding: const EdgeInsets.all(16),
            color: _connected ? Colors.green.shade100 : Colors.red.shade100,
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
                const Spacer(),
                if (!_connected && _psm != null)
                  ElevatedButton(
                    onPressed: _connectL2cap,
                    child: const Text('Connect'),
                  ),
              ],
            ),
          ),
          
          // Chat messages
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final message = _messages[index];
                return _ChatBubble(message: message);
              },
            ),
          ),
          
          // Input field
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 4,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: const InputDecoration(
                      hintText: 'Type a message...',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _sendMessage(),
                    enabled: _connected,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _connected ? _sendMessage : null,
                  color: Theme.of(context).primaryColor,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ChatMessage {
  final String text;
  final bool isMe;
  final DateTime timestamp;
  final bool isSystem;
  
  ChatMessage({
    required this.text,
    required this.isMe,
    required this.timestamp,
    this.isSystem = false,
  });
}

class _ChatBubble extends StatelessWidget {
  final ChatMessage message;
  
  const _ChatBubble({required this.message});
  
  @override
  Widget build(BuildContext context) {
    if (message.isSystem) {
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.grey.shade200,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            message.text,
            style: TextStyle(
              color: Colors.grey.shade700,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      );
    }
    
    return Align(
      alignment: message.isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.7,
        ),
        decoration: BoxDecoration(
          color: message.isMe
              ? Theme.of(context).primaryColor
              : Colors.grey.shade300,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(message.isMe ? 16 : 4),
            bottomRight: Radius.circular(message.isMe ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message.text,
              style: TextStyle(
                color: message.isMe ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${message.timestamp.hour.toString().padLeft(2, '0')}:${message.timestamp.minute.toString().padLeft(2, '0')}',
              style: TextStyle(
                fontSize: 11,
                color: message.isMe
                    ? Colors.white.withOpacity(0.7)
                    : Colors.black54,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
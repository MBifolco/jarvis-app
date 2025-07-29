// lib/services/transcript_service.dart

import 'dart:async';
import '../models/chat_message.dart';

class TranscriptService {
  final List<ChatMessage> _messages = [];
  final StreamController<List<ChatMessage>> _messagesController = StreamController<List<ChatMessage>>.broadcast();
  
  String? _currentPartialMessageId;
  
  List<ChatMessage> get messages => List.unmodifiable(_messages);
  Stream<List<ChatMessage>> get messagesStream => _messagesController.stream;

  String addUserMessage(String text) {
    final message = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      text: text,
      sender: MessageSender.user,
      timestamp: DateTime.now(),
    );
    _messages.add(message);
    _messagesController.add(_messages);
    return message.id;
  }

  String addPlaceholderUserMessage() {
    final message = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      text: "🎤 Transcribing...",
      sender: MessageSender.user,
      timestamp: DateTime.now(),
      isPartial: true,
    );
    _messages.add(message);
    _messagesController.add(_messages);
    return message.id;
  }

  void updateUserMessage(String messageId, String text) {
    final index = _messages.indexWhere((m) => m.id == messageId);
    if (index != -1) {
      _messages[index] = _messages[index].copyWith(
        text: text,
        isPartial: false,
      );
      _messagesController.add(_messages);
    }
  }

  void addPartialAssistantMessage(String text) {
    if (_currentPartialMessageId != null) {
      final index = _messages.indexWhere((m) => m.id == _currentPartialMessageId);
      if (index != -1) {
        _messages[index] = _messages[index].copyWith(text: text);
        _messagesController.add(_messages);
        return;
      }
    }

    _currentPartialMessageId = DateTime.now().millisecondsSinceEpoch.toString();
    final message = ChatMessage(
      id: _currentPartialMessageId!,
      text: text,
      sender: MessageSender.assistant,
      timestamp: DateTime.now(),
      isPartial: true,
    );
    _messages.add(message);
    _messagesController.add(_messages);
  }

  void finalizeAssistantMessage(String text) {
    if (_currentPartialMessageId != null) {
      final index = _messages.indexWhere((m) => m.id == _currentPartialMessageId);
      if (index != -1) {
        _messages[index] = _messages[index].copyWith(
          text: text,
          isPartial: false,
        );
        _currentPartialMessageId = null;
        _messagesController.add(_messages);
        return;
      }
    }

    final message = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      text: text,
      sender: MessageSender.assistant,
      timestamp: DateTime.now(),
    );
    _messages.add(message);
    _messagesController.add(_messages);
  }

  void clearMessages() {
    _messages.clear();
    _currentPartialMessageId = null;
    _messagesController.add(_messages);
  }

  void dispose() {
    _messagesController.close();
  }
}
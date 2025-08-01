import 'dart:collection';
import 'package:flutter/foundation.dart';

enum LogSource { app, device }
enum LogLevel { debug, info, warning, error }

class LogEntry {
  final DateTime timestamp;
  final LogSource source;
  final LogLevel level;
  final String tag;
  final String message;

  LogEntry({
    required this.timestamp,
    required this.source,
    required this.level,
    required this.tag,
    required this.message,
  });

  String get formattedTime => 
      '${timestamp.hour.toString().padLeft(2, '0')}:'
      '${timestamp.minute.toString().padLeft(2, '0')}:'
      '${timestamp.second.toString().padLeft(2, '0')}.'
      '${(timestamp.millisecond ~/ 10).toString().padLeft(2, '0')}';

  String get levelIcon {
    switch (level) {
      case LogLevel.debug: return '🐛';
      case LogLevel.info: return 'ℹ️';
      case LogLevel.warning: return '⚠️';
      case LogLevel.error: return '❌';
    }
  }
}

class LogService extends ChangeNotifier {
  static final LogService _instance = LogService._internal();
  factory LogService() => _instance;
  LogService._internal();

  final int _maxLogs = 1000;
  final Queue<LogEntry> _logs = Queue<LogEntry>();
  LogSource? _filterSource;
  LogLevel? _filterLevel;

  List<LogEntry> get logs {
    var filtered = _logs.toList();
    
    if (_filterSource != null) {
      filtered = filtered.where((log) => log.source == _filterSource).toList();
    }
    
    if (_filterLevel != null) {
      filtered = filtered.where((log) => log.level.index >= _filterLevel!.index).toList();
    }
    
    return filtered.reversed.toList(); // Most recent first
  }

  LogSource? get filterSource => _filterSource;
  LogLevel? get filterLevel => _filterLevel;

  void setSourceFilter(LogSource? source) {
    _filterSource = source;
    notifyListeners();
  }

  void setLevelFilter(LogLevel? level) {
    _filterLevel = level;
    notifyListeners();
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }

  void addLog({
    required LogSource source,
    required LogLevel level,
    required String tag,
    required String message,
  }) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      source: source,
      level: level,
      tag: tag,
      message: message,
    );

    _logs.addLast(entry);
    
    // Keep only the most recent logs
    while (_logs.length > _maxLogs) {
      _logs.removeFirst();
    }
    
    notifyListeners();
  }

  // Convenience methods for app logging
  void appDebug(String tag, String message) => 
      addLog(source: LogSource.app, level: LogLevel.debug, tag: tag, message: message);
  
  void appInfo(String tag, String message) => 
      addLog(source: LogSource.app, level: LogLevel.info, tag: tag, message: message);
  
  void appWarning(String tag, String message) => 
      addLog(source: LogSource.app, level: LogLevel.warning, tag: tag, message: message);
  
  void appError(String tag, String message) => 
      addLog(source: LogSource.app, level: LogLevel.error, tag: tag, message: message);

  // Methods for device logs (will be called when receiving logs via BLE)
  void deviceLog(String logLine) {
    // Parse ESP32 log format: "I (12345) TAG: Message"
    final match = RegExp(r'^([IWED]) \((\d+)\) ([^:]+): (.+)$').firstMatch(logLine);
    
    if (match != null) {
      final levelChar = match.group(1)!;
      final tag = match.group(3)!;
      final message = match.group(4)!;
      
      LogLevel level;
      switch (levelChar) {
        case 'D': level = LogLevel.debug; break;
        case 'I': level = LogLevel.info; break;
        case 'W': level = LogLevel.warning; break;
        case 'E': level = LogLevel.error; break;
        default: level = LogLevel.info;
      }
      
      addLog(
        source: LogSource.device,
        level: level,
        tag: tag,
        message: message,
      );
    } else {
      // Fallback for non-standard log lines
      addLog(
        source: LogSource.device,
        level: LogLevel.info,
        tag: 'DEVICE',
        message: logLine,
      );
    }
  }
}

// Global logger instance with debug print intercept
final logService = LogService();

// Override debugPrint to capture app logs
void initializeLogging() {
  final originalDebugPrint = debugPrint;
  
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) {
      // Extract tag from common patterns like "🎵 TAG: message" or "[TAG] message"
      String tag = 'APP';
      String msg = message;
      
      final emojiMatch = RegExp(r'^[^\s]+ ([A-Z_]+): (.+)$').firstMatch(message);
      final bracketMatch = RegExp(r'^\[([^\]]+)\] (.+)$').firstMatch(message);
      
      if (emojiMatch != null) {
        tag = emojiMatch.group(1)!;
        msg = emojiMatch.group(2)!;
      } else if (bracketMatch != null) {
        tag = bracketMatch.group(1)!;
        msg = bracketMatch.group(2)!;
      }
      
      // Determine log level from content
      LogLevel level = LogLevel.info;
      if (message.contains('❌') || message.contains('Error') || message.contains('error')) {
        level = LogLevel.error;
      } else if (message.contains('⚠️') || message.contains('Warning') || message.contains('warning')) {
        level = LogLevel.warning;
      } else if (message.contains('🐛') || tag.contains('DEBUG')) {
        level = LogLevel.debug;
      }
      
      logService.addLog(
        source: LogSource.app,
        level: level,
        tag: tag,
        message: msg,
      );
    }
    
    // Still print to console
    originalDebugPrint(message, wrapWidth: wrapWidth);
  };
}
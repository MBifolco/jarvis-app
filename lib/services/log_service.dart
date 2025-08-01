import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

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

  // Export logs as a string that can be shared
  String exportLogs() {
    final buffer = StringBuffer();
    buffer.writeln('=== Jarvis App Logs ===');
    buffer.writeln('Exported at: ${DateTime.now().toIso8601String()}');
    buffer.writeln('Total logs: ${_logs.length}');
    buffer.writeln('');
    
    for (final log in _logs) {
      final source = log.source == LogSource.app ? 'APP' : 'DEVICE';
      final level = log.level.toString().split('.').last.toUpperCase();
      buffer.writeln('[${log.formattedTime}] [$source] [$level] ${log.tag}: ${log.message}');
    }
    
    return buffer.toString();
  }

  // Save logs to a file in the app's documents directory
  Future<File?> saveLogsToFile() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').replaceAll('.', '-');
      final file = File('${directory.path}/jarvis_logs_$timestamp.txt');
      
      final logContent = exportLogs();
      await file.writeAsString(logContent);
      
      debugPrint('Logs saved to: ${file.path}');
      return file;
    } catch (e) {
      debugPrint('Failed to save logs: $e');
      return null;
    }
  }
  
  // Save logs to Downloads folder (Android only, requires permission)
  Future<File?> saveLogsToDownloads() async {
    try {
      // This only works on Android
      if (!Platform.isAndroid) {
        return saveLogsToFile(); // Fall back to app directory
      }
      
      final directory = Directory('/storage/emulated/0/Download');
      if (!await directory.exists()) {
        return saveLogsToFile(); // Fall back to app directory
      }
      
      // Create a more readable filename: jarvis_logs_2024-01-30_10-15-30.txt
      final now = DateTime.now();
      final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final timeStr = '${now.hour.toString().padLeft(2, '0')}-${now.minute.toString().padLeft(2, '0')}-${now.second.toString().padLeft(2, '0')}';
      final filename = 'jarvis_logs_${dateStr}_$timeStr.txt';
      final file = File('${directory.path}/$filename');
      
      final logContent = exportLogs();
      await file.writeAsString(logContent);
      
      debugPrint('Logs saved to Downloads: ${file.path}');
      return file;
    } catch (e) {
      debugPrint('Failed to save to Downloads: $e');
      return saveLogsToFile(); // Fall back to app directory
    }
  }

  // Get the path where logs are saved
  Future<String?> getLogDirectory() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      return directory.path;
    } catch (e) {
      return null;
    }
  }

  // List all saved log files
  Future<List<FileSystemEntity>> getSavedLogFiles() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final logFiles = directory
          .listSync()
          .where((file) => file.path.contains('jarvis_logs_') && file.path.endsWith('.txt'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path)); // Most recent first
      return logFiles;
    } catch (e) {
      debugPrint('Failed to list log files: $e');
      return [];
    }
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
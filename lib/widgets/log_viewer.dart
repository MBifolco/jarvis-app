import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/log_service.dart';

class LogViewer extends StatefulWidget {
  const LogViewer({super.key});

  @override
  State<LogViewer> createState() => _LogViewerState();
}

class _LogViewerState extends State<LogViewer> {
  final ScrollController _scrollController = ScrollController();
  bool _autoScroll = true;

  @override
  void initState() {
    super.initState();
    logService.addListener(_onLogsChanged);
  }

  @override
  void dispose() {
    logService.removeListener(_onLogsChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onLogsChanged() {
    if (_autoScroll && _scrollController.hasClients) {
      // Scroll to top (most recent logs)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        actions: [
          // Source filter
          PopupMenuButton<LogSource?>(
            icon: Icon(
              logService.filterSource == LogSource.app 
                  ? Icons.phone_android 
                  : logService.filterSource == LogSource.device 
                      ? Icons.memory 
                      : Icons.filter_list,
            ),
            onSelected: (source) => logService.setSourceFilter(source),
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: null,
                child: Text('All Sources'),
              ),
              const PopupMenuItem(
                value: LogSource.app,
                child: Row(
                  children: [
                    Icon(Icons.phone_android, size: 20),
                    SizedBox(width: 8),
                    Text('App Only'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: LogSource.device,
                child: Row(
                  children: [
                    Icon(Icons.memory, size: 20),
                    SizedBox(width: 8),
                    Text('Device Only'),
                  ],
                ),
              ),
            ],
          ),
          
          // Level filter
          PopupMenuButton<LogLevel?>(
            icon: const Icon(Icons.warning_amber),
            onSelected: (level) => logService.setLevelFilter(level),
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: null,
                child: Text('All Levels'),
              ),
              const PopupMenuItem(
                value: LogLevel.error,
                child: Text('Errors Only'),
              ),
              const PopupMenuItem(
                value: LogLevel.warning,
                child: Text('Warnings & Up'),
              ),
              const PopupMenuItem(
                value: LogLevel.info,
                child: Text('Info & Up'),
              ),
            ],
          ),
          
          // Auto-scroll toggle
          IconButton(
            icon: Icon(_autoScroll ? Icons.vertical_align_top : Icons.vertical_align_bottom),
            onPressed: () => setState(() => _autoScroll = !_autoScroll),
            tooltip: _autoScroll ? 'Auto-scroll ON' : 'Auto-scroll OFF',
          ),
          
          // Save logs to Downloads (Android)
          IconButton(
            icon: const Icon(Icons.download),
            onPressed: () async {
              final file = await logService.saveLogsToDownloads();
              if (context.mounted) {
                final isDownloads = file?.path.contains('/Download') ?? false;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(file != null 
                        ? isDownloads 
                            ? 'Logs saved to Downloads folder' 
                            : 'Logs saved to app documents'
                        : 'Failed to save logs'),
                    duration: const Duration(seconds: 3),
                    action: file != null && isDownloads ? SnackBarAction(
                      label: 'View',
                      onPressed: () {
                        showDialog(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Log File Saved'),
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('File saved to Downloads folder:'),
                                const SizedBox(height: 8),
                                SelectableText(
                                  file.path.split('/').last,
                                  style: const TextStyle(fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('OK'),
                              ),
                            ],
                          ),
                        );
                      },
                    ) : null,
                  ),
                );
              }
            },
            tooltip: 'Save to Downloads',
          ),
          
          // Export/Share logs
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: () async {
              final logs = logService.exportLogs();
              await Clipboard.setData(ClipboardData(text: logs));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('All logs copied to clipboard'),
                    duration: Duration(seconds: 2),
                  ),
                );
              }
            },
            tooltip: 'Copy all logs',
          ),
          
          // Clear logs
          IconButton(
            icon: const Icon(Icons.clear_all),
            onPressed: () => logService.clearLogs(),
            tooltip: 'Clear logs',
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: logService,
        builder: (context, child) {
          final logs = logService.logs;
          
          if (logs.isEmpty) {
            return const Center(
              child: Text(
                'No logs yet',
                style: TextStyle(color: Colors.grey),
              ),
            );
          }
          
          return ListView.builder(
            controller: _scrollController,
            itemCount: logs.length,
            itemBuilder: (context, index) {
              final log = logs[index];
              
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: InkWell(
                  onLongPress: () {
                    // Copy log to clipboard
                    final text = '${log.formattedTime} [${log.tag}] ${log.message}';
                    Clipboard.setData(ClipboardData(text: text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Log copied to clipboard'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Source icon
                        Icon(
                          log.source == LogSource.app 
                              ? Icons.phone_android 
                              : Icons.memory,
                          size: 16,
                          color: log.source == LogSource.app 
                              ? Colors.blue 
                              : Colors.green,
                        ),
                        const SizedBox(width: 4),
                        
                        // Level icon
                        Text(log.levelIcon, style: const TextStyle(fontSize: 14)),
                        const SizedBox(width: 4),
                        
                        // Time
                        Text(
                          log.formattedTime,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                            fontFamily: 'monospace',
                          ),
                        ),
                        const SizedBox(width: 8),
                        
                        // Tag
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: _getTagColor(log.tag).withOpacity(0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            log.tag,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: _getTagColor(log.tag),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        
                        // Message
                        Expanded(
                          child: Text(
                            log.message,
                            style: const TextStyle(fontSize: 13),
                            softWrap: true,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
  
  Color _getTagColor(String tag) {
    // Generate consistent color from tag
    final hash = tag.hashCode;
    return HSLColor.fromAHSL(
      1.0,
      (hash % 360).toDouble(),
      0.7,
      0.5,
    ).toColor();
  }
}
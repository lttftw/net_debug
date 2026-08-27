import 'package:flutter/foundation.dart';

/// 全局日志来源
enum GlobalLogSource { tcp, mqtt, broker, app }

/// 全局日志条目
class GlobalLogEntry {
  final DateTime time;
  final GlobalLogSource source;
  final String kind;
  final String message;
  final String? topic;

  const GlobalLogEntry({
    required this.time,
    required this.source,
    required this.kind,
    required this.message,
    this.topic,
  });

  String get sourceLabel {
    switch (source) {
      case GlobalLogSource.tcp:
        return 'TCP';
      case GlobalLogSource.mqtt:
        return 'MQTT';
      case GlobalLogSource.broker:
        return 'Broker';
      case GlobalLogSource.app:
        return '应用';
    }
  }
}

/// 全局日志服务：收集来自各模块的日志，提供统一的查看入口
class GlobalLogService extends ChangeNotifier {
  static const int _maxLogs = 5000;
  final List<GlobalLogEntry> _logs = [];

  List<GlobalLogEntry> get logs => List.unmodifiable(_logs);

  void log({
    required GlobalLogSource source,
    required String kind,
    required String message,
    String? topic,
  }) {
    _logs.add(GlobalLogEntry(
      time: DateTime.now(),
      source: source,
      kind: kind,
      message: message,
      topic: topic,
    ));
    if (_logs.length > _maxLogs) {
      _logs.removeRange(0, _logs.length - _maxLogs);
    }
    notifyListeners();
  }

  void clear() {
    _logs.clear();
    notifyListeners();
  }
}
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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

  Map<String, dynamic> toJson() => {
    't': time.toIso8601String(),
    's': source.name,
    'k': kind,
    'm': message,
    if (topic != null) 'top': topic,
  };

  factory GlobalLogEntry.fromJson(Map<String, dynamic> json) {
    final sourceName = json['s'] as String?;
    GlobalLogSource source = GlobalLogSource.app;
    for (final s in GlobalLogSource.values) {
      if (s.name == sourceName) {
        source = s;
        break;
      }
    }
    return GlobalLogEntry(
      time: DateTime.tryParse(json['t'] as String? ?? '') ?? DateTime.now(),
      source: source,
      kind: json['k'] as String? ?? 'system',
      message: json['m'] as String? ?? '',
      topic: json['top'] as String?,
    );
  }
}

/// 全局日志服务：收集来自各模块的日志，提供统一的查看入口。
/// 日志持久化到支持目录下的 `global_log.jsonl`，退出 App 后仍可恢复最近记录。
///
/// 性能策略：写入采用「内存缓冲 + 定时/攒批批量落盘」，
/// 避免逐条写盘带来的磁盘 IO 压力；一旦缓冲量超过 [maxLogs] 的日志
/// 只保留最新一笔，文件同样定期压缩以平衡体积。
class GlobalLogService extends ChangeNotifier {
  static const int _maxLogs = 5000;

  /// 批量落盘的触发条件：间隔时间
  static const Duration _flushInterval = Duration(milliseconds: 500);

  /// 批量落盘的触发条件：缓冲条数
  static const int _batchSize = 200;

  static const String _fileName = 'global_log.jsonl';
  final List<GlobalLogEntry> _logs = [];

  /// 等待落盘的缓冲日志
  final List<GlobalLogEntry> _buffer = [];

  Timer? _flushTimer;

  /// 磁盘写入串行队列，保证追加/压缩/清空按顺序执行，避免数据交错损坏
  Future<void> _writeQueue = Future.value();

  /// 已写入磁盘的行数（用于触发文件压缩）
  int _persistedLines = 0;

  List<GlobalLogEntry> get logs => List.unmodifiable(_logs);

  void log({
    required GlobalLogSource source,
    required String kind,
    required String message,
    String? topic,
  }) {
    final entry = GlobalLogEntry(
      time: DateTime.now(),
      source: source,
      kind: kind,
      message: message,
      topic: topic,
    );
    _logs.add(entry);
    if (_logs.length > _maxLogs) {
      _logs.removeRange(0, _logs.length - _maxLogs);
    }
    _buffer.add(entry);
    _scheduleFlush();
    notifyListeners();
  }

  /// 从磁盘加载历史日志（应用启动时调用）
  Future<void> load() async {
    final completer = Completer<void>();
    _writeQueue = _writeQueue
        .then((_) async {
          try {
            final file = await _file();
            if (!(await file.exists())) return;
            final lines = await file.readAsLines();
            _logs.clear();
            for (final line in lines) {
              if (line.trim().isEmpty) continue;
              try {
                _logs.add(
                  GlobalLogEntry.fromJson(
                    jsonDecode(line) as Map<String, dynamic>,
                  ),
                );
              } catch (_) {
                // 忽略损坏行
              }
            }
            _persistedLines = lines.length;
            if (_logs.length > _maxLogs) {
              _logs.removeRange(0, _logs.length - _maxLogs);
            }
          } catch (_) {
            // 读取失败时保持内存为空
          }
        })
        .then((_) {
          if (!completer.isCompleted) completer.complete();
        })
        .catchError((Object _) {
          if (!completer.isCompleted) completer.complete();
        });
    await completer.future;
    notifyListeners();
  }

  /// 清空日志（内存 + 缓冲 + 磁盘）
  Future<void> clear() {
    _logs.clear();
    _buffer.clear();
    _flushTimer?.cancel();
    _flushTimer = null;
    notifyListeners();
    final past = _writeQueue;
    _writeQueue = past
        .then((_) async {
          final file = await _file();
          if (await file.exists()) await file.delete();
          _persistedLines = 0;
        })
        .catchError((Object _) {});
    return _writeQueue;
  }

  /// 把缓冲日志批量写入磁盘（尽力而为，异常静默吞掉）
  Future<void> flush() {
    if (_buffer.isEmpty) return Future.value();
    final batch = List<GlobalLogEntry>.from(_buffer);
    _buffer.clear();
    _flushTimer?.cancel();
    _flushTimer = null;
    final past = _writeQueue;
    _writeQueue = past
        .then((_) => _writeBatch(batch))
        .catchError((Object _) {});
    return _writeQueue;
  }

  /// 满足「攒够批量」或「间隔时间到」条件之一即触发落盘
  void _scheduleFlush() {
    if (_buffer.isEmpty) return;
    if (_buffer.length >= _batchSize) {
      _flushTimer?.cancel();
      _flushTimer = null;
      unawaited(flush());
      return;
    }
    _flushTimer ??= Timer(_flushInterval, () {
      _flushTimer = null;
      unawaited(flush());
    });
  }

  /// 将一批条目一次性追加写入文本，随后在超限时压缩
  Future<void> _writeBatch(List<GlobalLogEntry> batch) async {
    final file = await _file();
    final sb = StringBuffer();
    for (final e in batch) {
      sb.writeln(jsonEncode(e.toJson()));
    }
    await file.writeAsString(sb.toString(), mode: FileMode.append);
    _persistedLines += batch.length;
    if (_persistedLines >= _maxLogs * 2) {
      final lines = await file.readAsLines();
      if (lines.length > _maxLogs) {
        final keep = lines.sublist(lines.length - _maxLogs);
        await file.writeAsString('${keep.join('\n')}\n', flush: true);
      }
      _persistedLines = _maxLogs;
    }
  }

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, _fileName));
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    _flushTimer = null;
    // 尽力把剩余缓冲落盘再销毁
    unawaited(flush());
    super.dispose();
  }
}

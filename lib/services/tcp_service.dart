import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/command_preset.dart';
import 'global_log_service.dart';

/// TCP 连接状态
enum TcpStatus { disconnected, connecting, connected }

/// 日志类型
enum LogKind { tx, rx, system, error }

/// 一条日志记录
class LogEntry {
  final DateTime time;
  final LogKind kind;
  final String message;

  LogEntry(this.time, this.kind, this.message);
}

/// 一条命令历史记录（含发送时间戳）
class HistoryEntry {
  final String command;
  final DateTime time;

  const HistoryEntry(this.command, this.time);

  Map<String, dynamic> toJson() => {
    'cmd': command,
    'time': time.toIso8601String(),
  };

  factory HistoryEntry.fromJson(Map<String, dynamic> json) => HistoryEntry(
    json['cmd'] as String,
    DateTime.tryParse(json['time'] as String? ?? '') ?? DateTime.now(),
  );
}

/// 一条连接配置历史
class ConnectionProfile {
  final String host;
  final int port;

  const ConnectionProfile(this.host, this.port);

  Map<String, dynamic> toJson() => {'host': host, 'port': port};

  factory ConnectionProfile.fromJson(Map<String, dynamic> json) =>
      ConnectionProfile(json['host'] as String, json['port'] as int);

  String get label => '$host:$port';
}

/// OTA 进度信息
class OtaProgress {
  final int written;
  final int total;
  final int percent;
  final String state;

  const OtaProgress(this.written, this.total, this.percent, this.state);
}

/// TCP 连接管理：负责连接、按行解析响应、发送指令、日志、历史与 OTA。
class TcpService extends ChangeNotifier {
  static const _kMaxLogs = 2000;
  static const _kMaxHistory = 100;
  static const _kMaxConnections = 10;

  Socket? _socket;
  TcpStatus _status = TcpStatus.disconnected;
  final List<LogEntry> _logs = [];
  final List<HistoryEntry> _history = [];
  final List<ConnectionProfile> _connections = [];
  final List<QuickCommand> _quickCommands = [];
  final List<CommandPreset> _presets = [];
  bool _presetsLoaded = false;

  /// 是否启用 OTA 固件升级扩展（设备特定协议，默认关闭）
  bool _otaEnabled = false;
  String _buffer = '';
  final bool _autoScroll = true;

  /// 同步命令等待机制：发送命令后等待下一行响应
  Completer<String>? _pending;
  Timer? _pendingTimer;

  /// 发送队列：串行化所有发送，避免多条指令同时到达设备端
  /// （设备端为单客户端长连接，缓冲区仅 2304 字节，并发发送会触发
  ///  too_large 或响应错配）
  final List<(Completer<void>, Future<void> Function())> _sendQueue = [];
  bool _draining = false;

  /// 自动重连：记录上次连接参数，收到 RST 后自动重连（限制次数避免循环）
  String? _lastHost;
  int? _lastPort;
  bool _reconnecting = false;
  int _reconnectAttempts = 0;
  static const _kMaxReconnectAttempts = 3;

  Database? _db;

  GlobalLogService? _globalLog;

  /// 初始化全局日志连接（在 load* 方法之前调用）
  void init({GlobalLogService? globalLog}) {
    _globalLog = globalLog;
  }

  TcpStatus get status => _status;
  List<LogEntry> get logs => List.unmodifiable(_logs);
  List<HistoryEntry> get history => List.unmodifiable(_history);
  List<ConnectionProfile> get connections => List.unmodifiable(_connections);
  List<QuickCommand> get quickCommands => List.unmodifiable(_quickCommands);

  /// 内置指令预设（来自 JSON 资源）
  List<CommandPreset> get presets => List.unmodifiable(_presets);

  /// 是否启用 OTA 固件升级扩展
  bool get otaEnabled => _otaEnabled;

  /// 是否有被隐藏的内置预设（用于显示"恢复全部"入口）
  bool get hasHiddenBuiltins {
    // 内置预设总数 - 当前显示的内置预设数 > 0 表示有隐藏
    int builtinShown = _quickCommands.where((q) => q.isBuiltin || q.isOverride).length;
    return builtinShown < _presets.length;
  }
  bool get autoScroll => _autoScroll;
  bool get busy => _pending != null;

  /// 旧版 JSON 数据目录（仅用于迁移）
  String get _legacyBaseDir {
    if (Platform.isWindows) {
      return Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
    }
    if (Platform.isAndroid) {
      return '${Directory.systemTemp.path}/tcp_flutter';
    }
    return Directory.systemTemp.path;
  }

  /// 初始化 sqlite 数据库（应用支持目录，覆盖安装后数据保留）
  Future<void> _initDb() async {
    if (_db != null) return;
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, 'tcp_flutter.db');
    _db = await openDatabase(
      path,
      version: 3,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE command_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            cmd TEXT NOT NULL,
            time TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE connection_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            host TEXT NOT NULL,
            port INTEGER NOT NULL,
            time TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE quick_commands (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            label TEXT NOT NULL,
            command TEXT NOT NULL,
            hint TEXT,
            override_index INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE quick_command_order (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            sort_order INTEGER NOT NULL,
            is_builtin INTEGER NOT NULL DEFAULT 0,
            builtin_index INTEGER,
            ref_id INTEGER
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('''
            CREATE TABLE quick_commands (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              label TEXT NOT NULL,
              command TEXT NOT NULL,
              hint TEXT,
              override_index INTEGER
            )
          ''');
        }
        if (oldVersion < 3) {
          await db.execute('''
            CREATE TABLE quick_command_order (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              sort_order INTEGER NOT NULL,
              is_builtin INTEGER NOT NULL DEFAULT 0,
              builtin_index INTEGER,
              ref_id INTEGER
            )
          ''');
        }
      },
    );
  }

  /// 从 sqlite 加载历史指令与连接配置，并迁移旧版 JSON 数据
  Future<void> loadHistory() async {
    try {
      await _initDb();
      final db = _db!;
      final rows = await db.query(
        'command_history',
        columns: ['cmd', 'time'],
        orderBy: 'id DESC',
        limit: _kMaxHistory,
      );
      for (final row in rows) {
        _history.add(
          HistoryEntry(
            row['cmd'] as String,
            DateTime.tryParse(row['time'] as String? ?? '') ?? DateTime.now(),
          ),
        );
      }
      final conns = await db.query(
        'connection_history',
        columns: ['host', 'port'],
        orderBy: 'id DESC',
        limit: _kMaxConnections,
      );
      for (final row in conns) {
        _connections.add(
          ConnectionProfile(row['host'] as String, row['port'] as int),
        );
      }
      await _migrateLegacyFiles();
    } catch (_) {
      // 忽略存储错误
    }
    notifyListeners();
  }

  /// 加载工具配置（如 OTA 扩展开关）
  Future<void> loadSettings() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File(p.join(dir.path, 'tcp_settings.json'));
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString());
        _otaEnabled = (json['ota_enabled'] as bool?) ?? false;
      }
    } catch (_) {
      // 忽略存储错误
    }
    notifyListeners();
  }

  /// 设置 OTA 固件升级扩展开关（持久化）
  Future<void> setOtaEnabled(bool value) async {
    _otaEnabled = value;
    notifyListeners();
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File(p.join(dir.path, 'tcp_settings.json'));
      await file.writeAsString(jsonEncode({'ota_enabled': _otaEnabled}));
    } catch (_) {
      // 忽略存储错误
    }
  }

  /// 迁移旧版 JSON 文件数据到 sqlite（仅当数据库为空时）
  Future<void> _migrateLegacyFiles() async {
    final db = _db;
    if (db == null) return;
    final sep = Platform.pathSeparator;
    final historyFile = File('$_legacyBaseDir${sep}tcp_flutter_history.json');
    final configFile = File('$_legacyBaseDir${sep}tcp_flutter_config.json');

    if (await historyFile.exists()) {
      final count = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM command_history'),
      )!;
      if (count == 0) {
        try {
          final list =
              jsonDecode(await historyFile.readAsString()) as List<dynamic>;
          for (final item in list) {
            if (item is String) {
              await db.insert('command_history', {
                'cmd': item,
                'time': DateTime.now().toIso8601String(),
              });
            } else if (item is Map) {
              try {
                final e = HistoryEntry.fromJson(item.cast<String, dynamic>());
                await db.insert('command_history', {
                  'cmd': e.command,
                  'time': e.time.toIso8601String(),
                });
              } catch (_) {}
            }
          }
          _history.clear();
          final rows = await db.query(
            'command_history',
            columns: ['cmd', 'time'],
            orderBy: 'id DESC',
            limit: _kMaxHistory,
          );
          for (final row in rows) {
            _history.add(
              HistoryEntry(
                row['cmd'] as String,
                DateTime.tryParse(row['time'] as String? ?? '') ??
                    DateTime.now(),
              ),
            );
          }
        } catch (_) {}
      }
      try {
        await historyFile.delete();
      } catch (_) {}
    }

    if (await configFile.exists()) {
      final count = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM connection_history'),
      )!;
      if (count == 0) {
        try {
          final list =
              jsonDecode(await configFile.readAsString()) as List<dynamic>;
          for (final item in list) {
            try {
              final c = ConnectionProfile.fromJson(
                (item as Map).cast<String, dynamic>(),
              );
              await db.insert('connection_history', {
                'host': c.host,
                'port': c.port,
                'time': DateTime.now().toIso8601String(),
              });
            } catch (_) {}
          }
          _connections.clear();
          final rows = await db.query(
            'connection_history',
            columns: ['host', 'port'],
            orderBy: 'id DESC',
            limit: _kMaxConnections,
          );
          for (final row in rows) {
            _connections.add(
              ConnectionProfile(row['host'] as String, row['port'] as int),
            );
          }
        } catch (_) {}
      }
      try {
        await configFile.delete();
      } catch (_) {}
    }
  }

  /// 连接设备
  Future<void> connect(String host, int port) async {
    if (_status == TcpStatus.connecting || _status == TcpStatus.connected) {
      await disconnect();
    }
    _lastHost = host;
    _lastPort = port;
    _setStatus(TcpStatus.connecting);
    _addLog(LogKind.system, '正在连接 $host:$port ...');
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 5),
      );
      socket.setOption(SocketOption.tcpNoDelay, true);
      _socket = socket;
      _buffer = '';
      socket.listen(
        (data) => _onData(socket, data),
        onError: (Object error) => _onError(socket, error),
        onDone: () => _onDone(socket),
        cancelOnError: true,
      );
      _setStatus(TcpStatus.connected);
      _addLog(LogKind.system, '已连接 $host:$port');
      _saveConnection(host, port);
    } catch (e) {
      _setStatus(TcpStatus.disconnected);
      _addLog(LogKind.error, '连接失败: $e');
    }
  }

  /// 断开连接
  Future<void> disconnect() async {
    _reconnectAttempts = 0;
    _failPending('连接已断开');
    final s = _socket;
    _socket = null;
    if (s != null) {
      try {
        await s.close();
      } catch (_) {}
    }
    _setStatus(TcpStatus.disconnected);
    _addLog(LogKind.system, '已断开连接');
  }

  /// 发送一条指令（自动补 \n，串行化发送并等待短超时响应）
  /// 发送一条指令（短超时，不阻塞 UI）。
  /// [recordHistory] 为 false 时不写入历史（供 OTA 等内部指令使用）。
  Future<bool> send(String text, {bool recordHistory = true}) async {
    final s = _socket;
    if (s == null || _status != TcpStatus.connected) {
      _addLog(LogKind.error, '未连接，无法发送');
      return false;
    }
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    if (utf8.encode(trimmed).length + 1 > 2304) {
      _addLog(LogKind.error, '指令超过设备 2304 字节限制，已取消发送');
      return false;
    }
    if (!_isValidJsonObject(trimmed)) {
      _addLog(LogKind.error, '指令必须是 JSON 对象（以 { 开头），已取消发送');
      return false;
    }
    try {
      await _enqueue(() => _sendAndWait(trimmed, recordHistory: recordHistory));
      return true;
    } catch (e) {
      _addLog(LogKind.error, '发送失败: $e');
      return false;
    }
  }

  /// 发送一条指令并等待下一行响应（同步命令，用于 OTA 等需要确认的场景）
  Future<Map<String, dynamic>> sendCommand(
    String cmd, {
    Duration timeout = const Duration(seconds: 30),
    bool recordHistory = true,
  }) async {
    final s = _socket;
    if (s == null || _status != TcpStatus.connected) {
      throw Exception('未连接，无法发送');
    }
    final trimmed = cmd.trim();
    if (utf8.encode(trimmed).length + 1 > 2304) {
      throw Exception('指令超过设备 2304 字节限制');
    }
    if (!_isValidJsonObject(trimmed)) {
      throw Exception('指令必须是 JSON 对象（以 { 开头）');
    }
    final result = Completer<Map<String, dynamic>>();
    await _enqueue(() async {
      try {
        result.complete(await _sendCommandRaw(
          trimmed,
          timeout,
          recordHistory: recordHistory,
        ));
      } catch (e) {
        result.completeError(e);
      }
    });
    return result.future;
  }

  /// 将任务加入发送队列，串行执行（同一时间仅一条指令在途）
  Future<void> _enqueue(Future<void> Function() task) async {
    final completer = Completer<void>();
    _sendQueue.add((completer, task));
    if (!_draining) {
      _draining = true;
      _drainQueue();
    }
    await completer.future;
  }

  Future<void> _drainQueue() async {
    while (_sendQueue.isNotEmpty) {
      final (completer, task) = _sendQueue.removeAt(0);
      try {
        await task();
      } catch (_) {
        // 任务内部已处理错误
      } finally {
        if (!completer.isCompleted) completer.complete();
      }
    }
    _draining = false;
  }

  /// 发送一条指令并等待响应（短超时），超时后不报错、允许继续发送
  Future<void> _sendAndWait(String data, {bool recordHistory = true}) async {
    final s = _socket;
    if (s == null || _status != TcpStatus.connected) return;
    final completer = Completer<String>();
    _pending = completer;
    _pendingTimer = Timer(const Duration(seconds: 3), () {
      if (_pending == completer) {
        _pending = null;
        _pendingTimer = null;
        completer.completeError(TimeoutException('等待响应超时'));
      }
    });
    try {
      s.add(utf8.encode('$data\n'));
      await s.flush();
      _addLog(LogKind.tx, _prettyJson(data));
      if (recordHistory) _addToHistory(data);
      notifyListeners();
      await completer.future;
    } catch (_) {
      // 超时或连接断开，忽略
    }
  }

  /// 发送一条指令并等待下一行响应（队列内部执行）
  Future<Map<String, dynamic>> _sendCommandRaw(
    String trimmed,
    Duration timeout, {
    bool recordHistory = true,
  }) async {
    final s = _socket;
    if (s == null || _status != TcpStatus.connected) {
      throw Exception('未连接，无法发送');
    }
    final completer = Completer<String>();
    _pending = completer;
    _pendingTimer = Timer(timeout, () {
      if (_pending == completer) {
        _pending = null;
        completer.completeError(TimeoutException('等待响应超时（$timeout）'));
      }
    });
    try {
      s.add(utf8.encode('$trimmed\n'));
      await s.flush();
      _addLog(LogKind.tx, _prettyJson(trimmed));
      if (recordHistory) _addToHistory(trimmed);
      notifyListeners();
      final line = await completer.future;
      try {
        return jsonDecode(line) as Map<String, dynamic>;
      } catch (_) {
        return {'raw': line};
      }
    } catch (e) {
      _addLog(LogKind.error, '命令失败: $e');
      rethrow;
    }
  }

  /// 校验指令是否为有效的 JSON 对象
  bool _isValidJsonObject(String text) {
    try {
      return jsonDecode(text) is Map<String, dynamic>;
    } catch (_) {
      return false;
    }
  }

  /// 清空日志
  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }

  /// 添加一条系统日志（供 UI 直接调用）
  void addSystemLog(String message) {
    _addLog(LogKind.system, message);
  }

  /// 清空指令历史（内存 + 数据库）
  Future<void> clearHistory() async {
    _history.clear();
    final db = _db;
    if (db != null) {
      try {
        await db.delete('command_history');
      } catch (_) {}
    }
    notifyListeners();
  }

  /// 清空连接历史（内存 + 数据库）
  Future<void> clearConnections() async {
    _connections.clear();
    final db = _db;
    if (db != null) {
      try {
        await db.delete('connection_history');
      } catch (_) {}
    }
    notifyListeners();
  }

  // ---------- OTA ----------

  /// 查询 OTA 状态
  Future<Map<String, dynamic>> otaStatus() async {
    return sendCommand(
      jsonEncode({
        'ota': {'op': 'status'},
      }),
      recordHistory: false,
    );
  }

  /// 上传固件：begin -> chunk 循环 -> finish，带进度回调
  Future<void> otaUpload(
    Uint8List data, {
    void Function(OtaProgress)? onProgress,
  }) async {
    final size = data.length;
    if (size == 0) throw Exception('固件文件为空');
    _addLog(LogKind.system, 'OTA 开始，固件大小 $size 字节');

    // 查询状态，支持续传
    final status = await otaStatus();
    int offset = 0;
    final state = status['state'];
    final written = (status['written'] as num?)?.toInt() ?? 0;
    final total = (status['total'] as num?)?.toInt() ?? 0;
    if (state == 'receiving' && total == size && written <= size) {
      offset = written;
      _addLog(LogKind.system, '检测到已有接收会话，从 $offset 字节续传');
    } else {
      final begin = await sendCommand(
        jsonEncode({
          'ota': {'op': 'begin', 'size': size},
        }),
        timeout: const Duration(seconds: 120),
        recordHistory: false,
      );
      if (begin['ok'] != true) {
        throw Exception('OTA begin 失败: ${jsonEncode(begin)}');
      }
      offset = 0;
    }

    onProgress?.call(
      OtaProgress(offset, size, _percent(offset, size), 'uploading'),
    );
    while (offset < size) {
      final end = math.min(offset + 1024, size);
      final chunk = data.sublist(offset, end);
      final hex = chunk.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final resp = await sendCommand(
        jsonEncode({
          'ota': {'op': 'chunk', 'offset': offset, 'data': hex},
        }),
        timeout: const Duration(seconds: 60),
        recordHistory: false,
      );
      if (resp['ok'] != true) {
        throw Exception('OTA chunk 失败: ${jsonEncode(resp)}');
      }
      offset = end;
      onProgress?.call(
        OtaProgress(offset, size, _percent(offset, size), 'uploading'),
      );
    }

    final finish = await sendCommand(
      jsonEncode({
        'ota': {'op': 'finish'},
      }),
      timeout: const Duration(seconds: 120),
      recordHistory: false,
    );
    if (finish['ok'] != true) {
      throw Exception('OTA finish 失败: ${jsonEncode(finish)}');
    }
    _addLog(LogKind.system, 'OTA 固件上传并校验成功');
    onProgress?.call(OtaProgress(size, size, 100, 'ready'));
  }

  /// 应用固件并重启
  Future<Map<String, dynamic>> otaApply() async {
    return sendCommand(
      jsonEncode({
        'ota': {'op': 'apply'},
      }),
      timeout: const Duration(seconds: 30),
      recordHistory: false,
    );
  }

  /// 中止 OTA
  Future<Map<String, dynamic>> otaAbort() async {
    return sendCommand(
      jsonEncode({
        'ota': {'op': 'abort'},
      }),
      recordHistory: false,
    );
  }

  int _percent(int written, int total) =>
      total == 0 ? 0 : (written * 100 / total).floor();

  // ---------- 内部实现 ----------

  void _onData(Socket source, Uint8List data) {
    if (!identical(_socket, source)) return;
    _buffer += utf8.decode(data, allowMalformed: true);
    while (true) {
      final idx = _buffer.indexOf('\n');
      if (idx < 0) break;
      final line = _buffer.substring(0, idx).trim();
      _buffer = _buffer.substring(idx + 1);
      if (line.isEmpty) continue;
      _addLog(LogKind.rx, _prettyJson(line));
      final p = _pending;
      if (p != null) {
        _pending = null;
        _pendingTimer?.cancel();
        p.complete(line);
      }
    }
  }

  void _onError(Socket source, Object error) {
    if (!identical(_socket, source)) return;
    _socket = null;
    _buffer = '';
    source.destroy();
    _failPending('接收错误: $error');
    _setStatus(TcpStatus.disconnected);
    _addLog(LogKind.error, '接收错误: $error');
    _scheduleReconnect();
  }

  /// 连接异常（如 Connection reset）后自动重连，最多重试 3 次
  void _scheduleReconnect() {
    final host = _lastHost;
    final port = _lastPort;
    if (host == null || port == null) return;
    if (_reconnecting) return;
    if (_reconnectAttempts >= _kMaxReconnectAttempts) {
      _addLog(LogKind.error, '自动重连失败次数过多，请手动重连');
      return;
    }
    _reconnecting = true;
    _reconnectAttempts++;
    _addLog(LogKind.system, '连接异常，2 秒后自动重连（第 $_reconnectAttempts 次）...');
    Timer(const Duration(seconds: 2), () async {
      _reconnecting = false;
      if (_status == TcpStatus.connected) return;
      await connect(host, port);
      if (_status == TcpStatus.connected) {
        _reconnectAttempts = 0;
      }
    });
  }

  void _onDone(Socket source) {
    if (!identical(_socket, source)) return;
    _socket = null;
    _buffer = '';
    _failPending('连接已关闭');
    _setStatus(TcpStatus.disconnected);
    _addLog(LogKind.system, '连接已关闭');
    _scheduleReconnect();
  }

  void _failPending(String reason) {
    final p = _pending;
    if (p != null) {
      _pending = null;
      _pendingTimer?.cancel();
      p.completeError(Exception(reason));
    }
  }

  /// 尝试美化 JSON，失败则原样返回
  String _prettyJson(String text) {
    try {
      final obj = jsonDecode(text);
      return const JsonEncoder.withIndent('  ').convert(obj);
    } catch (_) {
      return text;
    }
  }

  void _addToHistory(String cmd) {
    _history.removeWhere((e) => e.command == cmd);
    _history.insert(0, HistoryEntry(cmd, DateTime.now()));
    if (_history.length > _kMaxHistory) {
      _history.removeRange(_kMaxHistory, _history.length);
    }
    _saveHistory(cmd);
  }

  Future<void> _saveHistory(String cmd) async {
    final db = _db;
    if (db == null) return;
    try {
      await db.transaction((txn) async {
        await txn.delete('command_history', where: 'cmd = ?', whereArgs: [cmd]);
        await txn.insert('command_history', {
          'cmd': cmd,
          'time': DateTime.now().toIso8601String(),
        });
        await txn.rawDelete(
          'DELETE FROM command_history WHERE id NOT IN '
          '(SELECT id FROM command_history ORDER BY id DESC LIMIT ?)',
          [_kMaxHistory],
        );
      });
    } catch (_) {
      // 忽略存储错误
    }
  }

  void _saveConnection(String host, int port) {
    _connections.removeWhere((c) => c.host == host && c.port == port);
    _connections.insert(0, ConnectionProfile(host, port));
    if (_connections.length > _kMaxConnections) {
      _connections.removeRange(_kMaxConnections, _connections.length);
    }
    _saveConfig(host, port);
    notifyListeners();
  }

  Future<void> _saveConfig(String host, int port) async {
    final db = _db;
    if (db == null) return;
    try {
      await db.transaction((txn) async {
        await txn.delete(
          'connection_history',
          where: 'host = ? AND port = ?',
          whereArgs: [host, port],
        );
        await txn.insert('connection_history', {
          'host': host,
          'port': port,
          'time': DateTime.now().toIso8601String(),
        });
        await txn.rawDelete(
          'DELETE FROM connection_history WHERE id NOT IN '
          '(SELECT id FROM connection_history ORDER BY id DESC LIMIT ?)',
          [_kMaxConnections],
        );
      });
    } catch (_) {
      // 忽略存储错误
    }
  }

  /// 从内置 JSON 资源加载指令预设（幂等）。
  Future<void> _loadCommandPresets() async {
    if (_presetsLoaded) return;
    _presetsLoaded = true;
    _presets
      ..clear()
      ..addAll(await loadCommandPresets());
  }

  /// 从 sqlite 加载快捷指令（内置预设 + 自定义/覆盖项）
  /// 加载快捷指令（按用户自定义排序：排序表优先，缺失项自动补到末尾）
  Future<void> loadQuickCommands() async {
    await _loadCommandPresets();
    try {
      await _initDb();
      final db = _db!;
      final rows = await db.query('quick_commands', orderBy: 'id ASC');
      await _syncQuickOrder(rows);
      final orderRows = await db.query(
        'quick_command_order',
        orderBy: 'sort_order ASC',
      );
      _rebuildQuickCommands(rows, orderRows);
    } catch (_) {
      // 忽略存储错误
    }
    notifyListeners();
  }

  /// 确保排序表存在且完整：
  /// - 首次使用时写入默认顺序（内置按预设索引 + 自定义按 id）；
  /// - 之后将新增的内置预设/自定义指令补充到末尾，保证不丢失。
  Future<void> _syncQuickOrder(List<Map<String, dynamic>>? qcRows) async {
    final db = _db;
    if (db == null) return;
    final rows = qcRows ?? await db.query('quick_commands');
    final customIds = <int>[];
    for (final row in rows) {
      final qc = QuickCommand.fromDb(row);
      if (qc.overrideIndex == null) customIds.add(qc.id!);
    }
    final orderRows = await db.query('quick_command_order');
    final existingBuiltin = <int>{};
    final existingCustom = <int>{};
    var maxOrder = 0;
    for (final row in orderRows) {
      final o = row['sort_order'] as int;
      if (o > maxOrder) maxOrder = o;
      if ((row['is_builtin'] as int) == 1) {
        existingBuiltin.add(row['builtin_index'] as int);
      } else {
        existingCustom.add(row['ref_id'] as int);
      }
    }
    final batch = db.batch();
    var added = false;
    for (var i = 0; i < _presets.length; i++) {
      if (existingBuiltin.contains(i)) continue;
      batch.insert('quick_command_order', {
        'sort_order': ++maxOrder,
        'is_builtin': 1,
        'builtin_index': i,
      });
      added = true;
    }
    for (final id in customIds) {
      if (existingCustom.contains(id)) continue;
      batch.insert('quick_command_order', {
        'sort_order': ++maxOrder,
        'is_builtin': 0,
        'ref_id': id,
      });
      added = true;
    }
    if (added) await batch.commit(noResult: true);
  }

  void _rebuildQuickCommands(
    List<Map<String, dynamic>> rows,
    List<Map<String, dynamic>> orderRows,
  ) {
    final overrides = <int, QuickCommand>{};
    final customs = <int, QuickCommand>{};
    final hidden = <int>{};
    for (final row in rows) {
      final qc = QuickCommand.fromDb(row);
      final idx = qc.overrideIndex;
      if (idx != null) {
        if (idx < 0) {
          // 负数表示隐藏的内置预设（-1 -> 隐藏内置 0, -2 -> 隐藏内置 1 ...）
          hidden.add(-idx - 1);
        } else {
          overrides[idx] = qc;
        }
      } else {
        customs[qc.id!] = qc;
      }
    }
    _quickCommands.clear();
    if (orderRows.isNotEmpty) {
      for (final row in orderRows) {
        if ((row['is_builtin'] as int) == 1) {
          final i = row['builtin_index'] as int;
          if (i < 0 || i >= _presets.length) continue;
          if (hidden.contains(i)) continue; // 用户隐藏的内置预设跳过
          _quickCommands.add(
            overrides[i] ?? QuickCommand.builtin(_presets[i], i),
          );
        } else {
          final qc = customs[row['ref_id'] as int];
          if (qc != null) _quickCommands.add(qc);
        }
      }
    } else {
      // 无排序表：按默认顺序（内置 + 自定义）
      for (var i = 0; i < _presets.length; i++) {
        if (hidden.contains(i)) continue;
        _quickCommands.add(
          overrides[i] ?? QuickCommand.builtin(_presets[i], i),
        );
      }
      _quickCommands.addAll(customs.values);
    }
  }

  /// 调整快捷指令显示顺序：同步更新内存并通知（各页面联动），
  /// 再异步按内存显示顺序重建排序表持久化。
  Future<void> moveQuickCommand(int from, int to) async {
    if (from == to) return;
    if (from < 0 ||
        from >= _quickCommands.length ||
        to < 0 ||
        to >= _quickCommands.length) {
      return;
    }
    // 1) 同步移动内存列表并通知
    final moved = _quickCommands.removeAt(from);
    _quickCommands.insert(to, moved);
    notifyListeners();
    // 2) 异步持久化：按当前内存显示顺序整表重建，
    //    规避排序表含隐藏项时按索引移位会错位的问题
    final db = _db;
    if (db == null) return;
    try {
      await _persistQuickCommandOrder();
    } catch (_) {
      await loadQuickCommands(); // 持久化失败时回滚为已保存顺序
    }
  }

  /// 按内存显示列表整表重建排序表（与界面完全一致；
  /// 被隐藏的内置项追加到末尾，恢复后出现在最后）
  Future<void> _persistQuickCommandOrder() async {
    final db = _db;
    if (db == null) return;
    final displayedBuiltins = <int>{};
    final batch = db.batch();
    batch.delete('quick_command_order');
    var order = 0;
    for (final qc in _quickCommands) {
      if (qc.isBuiltin || qc.isOverride) {
        final idx = qc.builtinIndex ?? qc.overrideIndex!;
        displayedBuiltins.add(idx);
        batch.insert('quick_command_order', {
          'sort_order': ++order,
          'is_builtin': 1,
          'builtin_index': idx,
        });
      } else {
        batch.insert('quick_command_order', {
          'sort_order': ++order,
          'is_builtin': 0,
          'ref_id': qc.id,
        });
      }
    }
    for (var i = 0; i < _presets.length; i++) {
      if (displayedBuiltins.contains(i)) continue;
      batch.insert('quick_command_order', {
        'sort_order': ++order,
        'is_builtin': 1,
        'builtin_index': i,
      });
    }
    await batch.commit(noResult: true);
  }

  /// 新增自定义快捷指令（追加到列表末尾）
  Future<void> addQuickCommand(String label, String command, {String? hint}) async {
    final db = _db;
    if (db == null) return;
    try {
      final id = await db.insert('quick_commands', {
        'label': label,
        'command': command,
        'hint': hint,
      });
      final maxOrder = Sqflite.firstIntValue(
            await db.rawQuery(
              'SELECT COALESCE(MAX(sort_order), 0) FROM quick_command_order',
            ),
          ) ??
          0;
      await db.insert('quick_command_order', {
        'sort_order': maxOrder + 1,
        'is_builtin': 0,
        'ref_id': id,
      });
      await loadQuickCommands();
    } catch (_) {
      // 忽略存储错误
    }
  }

  /// 更新自定义/覆盖快捷指令
  Future<void> updateQuickCommand(int id, String label, String command,
      {String? hint}) async {
    final db = _db;
    if (db == null) return;
    try {
      await db.update(
        'quick_commands',
        {'label': label, 'command': command, 'hint': hint},
        where: 'id = ?',
        whereArgs: [id],
      );
      await loadQuickCommands();
    } catch (_) {
      // 忽略存储错误
    }
  }

  /// 删除自定义快捷指令（同步清理排序表记录）
  Future<void> deleteQuickCommand(int id) async {
    final db = _db;
    if (db == null) return;
    try {
      await db.delete('quick_commands', where: 'id = ?', whereArgs: [id]);
      await db.delete(
        'quick_command_order',
        where: 'is_builtin = 0 AND ref_id = ?',
        whereArgs: [id],
      );
      await loadQuickCommands();
    } catch (_) {
      // 忽略存储错误
    }
  }

  /// 修改内置预设：保存为覆盖项（原内置仍可恢复）
  Future<void> overrideBuiltin(int index, String label, String command,
      {String? hint}) async {
    final db = _db;
    if (db == null) return;
    try {
      final existing = await db.query(
        'quick_commands',
        where: 'override_index = ?',
        whereArgs: [index],
      );
      if (existing.isNotEmpty) {
        await db.update(
          'quick_commands',
          {'label': label, 'command': command, 'hint': hint},
          where: 'override_index = ?',
          whereArgs: [index],
        );
      } else {
        await db.insert('quick_commands', {
          'label': label,
          'command': command,
          'hint': hint,
          'override_index': index,
        });
      }
      await loadQuickCommands();
    } catch (_) {
      // 忽略存储错误
    }
  }

  /// 恢复内置预设默认（删除覆盖项）
  Future<void> restoreBuiltin(int index) async {
    final db = _db;
    if (db == null) return;
    try {
      await db.delete(
        'quick_commands',
        where: 'override_index = ?',
        whereArgs: [index],
      );
      await loadQuickCommands();
    } catch (_) {
      // 忽略存储错误
    }
  }

  /// 隐藏内置预设（长按删除）
  Future<void> hideBuiltin(int index) async {
    final db = _db;
    if (db == null) return;
    try {
      // 负数 override_index 表示隐藏：-1 -> 内置 0, -2 -> 内置 1 ...
      await db.insert('quick_commands', {
        'label': '',
        'command': '',
        'override_index': -(index + 1),
      });
      await loadQuickCommands();
    } catch (_) {
      // 忽略存储错误
    }
  }

  /// 恢复全部隐藏的内置预设
  Future<void> restoreAllBuiltins() async {
    final db = _db;
    if (db == null) return;
    try {
      await db.delete(
        'quick_commands',
        where: 'override_index < 0',
      );
      await loadQuickCommands();
    } catch (_) {
      // 忽略存储错误
    }
  }

  void _addLog(LogKind kind, String message) {
    _logs.add(LogEntry(DateTime.now(), kind, message));
    if (_logs.length > _kMaxLogs) {
      _logs.removeRange(0, _logs.length - _kMaxLogs);
    }
    _globalLog?.log(
      source: GlobalLogSource.tcp,
      kind: kind.name,
      message: message,
    );
    notifyListeners();
  }

  void _setStatus(TcpStatus s) {
    if (_status != s) {
      _status = s;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _pendingTimer?.cancel();
    _socket?.destroy();
    _db?.close();
    super.dispose();
  }
}

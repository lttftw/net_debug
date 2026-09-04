import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'app_settings_service.dart';
import 'app_state_db.dart';
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
  static const _kMaxHistory = 100;
  static const _kMaxConnections = 10;

  /// 消息区数量上限（来自应用设置，默认 100）
  int get maxLogs => AppSettingsService.instance.maxLogs;

  TcpService() {
    // 消息区数量上限变化时同步刷新 UI
    AppSettingsService.instance.addListener(_onSettingsChanged);
  }

  void _onSettingsChanged() => notifyListeners();

  Socket? _socket;
  TcpStatus _status = TcpStatus.disconnected;
  final List<LogEntry> _logs = [];
  final List<HistoryEntry> _history = [];
  final List<ConnectionProfile> _connections = [];

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
  /// 是否启用 OTA 固件升级扩展
  bool get otaEnabled => _otaEnabled;


  bool get autoScroll => _autoScroll;
  bool get busy => _pending != null;

  /// 初始化 sqlite 数据库（应用支持目录，覆盖安装后数据保留）
  Future<void> _initDb() async {
    if (_db != null) return;
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, 'debug_tools.db');
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

  /// 从 sqlite 加载历史指令与连接配置
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
    } catch (_) {
      // 忽略存储错误
    }
    notifyListeners();
  }

  /// 加载工具配置（如 OTA 扩展开关）。运行时设置统一存 sqlite。
  Future<void> loadSettings() async {
    try {
      await AppStateDb.instance.migrateFileToKey(
        AppStateDb.tcpSettingsKey,
        'tcp_settings.json',
      );
      final raw = await AppStateDb.instance.read(AppStateDb.tcpSettingsKey);
      if (raw != null) {
        final json = jsonDecode(raw);
        _otaEnabled = (json['ota_enabled'] as bool?) ?? false;
      }
    } catch (_) {
      // 忽略存储错误
    }
    notifyListeners();
  }

  /// 设置 OTA 固件升级扩展开关（持久化到 sqlite）
  Future<void> setOtaEnabled(bool value) async {
    _otaEnabled = value;
    notifyListeners();
    await AppStateDb.instance.write(
      AppStateDb.tcpSettingsKey,
      jsonEncode({'ota_enabled': _otaEnabled}),
    );
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
        result.complete(
          await _sendCommandRaw(trimmed, timeout, recordHistory: recordHistory),
        );
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
      _addLog(LogKind.tx, data);
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
      _addLog(LogKind.tx, trimmed);
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
      _addLog(LogKind.rx, line);
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

  void _addLog(LogKind kind, String message) {
    final max = AppSettingsService.instance.maxLogs;
    _logs.add(LogEntry(DateTime.now(), kind, message));
    if (_logs.length > max) {
      _logs.removeRange(0, _logs.length - max);
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
    AppSettingsService.instance.removeListener(_onSettingsChanged);
    _pendingTimer?.cancel();
    _socket?.destroy();
    _db?.close();
    super.dispose();
  }
}

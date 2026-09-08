import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../models/modbus_command.dart';
import 'app_settings_service.dart';
import 'app_state_db.dart';
import 'global_log_service.dart';

/// Modbus TCP 连接状态
enum ModbusStatus { disconnected, connecting, connected }

/// Modbus 日志类型
enum ModbusLogKind { tx, rx, system, error }

/// 一条 Modbus 日志
class ModbusLogEntry {
  final DateTime time;
  final ModbusLogKind kind;
  final String message;

  ModbusLogEntry(this.time, this.kind, this.message);
}

/// 一次 Modbus 请求-响应的结果。
class ModbusResult {
  final bool ok;

  /// 请求功能码
  final int functionCode;

  /// 异常码（ok 为 false 时有值）
  final int? exceptionCode;

  /// 响应帧原始 hex
  final String rawHex;

  /// 解析后的数据文本（读类为数据，写类为确认）
  final String dataText;

  /// 读寄存器解析出的 u16 值（读寄存器类）
  final List<int>? registers;

  /// 读线圈/离散输入的位值（读线圈/离散类）
  final List<bool>? coils;

  const ModbusResult({
    required this.ok,
    required this.functionCode,
    this.exceptionCode,
    required this.rawHex,
    required this.dataText,
    this.registers,
    this.coils,
  });
}

/// 一条 Modbus 连接配置历史。
class ModbusConnection {
  final String host;
  final int port;

  const ModbusConnection(this.host, this.port);

  String get label => '$host:$port';

  Map<String, dynamic> toJson() => {'host': host, 'port': port};

  factory ModbusConnection.fromJson(Map<String, dynamic> json) =>
      ModbusConnection(json['host'] as String, json['port'] as int);
}

/// Modbus TCP 主站通信层：连接、MBAP 帧编解码、8 个功能码请求/响应。
class ModbusTcpService extends ChangeNotifier {
  static const Duration _defaultTimeout = Duration(seconds: 3);
  static const int _kMaxConnections = 10;

  ModbusTcpService() {
    AppSettingsService.instance.addListener(_onSettingsChanged);
  }

  void _onSettingsChanged() => notifyListeners();

  int get maxLogs => AppSettingsService.instance.maxLogs;

  Socket? _socket;
  ModbusStatus _status = ModbusStatus.disconnected;
  final List<ModbusLogEntry> _logs = [];
  List<int> _buffer = [];
  int _transactionId = 1;

  Completer<Uint8List>? _pending;
  int? _pendingTid;
  Timer? _pendingTimer;

  GlobalLogService? _globalLog;

  final List<ModbusConnection> _connections = [];

  ModbusStatus get status => _status;
  List<ModbusLogEntry> get logs => List.unmodifiable(_logs);
  List<ModbusConnection> get connections => List.unmodifiable(_connections);
  bool get busy => _pending != null;

  void init({GlobalLogService? globalLog}) {
    _globalLog = globalLog;
  }

  /// 加载连接历史（应用启动时调用）。
  Future<void> loadConnections() async {
    try {
      final raw = await AppStateDb.instance.read(AppStateDb.modbusConnectionsKey);
      if (raw != null) {
        final list = jsonDecode(raw) as List;
        _connections
          ..clear()
          ..addAll([
            for (final e in list)
              if (e is Map) ModbusConnection.fromJson(e.cast<String, dynamic>()),
          ]);
      }
    } catch (_) {
      // 忽略存储错误
    }
    notifyListeners();
  }

  /// 清空连接历史（内存 + 持久化）。
  Future<void> clearConnections() async {
    _connections.clear();
    notifyListeners();
    await AppStateDb.instance.remove(AppStateDb.modbusConnectionsKey);
  }

  void _saveConnection(String host, int port) {
    _connections.removeWhere((c) => c.host == host && c.port == port);
    _connections.insert(0, ModbusConnection(host, port));
    if (_connections.length > _kMaxConnections) {
      _connections.removeRange(_kMaxConnections, _connections.length);
    }
    _persistConnections();
    notifyListeners();
  }

  Future<void> _persistConnections() async {
    await AppStateDb.instance.write(
      AppStateDb.modbusConnectionsKey,
      jsonEncode([for (final c in _connections) c.toJson()]),
    );
  }

  /// 连接 Modbus 从站（默认端口 502）。
  Future<void> connect(String host, int port) async {
    if (_status == ModbusStatus.connecting || _status == ModbusStatus.connected) {
      await disconnect();
    }
    _setStatus(ModbusStatus.connecting);
    _addLog(ModbusLogKind.system, '正在连接 $host:$port ...');
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 5),
      );
      socket.setOption(SocketOption.tcpNoDelay, true);
      _socket = socket;
      _buffer = [];
      socket.listen(
        (data) => _onData(socket, data),
        onError: (Object e) => _onError(socket, e),
        onDone: () => _onDone(socket),
        cancelOnError: true,
      );
      _setStatus(ModbusStatus.connected);
      _addLog(ModbusLogKind.system, '已连接 $host:$port');
      _saveConnection(host, port);
    } catch (e) {
      _setStatus(ModbusStatus.disconnected);
      _addLog(ModbusLogKind.error, '连接失败: $e');
    }
  }

  Future<void> disconnect() async {
    _failPending('连接已断开');
    final s = _socket;
    _socket = null;
    if (s != null) {
      try {
        await s.close();
      } catch (_) {}
    }
    _setStatus(ModbusStatus.disconnected);
    _addLog(ModbusLogKind.system, '已断开连接');
  }

  /// 发送一条 Modbus 指令并等待响应。
  Future<ModbusResult> send(ModbusCommand cmd) async {
    final s = _socket;
    if (s == null || _status != ModbusStatus.connected) {
      throw Exception('未连接，无法发送');
    }
    if (_pending != null) {
      throw Exception('上一条指令尚未返回，请稍候');
    }

    final pdu = _buildPdu(cmd);
    final tid = _nextTransactionId();
    final frame = _buildFrame(tid, cmd.unit, pdu);

    final completer = Completer<Uint8List>();
    _pending = completer;
    _pendingTid = tid;
    _pendingTimer = Timer(_defaultTimeout, () {
      if (_pending == completer) {
        _pending = null;
        _pendingTid = null;
        // 丢弃残缺的接收缓冲，避免迟到的半帧与下一响应拼接错位
        _buffer = [];
        completer.completeError(TimeoutException('等待响应超时'));
      }
    });

    try {
      s.add(frame);
      await s.flush();
      _addLog(ModbusLogKind.tx, '${cmd.summary}  [${_hex(frame)}]');
      notifyListeners();

      final respFrame = await completer.future;
      _pending = null;
      _pendingTid = null;
      _pendingTimer?.cancel();
      _pendingTimer = null;

      final result = _parseFrame(respFrame, cmd);
      _addLog(
        ModbusLogKind.rx,
        '[${_hex(respFrame)}]  →  ${result.dataText}',
      );
      return result;
    } catch (e) {
      _pending = null;
      _pendingTid = null;
      _pendingTimer?.cancel();
      _pendingTimer = null;
      _addLog(ModbusLogKind.error, '发送失败: $e');
      rethrow;
    }
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }

  // ---------- 帧构造 ----------

  int _nextTransactionId() {
    final id = _transactionId;
    _transactionId = (_transactionId + 1) & 0xFFFF;
    if (_transactionId == 0) _transactionId = 1;
    return id;
  }

  Uint8List _buildFrame(int tid, int unit, Uint8List pdu) {
    final b = BytesBuilder();
    b.addByte((tid >> 8) & 0xFF);
    b.addByte(tid & 0xFF);
    b.addByte(0); // 协议 ID 高位
    b.addByte(0); // 协议 ID 低位
    final len = 1 + pdu.length;
    b.addByte((len >> 8) & 0xFF);
    b.addByte(len & 0xFF);
    b.addByte(unit & 0xFF);
    b.add(pdu);
    return b.toBytes();
  }

  Uint8List _buildPdu(ModbusCommand cmd) {
    final b = BytesBuilder();
    b.addByte(cmd.function.code);
    b.addByte((cmd.address >> 8) & 0xFF);
    b.addByte(cmd.address & 0xFF);
    switch (cmd.function) {
      case ModbusFunction.readCoils:
      case ModbusFunction.readDiscreteInputs:
      case ModbusFunction.readHoldingRegisters:
      case ModbusFunction.readInputRegisters:
        final n = cmd.count ?? 1;
        b.addByte((n >> 8) & 0xFF);
        b.addByte(n & 0xFF);
        break;
      case ModbusFunction.writeSingleCoil:
        final v = cmd.coilValue == true ? 0xFF00 : 0x0000;
        b.addByte((v >> 8) & 0xFF);
        b.addByte(v & 0xFF);
        break;
      case ModbusFunction.writeSingleRegister:
        final v = cmd.registerValue ?? 0;
        b.addByte((v >> 8) & 0xFF);
        b.addByte(v & 0xFF);
        break;
      case ModbusFunction.writeMultipleCoils:
        final coils = cmd.coilValues ?? const <bool>[];
        final qty = coils.length;
        b.addByte((qty >> 8) & 0xFF);
        b.addByte(qty & 0xFF);
        final bytes = _packCoils(coils);
        b.addByte(bytes.length);
        b.add(bytes);
        break;
      case ModbusFunction.writeMultipleRegisters:
        final regs = cmd.registerValues ?? const <int>[];
        final qty = regs.length;
        b.addByte((qty >> 8) & 0xFF);
        b.addByte(qty & 0xFF);
        final bytes = Uint8List(qty * 2);
        for (var i = 0; i < qty; i++) {
          bytes[i * 2] = (regs[i] >> 8) & 0xFF;
          bytes[i * 2 + 1] = regs[i] & 0xFF;
        }
        b.addByte(bytes.length);
        b.add(bytes);
        break;
    }
    return b.toBytes();
  }

  Uint8List _packCoils(List<bool> coils) {
    final bytes = Uint8List((coils.length + 7) ~/ 8);
    for (var i = 0; i < coils.length; i++) {
      if (coils[i]) bytes[i >> 3] |= 1 << (i & 7);
    }
    return bytes;
  }

  // ---------- 响应解析 ----------

  ModbusResult _parseFrame(Uint8List frame, ModbusCommand cmd) {
    // 至少 MBAP 头 7 字节 + PDU
    if (frame.length < 9) {
      throw Exception('响应帧过短');
    }
    final pid = (frame[2] << 8) | frame[3];
    if (pid != 0) {
      throw Exception('响应协议 ID 非法: $pid');
    }
    final unit = frame[6];
    if (unit != cmd.unit) {
      throw Exception('响应从站地址不匹配: 期望 ${cmd.unit}，收到 $unit');
    }
    final pdu = Uint8List.sublistView(frame, 7);
    return _parsePdu(pdu, cmd);
  }

  ModbusResult _parsePdu(Uint8List pdu, ModbusCommand cmd) {
    if (pdu.isEmpty) {
      throw Exception('响应帧不完整');
    }
    final fcByte = pdu[0];
    // 异常响应
    if ((fcByte & 0x80) != 0) {
      final code = pdu.length > 1 ? pdu[1] : 0;
      return ModbusResult(
        ok: false,
        functionCode: cmd.function.code,
        exceptionCode: code,
        rawHex: _hex(pdu),
        dataText: '异常 ${_exceptionText(code)}',
      );
    }
    if (fcByte != cmd.function.code) {
      throw Exception(
        '响应功能码不一致: 期望 0x${cmd.function.code.toRadixString(16).padLeft(2, '0')}，'
        '收到 0x${fcByte.toRadixString(16).padLeft(2, '0')}',
      );
    }

    switch (cmd.function) {
      case ModbusFunction.readCoils:
      case ModbusFunction.readDiscreteInputs:
        if (pdu.length < 2) {
          throw Exception('响应帧不完整');
        }
        final byteCount = pdu[1];
        if (pdu.length < 2 + byteCount) {
          throw Exception('响应帧不完整: 声明 $byteCount 字节，实际 ${pdu.length - 2}');
        }
        final data = Uint8List.sublistView(pdu, 2, 2 + byteCount);
        final coils = _unpackCoils(data, cmd.count ?? 1);
        return ModbusResult(
          ok: true,
          functionCode: cmd.function.code,
          rawHex: _hex(pdu),
          dataText: '[${coils.map((v) => v ? 1 : 0).join(', ')}]',
          coils: coils,
        );
      case ModbusFunction.readHoldingRegisters:
      case ModbusFunction.readInputRegisters:
        if (pdu.length < 2) {
          throw Exception('响应帧不完整');
        }
        final byteCount = pdu[1];
        if (pdu.length < 2 + byteCount) {
          throw Exception('响应帧不完整: 声明 $byteCount 字节，实际 ${pdu.length - 2}');
        }
        final data = Uint8List.sublistView(pdu, 2, 2 + byteCount);
        final regs = <int>[
          for (var i = 0; i + 1 < data.length; i += 2)
            (data[i] << 8) | data[i + 1],
        ];
        final text = _formatRegisters(regs, cmd.asType);
        return ModbusResult(
          ok: true,
          functionCode: cmd.function.code,
          rawHex: _hex(pdu),
          dataText: text,
          registers: regs,
        );
      case ModbusFunction.writeSingleCoil:
      case ModbusFunction.writeSingleRegister:
      case ModbusFunction.writeMultipleCoils:
      case ModbusFunction.writeMultipleRegisters:
        return ModbusResult(
          ok: true,
          functionCode: cmd.function.code,
          rawHex: _hex(pdu),
          dataText: 'OK',
        );
    }
  }

  List<bool> _unpackCoils(Uint8List data, int count) {
    if (count > data.length * 8) {
      throw Exception('响应数据不足: 期望 $count 位，实际 ${data.length * 8} 位');
    }
    final out = <bool>[];
    for (var i = 0; i < count; i++) {
      final byte = data[i >> 3];
      out.add((byte & (1 << (i & 7))) != 0);
    }
    return out;
  }

  String _formatRegisters(List<int> regs, String? asType) {
    if (asType == 'u32') {
      final u32 = <int>[];
      for (var i = 0; i + 1 < regs.length; i += 2) {
        u32.add((regs[i] << 16) | regs[i + 1]);
      }
      if (u32.isEmpty) return '[]';
      return '[${u32.join(', ')}]';
    }
    return '[${regs.join(', ')}]';
  }

  String _exceptionText(int code) {
    switch (code) {
      case 1:
        return '01 非法功能码';
      case 2:
        return '02 地址越界';
      case 3:
        return '03 数量或值非法';
      case 4:
        return '04 执行失败';
      default:
        return '$code';
    }
  }

  String _hex(List<int> bytes) => bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');

  // ---------- 数据接收 ----------

  void _onData(Socket source, Uint8List data) {
    if (!identical(_socket, source)) return;
    _buffer.addAll(data);
    while (_buffer.length >= 6) {
      final len = (_buffer[4] << 8) | _buffer[5];
      final frameLen = 6 + len;
      if (_buffer.length < frameLen) break;
      final frame = Uint8List.fromList(_buffer.sublist(0, frameLen));
      _buffer = _buffer.sublist(frameLen);
      _dispatchFrame(frame);
    }
  }

  void _dispatchFrame(Uint8List frame) {
    final tid = (frame[0] << 8) | frame[1];
    final p = _pending;
    if (p != null && tid == _pendingTid && !p.isCompleted) {
      _pending = null;
      _pendingTid = null;
      _pendingTimer?.cancel();
      _pendingTimer = null;
      p.complete(frame);
    }
    // 事务 ID 不匹配或非 pending 的帧忽略（Modbus 主站一次一请求）
  }

  void _onError(Socket source, Object error) {
    if (!identical(_socket, source)) return;
    _socket = null;
    _buffer = [];
    source.destroy();
    _failPending('接收错误: $error');
    _setStatus(ModbusStatus.disconnected);
    _addLog(ModbusLogKind.error, '接收错误: $error');
  }

  void _onDone(Socket source) {
    if (!identical(_socket, source)) return;
    _socket = null;
    _buffer = [];
    _failPending('连接已关闭');
    _setStatus(ModbusStatus.disconnected);
    _addLog(ModbusLogKind.system, '连接已关闭');
  }

  void _failPending(String reason) {
    final p = _pending;
    if (p != null) {
      _pending = null;
      _pendingTid = null;
      _pendingTimer?.cancel();
      _pendingTimer = null;
      p.completeError(Exception(reason));
    }
  }

  void _addLog(ModbusLogKind kind, String message) {
    final max = AppSettingsService.instance.maxLogs;
    _logs.add(ModbusLogEntry(DateTime.now(), kind, message));
    if (_logs.length > max) {
      _logs.removeRange(0, _logs.length - max);
    }
    _globalLog?.log(
      source: GlobalLogSource.modbus,
      kind: kind.name,
      message: message,
    );
    notifyListeners();
  }

  void _setStatus(ModbusStatus s) {
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
    super.dispose();
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';

import 'app_settings_service.dart';
import 'app_state_db.dart';
import 'global_log_service.dart';

/// 串口连接状态
enum SerialStatus { disconnected, connecting, connected }

/// 串口日志类型
enum SerialLogKind { tx, rx, system, error }

/// 一条串口日志（[rawBytes] 非空时 UI 可按文本/HEX 模式重新格式化展示）
class SerialLogEntry {
  final DateTime time;
  final SerialLogKind kind;
  final String message;
  final Uint8List? rawBytes;

  SerialLogEntry(this.time, this.kind, this.message, [this.rawBytes]);
}

/// 枚举到的一个串口端口及其描述信息。
class SerialPortInfo {
  final String name;

  /// USB 描述（如 "USB-SERIAL CH340"），无则为 null
  final String? description;

  const SerialPortInfo(this.name, this.description);

  String get label =>
      description == null || description!.isEmpty ? name : '$name（$description）';
}

/// 一次打开串口的参数。
class SerialPortConfig2 {
  final String portName;
  final int baudRate;
  final int dataBits;
  final int parity; // SerialPortParity.*
  final int stopBits;

  const SerialPortConfig2({
    required this.portName,
    this.baudRate = 115200,
    this.dataBits = 8,
    this.parity = SerialPortParity.none,
    this.stopBits = 1,
  });

  String get label => '$portName @ $baudRate $dataBits$_parityLabel$stopBits';

  String get _parityLabel => switch (parity) {
    SerialPortParity.even => 'E',
    SerialPortParity.odd => 'O',
    _ => 'N',
  };
}

/// 串口调试服务：枚举端口、开关、参数配置、字节流收发与日志。
///
/// 当前使用 libserialport（Windows 桌面端）；读流跑在库内部的
/// 独立 isolate，接收侧按「数据静默 80ms」分帧为一条 RX 日志。
class SerialService extends ChangeNotifier {
  static const int _kMaxHistory = 100;
  static const Duration _frameGap = Duration(milliseconds: 80);

  SerialService() {
    AppSettingsService.instance.addListener(_onSettingsChanged);
  }

  void _onSettingsChanged() => notifyListeners();

  int get maxLogs => AppSettingsService.instance.maxLogs;

  SerialPort? _port;
  SerialPortReader? _reader;
  StreamSubscription<Uint8List>? _rxSub;
  SerialStatus _status = SerialStatus.disconnected;

  /// 当前已打开的参数（未打开为 null）
  SerialPortConfig2? _activeConfig;
  final List<SerialLogEntry> _logs = [];
  final List<String> _history = [];
  final List<int> _rxBuffer = [];
  Timer? _frameTimer;

  GlobalLogService? _globalLog;

  SerialStatus get status => _status;
  SerialPortConfig2? get activeConfig => _activeConfig;
  List<SerialLogEntry> get logs => List.unmodifiable(_logs);
  List<String> get history => List.unmodifiable(_history);

  /// 当前平台是否支持串口（后续接入 Android USB 串口后扩展）
  bool get isSupported => !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  void init({GlobalLogService? globalLog}) {
    _globalLog = globalLog;
  }

  /// 加载发送历史（应用启动时调用）。
  Future<void> loadHistory() async {
    try {
      final raw = await AppStateDb.instance.read(AppStateDb.serialHistoryKey);
      if (raw != null) {
        final list = jsonDecode(raw) as List;
        _history
          ..clear()
          ..addAll([
            for (final e in list)
              if (e is String && e.isNotEmpty) e,
          ]);
      }
    } catch (_) {
      // 忽略存储错误
    }
    notifyListeners();
  }

  /// 枚举当前可用串口（含 USB 描述信息）。
  List<SerialPortInfo> listPorts() {
    try {
      return [
        for (final name in SerialPort.availablePorts)
          SerialPortInfo(name, _safeDescription(name)),
      ];
    } catch (_) {
      return const [];
    }
  }

  String? _safeDescription(String name) {
    try {
      return SerialPort(name).description;
    } catch (_) {
      return null;
    }
  }

  /// 打开串口。
  Future<void> open(SerialPortConfig2 config) async {
    if (_status != SerialStatus.disconnected) await close();
    _status = SerialStatus.connecting;
    notifyListeners();
    _addLog(SerialLogKind.system, '正在打开 ${config.portName} ...');
    SerialPort? port;
    try {
      port = SerialPort(config.portName);
      if (!port.openReadWrite()) {
        throw Exception('打开失败（端口可能被占用）');
      }
      final cfg = port.config;
      cfg.baudRate = config.baudRate;
      cfg.bits = config.dataBits;
      cfg.parity = config.parity;
      cfg.stopBits = config.stopBits;
      port.config = cfg;

      final reader = SerialPortReader(port, timeout: 50);
      _port = port;
      _reader = reader;
      _rxSub = reader.stream.listen(
        _onRxData,
        onError: (Object e) => _onRxError(e),
      );
      _activeConfig = config;
      _status = SerialStatus.connected;
      _addLog(SerialLogKind.system, '已打开 ${config.label}');
    } catch (e) {
      port?.dispose();
      _port = null;
      _reader = null;
      _activeConfig = null;
      _status = SerialStatus.disconnected;
      _addLog(SerialLogKind.error, '打开串口失败: $e');
    }
  }

  /// 关闭串口（静默模式不写日志，供 dispose 使用）。
  Future<void> close({bool silent = false}) async {
    _frameTimer?.cancel();
    _frameTimer = null;
    _rxBuffer.clear();
    await _rxSub?.cancel();
    _rxSub = null;
    _reader?.close();
    _reader = null;
    final p = _port;
    _port = null;
    if (p != null) {
      try {
        p.close();
      } catch (_) {}
      try {
        p.dispose();
      } catch (_) {}
    }
    final wasConnected = _status != SerialStatus.disconnected;
    _activeConfig = null;
    _status = SerialStatus.disconnected;
    if (!silent && wasConnected) {
      _addLog(SerialLogKind.system, '已关闭串口');
    }
    notifyListeners();
  }

  /// 发送一段字节。
  Future<bool> write(Uint8List bytes) async {
    final p = _port;
    if (p == null || _status != SerialStatus.connected) {
      _addLog(SerialLogKind.error, '串口未打开，无法发送');
      return false;
    }
    if (bytes.isEmpty) return false;
    try {
      final n = p.write(bytes, timeout: 1000);
      if (n < bytes.length) {
        throw Exception('仅写入 $n/${bytes.length} 字节');
      }
      _addLog(SerialLogKind.tx, '', bytes);
      notifyListeners();
      return true;
    } catch (e) {
      _addLog(SerialLogKind.error, '发送失败: $e（设备可能已拔出）');
      return false;
    }
  }

  /// 记录一条已发送内容到历史（发送成功后由页面调用）。
  /// 保存用户输入原文（文本或 HEX 串），重发回填时所见即所得。
  void recordSent(String content) {
    final text = content.trim();
    if (text.isEmpty) return;
    _addToHistory(text);
    notifyListeners();
  }

  // ---------- 接收分帧 ----------

  void _onRxData(Uint8List data) {
    _rxBuffer.addAll(data);
    _frameTimer?.cancel();
    _frameTimer = Timer(_frameGap, _flushRxFrame);
  }

  void _onRxError(Object error) {
    _addLog(SerialLogKind.error, '读取错误: $error');
  }

  /// 数据静默期满，把缓冲作为一条 RX 日志记录。
  void _flushRxFrame() {
    if (_rxBuffer.isEmpty) return;
    final bytes = Uint8List.fromList(_rxBuffer);
    _rxBuffer.clear();
    _addLog(SerialLogKind.rx, '', bytes);
  }

  // ---------- 历史与日志 ----------

  void _addToHistory(String cmd) {
    _history.remove(cmd);
    _history.insert(0, cmd);
    if (_history.length > _kMaxHistory) {
      _history.removeRange(_kMaxHistory, _history.length);
    }
    _saveHistory();
  }

  Future<void> clearHistory() async {
    _history.clear();
    notifyListeners();
    await _saveHistory();
  }

  Future<void> _saveHistory() async {
    try {
      await AppStateDb.instance.write(
        AppStateDb.serialHistoryKey,
        jsonEncode(_history),
      );
    } catch (_) {
      // 忽略存储错误
    }
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }

  void _addLog(SerialLogKind kind, String message, [Uint8List? rawBytes]) {
    final max = AppSettingsService.instance.maxLogs;
    _logs.add(SerialLogEntry(DateTime.now(), kind, message, rawBytes));
    if (_logs.length > max) {
      _logs.removeRange(0, _logs.length - max);
    }
    _globalLog?.log(
      source: GlobalLogSource.serial,
      kind: kind.name,
      message: rawBytes != null ? bytesToHex(rawBytes) : message,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    AppSettingsService.instance.removeListener(_onSettingsChanged);
    _frameTimer?.cancel();
    close(silent: true);
    super.dispose();
  }

  // ---------- 格式化工具 ----------

  static String bytesToHex(List<int> bytes) => bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');

  static String bytesToText(List<int> bytes) {
    // 可打印字节与 \t \r \n 原样显示（\r\n 呈现为正常换行，不乱码）；
    // 其余控制字节转义为可见的 \xNN，避免替换符丢失信息
    final sb = StringBuffer();
    for (final b in bytes) {
      if (b >= 0x20 && b != 0x7F) {
        sb.writeCharCode(b);
      } else if (b == 0x09 || b == 0x0D || b == 0x0A) {
        sb.writeCharCode(b);
      } else {
        sb
          ..write(r'\x')
          ..write(b.toRadixString(16).padLeft(2, '0'));
      }
    }
    return sb.toString();
  }

  /// 解析 HEX 输入（"AA 55" / "aa,55" / "AA55" 均可），非法返回 null。
  static Uint8List? parseHex(String input) {
    final cleaned = input.replaceAll(RegExp(r'[\s,，]+'), '');
    if (cleaned.isEmpty) return null;
    if (cleaned.length % 2 != 0) return null;
    if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(cleaned)) return null;
    return Uint8List.fromList([
      for (var i = 0; i < cleaned.length; i += 2)
        int.parse(cleaned.substring(i, i + 2), radix: 16),
    ]);
  }
}

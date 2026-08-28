import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mqtt_client/mqtt_client.dart' as mqtt;
import 'package:mqtt_client/mqtt_server_client.dart' as mqtt_server;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'global_log_service.dart';

/// MQTT 客户端连接状态
enum MqttConnStatus { disconnected, connecting, connected }

/// MQTT 消息日志类型
enum MqttLogKind { system, tx, rx, error }

/// 一条 MQTT 消息日志
class MqttLogEntry {
  final DateTime time;
  final MqttLogKind kind;
  final String message;

  /// 来源/发送主题（TX/RX 消息有效，事件类为 null）
  final String? topic;

  const MqttLogEntry(this.time, this.kind, this.message, {this.topic});
}

/// 保存的 MQTT 客户端连接配置。
/// [clientIdTemplate] 支持 `$(变量)` 占位符。
class MqttClientConfig {
  final String host;
  final int port;
  final String username;
  final String password;
  final String clientIdTemplate;

  const MqttClientConfig({
    this.host = '',
    this.port = 1883,
    this.username = '',
    this.password = '',
    this.clientIdTemplate = 'debug_tools',
  });

  Map<String, dynamic> toJson() => {
    'host': host,
    'port': port,
    'username': username,
    'password': password,
    'clientIdTemplate': clientIdTemplate,
  };

  MqttClientConfig copyWith({
    String? host,
    int? port,
    String? username,
    String? password,
    String? clientIdTemplate,
  }) {
    return MqttClientConfig(
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      password: password ?? this.password,
      clientIdTemplate: clientIdTemplate ?? this.clientIdTemplate,
    );
  }

  factory MqttClientConfig.fromJson(Map<String, dynamic> json) =>
      MqttClientConfig(
        host: (json['host'] as String?) ?? '',
        port: (json['port'] as num?)?.toInt() ?? 1883,
        username: (json['username'] as String?) ?? '',
        password: (json['password'] as String?) ?? '',
        clientIdTemplate:
            (json['clientIdTemplate'] as String?) ??
            (json['clientId'] as String?) ??
            'debug_tools',
      );
}

/// 独立的 MQTT 调试客户端服务：负责 broker 连接、订阅、发布与消息日志，
/// 与 TcpService 完全解耦，可作为独立的调试工具使用。
class MqttService extends ChangeNotifier {
  /// 消息/事件历史条数上限（默认 100 条，可调整）
  int maxLogs = 100;

  mqtt_server.MqttServerClient? _client;
  MqttConnStatus _status = MqttConnStatus.disconnected;
  final List<MqttLogEntry> _logs = [];
  final List<String> _subscriptions = [];
  final Map<String, Color> _topicColors = {};
  final math.Random _topicColorRandom = math.Random();
  Future<String>? _installationIdFuture;
  StreamSubscription<List<mqtt.MqttReceivedMessage<mqtt.MqttMessage?>>?>?
  _updatesSub;
  MqttClientConfig _config = const MqttClientConfig();

  GlobalLogService? _globalLog;

  /// 初始化全局日志连接（在 loadConfig 方法之前调用）
  void init({GlobalLogService? globalLog}) {
    _globalLog = globalLog;
  }

  MqttConnStatus get status => _status;
  bool get isConnected => _status == MqttConnStatus.connected;
  List<MqttLogEntry> get logs => List.unmodifiable(_logs);
  List<String> get subscriptions => List.unmodifiable(_subscriptions);
  MqttClientConfig get config => _config;

  // ---------- 配置 / 订阅持久化（本地 JSON 文件） ----------

  Future<void> loadConfig() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final installationId = await _ensureInstallationId(dir);
      final file = File(p.join(dir.path, 'mqtt_client_config.json'));
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString());
        _config = MqttClientConfig.fromJson(
          (json as Map).cast<String, dynamic>(),
        );
      }
      // 默认 Client ID 在多端或公网 Broker 上会冲突，
      // 仅在用户未自定义时追加安装 ID 保证唯一；明确配置的 ID 保持不变。
      if (_usesDefaultClientId(_config.clientIdTemplate)) {
        _config = _config.copyWith(
          clientIdTemplate: 'debug_tools_$installationId',
        );
        await file.writeAsString(jsonEncode(_config.toJson()));
      }
      final subFile = File(p.join(dir.path, 'mqtt_subscriptions.json'));
      if (await subFile.exists()) {
        final list = jsonDecode(await subFile.readAsString()) as List;
        _subscriptions
          ..clear()
          ..addAll(list.cast<String>());
        for (final topic in _subscriptions) {
          _assignTopicColor(topic);
        }
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> saveConfig(MqttClientConfig cfg) async {
    _config = cfg;
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File(p.join(dir.path, 'mqtt_client_config.json'));
      await file.writeAsString(jsonEncode(cfg.toJson()));
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _saveSubscriptions() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File(p.join(dir.path, 'mqtt_subscriptions.json'));
      await file.writeAsString(jsonEncode(_subscriptions));
    } catch (_) {}
  }

  // ---------- 连接管理 ----------

  Future<void> connect({MqttClientConfig? config, String? clientId}) async {
    final cfg = config ?? _config;
    if (cfg.host.trim().isEmpty) {
      _addLog(MqttLogKind.error, '未填写 MQTT 服务器地址');
      return;
    }
    await disconnect(quiet: true);
    final configuredClientId = (clientId ?? cfg.clientIdTemplate).trim();
    final cid = _usesDefaultClientId(configuredClientId)
        ? 'debug_tools_${await _ensureInstallationId()}'
        : configuredClientId;
    _setStatus(MqttConnStatus.connecting);
    _addLog(
      MqttLogKind.system,
      '正在连接 ${cfg.host}:${cfg.port} (client: ${cid.isEmpty ? 'debug_tools' : cid}) ...',
    );

    final client = mqtt_server.MqttServerClient(
      cfg.host.trim(),
      cid.isEmpty ? 'debug_tools' : cid,
      maxConnectionAttempts: 1,
    );
    client.port = cfg.port;
    client.logging(on: false);
    client.setProtocolV311();
    client.keepAlivePeriod = 30;
    client.autoReconnect = true;
    client.resubscribeOnAutoReconnect = true;
    // mqtt_client 的 socketTimeout setter 会把 connectTimeoutPeriod 强制改为
    // 10ms，而同步连接器恰好使用 connectTimeoutPeriod 等待 CONNACK。
    // 因此不能在此设置 socketTimeout，否则绝大多数正常 Broker 都会
    // 被误判为未返回 CONNACK。
    client.connectTimeoutPeriod = 8000;
    client.onAutoReconnect = () {
      if (!identical(_client, client)) return;
      _setStatus(MqttConnStatus.connecting);
      _addLog(MqttLogKind.system, '连接意外中断，正在自动重连…');
    };
    client.onAutoReconnected = () {
      if (!identical(_client, client)) return;
      _setStatus(MqttConnStatus.connected);
      _addLog(MqttLogKind.system, '已自动重连 ${cfg.host}:${cfg.port}');
    };
    client.onDisconnected = () {
      // 忽略旧 client 延迟到达的断线回调，避免覆盖新连接状态。
      if (!identical(_client, client)) return;
      _client = null;
      _updatesSub?.cancel();
      _updatesSub = null;
      final connectionStatus = client.connectionStatus;
      final origin = connectionStatus?.disconnectionOrigin;
      final returnCode = connectionStatus?.returnCode;
      _setStatus(MqttConnStatus.disconnected);
      _addLog(
        MqttLogKind.system,
        '连接已断开'
        '${origin == null ? '' : ' · 来源: $origin'}'
        '${returnCode == null ? '' : ' · 状态: $returnCode'}',
      );
    };
    client.onSubscribed = (topic) =>
        _addLog(MqttLogKind.system, '订阅已确认: $topic');

    // 建连开始前就纳入 service 生命周期，使用户可取消建连，
    // 也避免 UI 超时后留下无主的 socket/client。
    _client = client;

    try {
      await client.connect(
        cfg.username.isEmpty ? null : cfg.username,
        cfg.password.isEmpty ? null : cfg.password,
      );
    } on mqtt.NoConnectionException catch (e) {
      _failConnect(
        client,
        '连接失败: 8 秒内未完成 MQTT CONNACK 握手。'
        '详情: $e',
      );
      return;
    } on SocketException {
      _failConnect(
        client,
        '连接失败: 无法连接到 ${cfg.host}:${cfg.port}（TCP 超时或连接被拒绝）。'
        '请确认：① broker 已启动且端口正确 ② 地址可达（ping 通）'
        '③ 防火墙放行 1883 端口',
      );
      return;
    } catch (e) {
      _failConnect(client, '连接失败: ${e is SocketException ? e.message : e}');
      return;
    }
    if (!identical(_client, client)) {
      client.autoReconnect = false;
      client.disconnect();
      return;
    }
    if (client.connectionStatus?.state != mqtt.MqttConnectionState.connected) {
      final rc = client.connectionStatus?.returnCode;
      _failConnect(
        client,
        rc != null ? '连接被拒绝: $rc' : '连接失败: 连接超时或无响应（${cfg.host}:${cfg.port}）',
      );
      return;
    }

    _updatesSub?.cancel();
    _updatesSub = client.updates!.listen(_onUpdates);
    // 恢复历史订阅
    for (final t in _subscriptions) {
      client.subscribe(t, mqtt.MqttQos.atMostOnce);
    }
    _setStatus(MqttConnStatus.connected);
    _addLog(MqttLogKind.system, '已连接 ${cfg.host}:${cfg.port}');
  }

  Future<void> disconnect({bool quiet = false}) async {
    _updatesSub?.cancel();
    _updatesSub = null;
    final c = _client;
    _client = null;
    if (c != null) {
      try {
        c.autoReconnect = false;
        c.disconnect();
      } catch (_) {}
    }
    _setStatus(MqttConnStatus.disconnected);
    if (!quiet) {
      _addLog(MqttLogKind.system, '已断开连接');
    }
  }

  void _failConnect(mqtt_server.MqttServerClient client, String message) {
    if (!identical(_client, client)) return;
    _client = null;
    client.autoReconnect = false;
    try {
      client.disconnect();
    } catch (_) {}
    _setStatus(MqttConnStatus.disconnected);
    _addLog(MqttLogKind.error, message);
  }

  // ---------- 订阅 / 发布 ----------

  void subscribe(String topic) {
    final t = topic.trim();
    if (t.isEmpty) {
      _addLog(MqttLogKind.error, '订阅主题不能为空');
      return;
    }
    if (_subscriptions.contains(t)) {
      _addLog(MqttLogKind.system, '已订阅该主题: $t');
      return;
    }
    final c = _client;
    if (c != null && isConnected) {
      c.subscribe(t, mqtt.MqttQos.atMostOnce);
      _addLog(MqttLogKind.system, '订阅请求: $t');
    } else {
      _addLog(MqttLogKind.system, '未连接，订阅将在连接后自动生效: $t');
    }
    _subscriptions.add(t);
    _assignTopicColor(t);
    _saveSubscriptions();
    notifyListeners();
  }

  void unsubscribe(String topic) {
    final c = _client;
    if (c != null && isConnected) {
      c.unsubscribe(topic);
    }
    _subscriptions.remove(topic);
    _addLog(MqttLogKind.system, '取消订阅: $topic');
    _saveSubscriptions();
    notifyListeners();
  }

  void publish(String topic, String payload, {int qos = 0}) {
    final t = topic.trim();
    if (t.isEmpty) {
      _addLog(MqttLogKind.error, '发布主题不能为空');
      return;
    }
    final c = _client;
    if (c == null || !isConnected) {
      _addLog(MqttLogKind.error, '未连接 MQTT broker，无法发布');
      return;
    }
    final builder = mqtt.MqttClientPayloadBuilder()..addUTF8String(payload);
    c.publishMessage(t, _qosFromInt(qos), builder.payload!);
    _addLog(MqttLogKind.tx, payload, topic: t);
  }

  mqtt.MqttQos _qosFromInt(int qos) => switch (qos) {
    1 => mqtt.MqttQos.atLeastOnce,
    2 => mqtt.MqttQos.exactlyOnce,
    _ => mqtt.MqttQos.atMostOnce,
  };

  // ---------- 日志 ----------

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }

  void _onUpdates(List<mqtt.MqttReceivedMessage<mqtt.MqttMessage?>>? list) {
    if (list == null) return;
    for (final rec in list) {
      final topic = rec.topic;
      String payload = '';
      final msg = rec.payload;
      if (msg is mqtt.MqttPublishMessage) {
        payload = mqtt.MqttPublishPayload.bytesToStringAsString(
          msg.payload.message,
        );
      }
      _addLog(MqttLogKind.rx, payload, topic: topic);
    }
  }

  void _addLog(MqttLogKind kind, String message, {String? topic}) {
    if (_logs.length >= maxLogs) _logs.removeAt(0);
    _logs.add(MqttLogEntry(DateTime.now(), kind, message, topic: topic));
    _globalLog?.log(
      source: GlobalLogSource.mqtt,
      kind: kind.name,
      message: message,
      topic: topic,
    );
    notifyListeners();
  }

  // ---------- 主题取色 ----------

  static const _topicPalette = <Color>[
    Color(0xFF26C6DA), // 青蓝
    Color(0xFF66BB6A), // 绿
    Color(0xFFAB47BC), // 紫
    Color(0xFFFFA726), // 橙
    Color(0xFFEC407A), // 粉
    Color(0xFF5C6BC0), // 靛
    Color(0xFF29B6F6), // 天蓝
    Color(0xFF9CCC65), // 黄绿
    Color(0xFF8D6E63), // 棕
    Color(0xFF42A5F5), // 蓝
  ];

  /// 为订阅分配会话内稳定的随机颜色。若收到的具体 topic
  /// 由 `+` / `#` 订阅匹配，则复用该订阅的颜色。
  Color colorForTopic(String topic) {
    final direct = _topicColors[topic];
    if (direct != null) return direct;
    for (final filter in _subscriptions) {
      if (_matchesTopicFilter(filter, topic)) {
        return _assignTopicColor(filter);
      }
    }
    return _assignTopicColor(topic);
  }

  Color _assignTopicColor(String topic) {
    return _topicColors.putIfAbsent(topic, () {
      final used = _topicColors.values.toSet();
      final available =
          _topicPalette.where((color) => !used.contains(color)).toList()
            ..shuffle(_topicColorRandom);
      if (available.isNotEmpty) return available.first;
      return HSLColor.fromAHSL(
        1,
        _topicColorRandom.nextDouble() * 360,
        0.68,
        0.55,
      ).toColor();
    });
  }

  bool _matchesTopicFilter(String filter, String topic) {
    final filterLevels = filter.split('/');
    final topicLevels = topic.split('/');
    for (var i = 0; i < filterLevels.length; i++) {
      final level = filterLevels[i];
      if (level == '#') return i == filterLevels.length - 1;
      if (i >= topicLevels.length) return false;
      if (level != '+' && level != topicLevels[i]) return false;
    }
    return filterLevels.length == topicLevels.length;
  }

  bool _usesDefaultClientId(String value) =>
      value.trim().isEmpty || value.trim() == 'debug_tools';

  Future<String> _ensureInstallationId([Directory? supportDir]) {
    return _installationIdFuture ??= _loadOrCreateInstallationId(supportDir);
  }

  Future<String> _loadOrCreateInstallationId(Directory? supportDir) async {
    final dir = supportDir ?? await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'mqtt_installation_id.txt'));
    try {
      if (await file.exists()) {
        final saved = (await file.readAsString()).trim().toLowerCase();
        if (RegExp(r'^[0-9a-f]{8}$').hasMatch(saved)) return saved;
      }
      final generated = math.Random.secure()
          .nextInt(0x100000000)
          .toRadixString(16)
          .padLeft(8, '0');
      await file.writeAsString(generated, flush: true);
      return generated;
    } catch (_) {
      // 存储不可用时仍避免回退到全球共用的固定 ID。
      final fallback = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
      return fallback
          .padLeft(8, '0')
          .substring(fallback.length < 8 ? 0 : fallback.length - 8);
    }
  }

  void _setStatus(MqttConnStatus s) {
    _status = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _updatesSub?.cancel();
    final c = _client;
    _client = null;
    if (c != null) {
      try {
        c.disconnect();
      } catch (_) {}
    }
    super.dispose();
  }
}

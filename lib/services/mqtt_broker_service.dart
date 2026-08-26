import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mqtt_broker_lite/mqtt_broker_lite.dart' as broker;

/// 内置 MQTT Broker 事件类型
enum MqttBrokerLogKind {
  system,
  connect,
  disconnect,
  subscribe,
  publish,
  error,
}

/// 一条内置 Broker 事件日志
class MqttBrokerLog {
  final DateTime time;
  final MqttBrokerLogKind kind;
  final String message;

  const MqttBrokerLog(this.time, this.kind, this.message);
}

/// 内置 MQTT Broker 服务：在应用进程内运行一个纯 Dart 的 MQTT 3.1.1 broker，
/// 用于临时本地测试（本机回环或局域网设备直连），无需外部 broker。
class MqttBrokerService extends ChangeNotifier {
  /// 默认监听端口（避开常见的 1883 以避免与真实 broker 冲突）
  static const int defaultPort = 1884;

  /// 事件/日志条数上限
  static const int maxLogs = 100;

  broker.MqttBroker? _broker;
  bool _running = false;
  int _port = defaultPort;
  int _clientCount = 0;
  String? _lanIpV4;
  final List<MqttBrokerLog> _logs = [];
  final List<StreamSubscription<dynamic>> _subs = [];

  bool get running => _running;
  int get port => _port;
  int get clientCount => _clientCount;

  /// 局域网 IPv4 地址（供局域网设备连接提示），探测失败时为 null
  String? get lanIpV4 => _lanIpV4;
  List<MqttBrokerLog> get logs => List.unmodifiable(_logs);

  /// 启动内置 broker，监听 0.0.0.0:[port]（局域网设备也可连接）。
  /// 返回 null 表示成功，否则返回错误信息。
  Future<String?> start({int port = defaultPort}) async {
    if (_running) return null;
    try {
      final b = broker.MqttBroker(
        address: InternetAddress.anyIPv4.address,
        port: port,
      );
      _subs
        ..add(b.onConnect.listen((e) {
          _clientCount++;
          _addLog(MqttBrokerLogKind.connect, '客户端接入: ${e.clientId}');
        }))
        ..add(b.onDisconnect.listen((e) {
          if (_clientCount > 0) _clientCount--;
          _addLog(MqttBrokerLogKind.disconnect, '客户端断开: ${e.clientId}');
        }))
        ..add(
          b.onSubscribe.listen((e) {
            _addLog(
              MqttBrokerLogKind.subscribe,
              '${e.clientId} 订阅: ${e.filter}',
            );
          }),
        )
        ..add(
          b.onUnsubscribe.listen((e) {
            _addLog(
              MqttBrokerLogKind.subscribe,
              '${e.clientId} 取消订阅: ${e.filter}',
            );
          }),
        )
        ..add(b.onPublish.listen((e) {
          final text = utf8.decode(e.payload, allowMalformed: true);
          final preview =
              text.length > 120 ? '${text.substring(0, 120)}…' : text;
          _addLog(
            MqttBrokerLogKind.publish,
            '${e.clientId ?? 'broker'} 发布 ${e.topic}: $preview',
          );
        }));
      await b.start();
      _broker = b;
      _running = true;
      _port = port;
      _addLog(MqttBrokerLogKind.system, '内置 Broker 已启动，监听 0.0.0.0:$port');
      unawaited(_refreshLanIp());
      notifyListeners();
      return null;
    } catch (e) {
      _addLog(MqttBrokerLogKind.error, '启动失败: $e');
      return '内置 Broker 启动失败: $e';
    }
  }

  Future<void> stop() async {
    final b = _broker;
    _broker = null;
    if (b != null) {
      try {
        await b.stop();
      } catch (_) {}
      _addLog(MqttBrokerLogKind.system, '内置 Broker 已停止');
    }
    _running = false;
    _clientCount = 0;
    _clearSubs();
    notifyListeners();
  }

  /// 探测局域网 IPv4 地址（仅用于展示连接提示，失败时保持 null）。
  Future<void> _refreshLanIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final ifc in interfaces) {
        for (final addr in ifc.addresses) {
          if (!addr.isLoopback && addr.address.isNotEmpty) {
            _lanIpV4 = addr.address;
            notifyListeners();
            return;
          }
        }
      }
    } catch (_) {}
  }

  void _addLog(MqttBrokerLogKind kind, String message) {
    if (_logs.length >= maxLogs) _logs.removeAt(0);
    _logs.add(MqttBrokerLog(DateTime.now(), kind, message));
    notifyListeners();
  }

  void _clearSubs() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
  }

  @override
  void dispose() {
    _clearSubs();
    final b = _broker;
    _broker = null;
    if (b != null) {
      try {
        b.stop();
      } catch (_) {}
    }
    super.dispose();
  }
}
import 'package:flutter/foundation.dart';

import 'app_state_db.dart';

/// 应用级运行设置（ChangeNotifier + sqlite 持久化），全局单例。
///
/// 目前包含：消息区数量上限（TCP / MQTT 记录区共用，默认 100）。
class AppSettingsService extends ChangeNotifier {
  AppSettingsService._();

  /// 全局单例
  static final AppSettingsService instance = AppSettingsService._();

  /// 默认消息区数量上限
  static const int defaultMaxLogs = 100;

  static const int _minMaxLogs = 10;
  static const int _maxMaxLogs = 5000;

  int _maxLogs = defaultMaxLogs;

  int get maxLogs => _maxLogs;

  Future<void> load() async {
    final raw = await AppStateDb.instance.read(AppStateDb.logLimitKey);
    if (raw != null) {
      _maxLogs =
          (int.tryParse(raw) ?? defaultMaxLogs).clamp(_minMaxLogs, _maxMaxLogs);
    }
    notifyListeners();
  }

  Future<void> setMaxLogs(int value) async {
    final v = value.clamp(_minMaxLogs, _maxMaxLogs);
    if (v == _maxLogs) return;
    _maxLogs = v;
    notifyListeners();
    await AppStateDb.instance.write(AppStateDb.logLimitKey, '$v');
  }
}

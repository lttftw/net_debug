import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// 应用运行时设置/状态的统一 sqlite 存储（单表 key-value）。
///
/// 数据分层原则：
/// - **预设模板**（变量模板、快捷指令预设、主题模板默认等）以可读 JSON
///   承载（内置 assets 完整版/示例 + 用户目录个人文件），不存于此；
/// - **运行时修改**（主题外观、OTA 开关、MQTT 配置与订阅、主题模板等
///   用户实际设置）一律保存在 sqlite 中，程序更新 / 公开版与完整版互相
///   覆盖安装均不影响运行时数据；
/// - 日志保持 jsonl 追加写，不存 sqlite。
class AppStateDb {
  AppStateDb._();

  /// 全局单例
  static final AppStateDb instance = AppStateDb._();

  /// 各运行时数据在 kv 表中的键
  static const String themeKey = 'theme';
  static const String tcpSettingsKey = 'tcp_settings';
  static const String mqttConfigKey = 'mqtt_config';
  static const String mqttSubscriptionsKey = 'mqtt_subscriptions';
  static const String mqttInstallationIdKey = 'mqtt_installation_id';
  static const String topicTemplatesKey = 'topic_templates';
  static const String quickCommandsKey = 'quick_commands';
  static const String mqttQuickCommandsKey = 'mqtt_quick_commands';

  static const String _fileName = 'app_state.db';

  Database? _db;

  Future<Database> _open() async {
    if (_db != null) return _db!;
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, _fileName);
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE kv (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
      },
    );
    return _db!;
  }

  /// 读取指定 key 的运行时 JSON；不存在返回 null。
  Future<String?> read(String key) async {
    try {
      final db = await _open();
      final rows = await db.query(
        'kv',
        where: 'key = ?',
        whereArgs: [key],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return rows.first['value'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// 写入指定 key 的运行时 JSON（覆盖）。
  Future<void> write(String key, String value) async {
    try {
      final db = await _open();
      await db.insert(
        'kv',
        {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}
  }

  /// 删除指定 key。
  Future<void> remove(String key) async {
    try {
      final db = await _open();
      await db.delete('kv', where: 'key = ?', whereArgs: [key]);
    } catch (_) {}
  }

  /// 迁移旧版 JSON 文件到 kv：内容写入 [key] 后原文件改名为 `.bak`。
  /// 已存在同名 kv 值或旧文件缺失时跳过，保证幂等。
  Future<bool> migrateFileToKey(String key, String legacyFileName) async {
    try {
      final existing = await read(key);
      if (existing != null) return false;
      final dir = await getApplicationSupportDirectory();
      final file = File(p.join(dir.path, legacyFileName));
      if (!await file.exists()) return false;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return false;
      await write(key, raw);
      final bak = File('${file.path}.bak');
      if (await bak.exists()) await bak.delete();
      await file.rename(bak.path);
      return true;
    } catch (_) {
      return false;
    }
  }
}

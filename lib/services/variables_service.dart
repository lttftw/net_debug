import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// 模板变量项
class VariableItem {
  final String name;
  String value;
  String hint;

  VariableItem({required this.name, this.value = '', this.hint = ''});

  Map<String, dynamic> toJson() =>
      {'name': name, 'value': value, 'hint': hint};

  factory VariableItem.fromJson(Map<String, dynamic> json) => VariableItem(
    name: (json['name'] as String?) ?? '',
    value: (json['value'] as String?) ?? '',
    hint: (json['hint'] as String?) ?? '',
  );
}

/// 完整版变量定义资源（本地可选，未随公开仓库发布）
const String kVariablesAssetFull = 'assets/variables/variables.full.json';

/// 公开版示例变量定义资源（随仓库发布）
const String kVariablesAssetPublic = 'assets/variables/variables.json';

/// 旧版运行时配置文件名（JSON，迁移到 sqlite 后不再使用）
const String _legacyRuntimeJsonName = 'variables.json';

/// 模板加载结果：items 为模板项（`value` 即预设默认值）。
class _VariableTemplate {
  final List<VariableItem> items;

  const _VariableTemplate(this.items);
}

/// 模板变量统一管理服务。
///
/// 所有模板（MQTT 主题模板 / client id / 快捷指令等）中的 `$(变量名)`
/// 占位符统一由此服务替换，变量值可在此或各使用处的折叠面板中快捷填写。
///
/// 数据分层：
/// - **模板层（定义 + 预设默认值）**：外部个人模板文件（应用支持目录
///   `template_variables.json`，由内置完整版资源物化）优先；仅当外部文件
///   不存在时才读取内置资源。模板项的 `value` 作为预设默认值，首次初始化、
///   恢复默认或完整模板新增变量时使用。
/// - **运行时层（用户实际配置）**：持久化在 sqlite（`variables.db`），
///   用户增删改的变量与值都以这里为准，程序更新不会覆盖。
class VariablesService extends ChangeNotifier {
  final List<VariableItem> _items = [];
  Database? _db;

  List<VariableItem> get items => List.unmodifiable(_items);
  bool get isEmpty => _items.isEmpty;

  VariableItem? byName(String name) {
    for (final it in _items) {
      if (it.name == name) return it;
    }
    return null;
  }

  String valueOf(String name) => byName(name)?.value ?? '';

  /// 打开/创建运行时 sqlite 数据库
  Future<Database> _database() async {
    if (_db != null) return _db!;
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, 'variables.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE variables (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            value TEXT NOT NULL DEFAULT '',
            hint TEXT,
            sort_order INTEGER NOT NULL DEFAULT 0
          )
        ''');
      },
    );
    return _db!;
  }

  // ---------- 模板源 ----------

  static List<VariableItem> _parseList(String raw) {
    final list = jsonDecode(raw) as List;
    return [
      for (final item in list)
        if (item is Map) VariableItem.fromJson(item.cast<String, dynamic>()),
    ];
  }

  /// 读取模板变量定义（含预设默认值）。
  /// 以**内置完整版资源**为默认源（与程序一起随包发布），公开 demo 仅回退，
  /// 不读取程序目录中可能过时的旧副本，保证恢复默认/初始化始终采用
  /// 当前完整版里维护的默认值。
  Future<_VariableTemplate> _loadTemplate() async {
    for (final asset in [kVariablesAssetFull, kVariablesAssetPublic]) {
      try {
        final raw = await rootBundle.loadString(asset);
        return _VariableTemplate(_parseList(raw));
      } catch (_) {
        // 尝试下一个资源
      }
    }
    return const _VariableTemplate([]);
  }

  // ---------- 加载 ----------

  Future<void> load() async {
    try {
      final db = await _database();
      final rows = await db.query(
        'variables',
        orderBy: 'sort_order ASC, id ASC',
      );
      if (rows.isEmpty) {
        // 无任何运行时配置：优先迁移旧版 JSON；否则以模板（完整>示例）
        // 初始化。已有运行时数据时模板不再干预，尊重用户增删。
        final migrated = await _migrateLegacyJson(db);
        if (!migrated) {
          final template = await _loadTemplate();
          await _insertAll(db, template.items);
        }
      }
      await _loadFromDb(db);
    } catch (_) {}
    notifyListeners();
  }

  /// 旧版 `variables.json`（应用支持目录）迁移到 sqlite。
  /// 迁移成功后把旧文件改名为 `.bak`，避免重复导入。
  Future<bool> _migrateLegacyJson(Database db) async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File(p.join(dir.path, _legacyRuntimeJsonName));
      if (!await file.exists()) return false;
      final list = jsonDecode(await file.readAsString()) as List;
      final items = [
        for (final item in list)
          if (item is Map)
            VariableItem.fromJson(item.cast<String, dynamic>()),
      ];
      await _insertAll(db, items);
      final bak = File('${file.path}.bak');
      if (await bak.exists()) await bak.delete();
      await file.rename(bak.path);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 将 [items] 整体写入 sqlite（按序），表中原有内容清空。
  Future<void> _insertAll(Database db, List<VariableItem> items) async {
    final batch = db.batch();
    for (var i = 0; i < items.length; i++) {
      final v = items[i];
      batch.insert('variables', {
        'name': v.name,
        'value': v.value,
        'hint': v.hint,
        'sort_order': i,
      });
    }
    await batch.commit(noResult: true);
  }

  Future<void> _loadFromDb(Database db) async {
    final rows = await db.query(
      'variables',
      orderBy: 'sort_order ASC, id ASC',
    );
    _items
      ..clear()
      ..addAll([
        for (final row in rows)
          VariableItem(
            name: row['name'] as String,
            value: row['value'] as String? ?? '',
            hint: row['hint'] as String? ?? '',
          ),
      ]);
  }

  // ---------- 持久化 ----------

  /// 将内存中的当前变量配置整体写回 sqlite（按当前顺序全量重建）。
  Future<void> _persistAll() async {
    try {
      final db = await _database();
      final batch = db.batch();
      batch.delete('variables');
      for (var i = 0; i < _items.length; i++) {
        final v = _items[i];
        batch.insert('variables', {
          'name': v.name,
          'value': v.value,
          'hint': v.hint,
          'sort_order': i,
        });
      }
      await batch.commit(noResult: true);
    } catch (_) {}
  }

  // ---------- 变更 ----------

  Future<void> setValue(String name, String value) async {
    final it = byName(name);
    if (it == null) return;
    it.value = value;
    await _persistAll();
    notifyListeners();
  }

  Future<void> add(String name, {String value = '', String hint = ''}) async {
    final n = name.trim();
    if (n.isEmpty || byName(n) != null) return;
    _items.add(VariableItem(name: n, value: value, hint: hint));
    await _persistAll();
    notifyListeners();
  }

  Future<void> update(String name,
      {String? value, String? hint, String? newName}) async {
    final it = byName(name);
    if (it == null) return;
    if (newName != null && newName.trim().isNotEmpty && newName.trim() != name) {
      if (byName(newName.trim()) != null) return; // 重名不允许
      final ni = VariableItem(
        name: newName.trim(),
        value: it.value,
        hint: it.hint,
      );
      final idx = _items.indexOf(it);
      _items[idx] = ni;
    } else {
      if (value != null) it.value = value;
      if (hint != null) it.hint = hint;
    }
    await _persistAll();
    notifyListeners();
  }

  Future<void> remove(String name) async {
    _items.removeWhere((it) => it.name == name);
    await _persistAll();
    notifyListeners();
  }

  /// 清空运行时配置，以模板（含预设默认值）重新初始化。
  Future<void> restoreDefaults() async {
    final template = await _loadTemplate();
    _items
      ..clear()
      ..addAll(template.items.map((v) => VariableItem(
            name: v.name,
            value: v.value, // 模板预设值作为默认值
            hint: v.hint,
          )));
    await _persistAll();
    notifyListeners();
  }

  // ---------- 展开 ----------

  /// 将模板中的 `$(变量名)` 占位符替换为变量值（未定义或为空的保持原样）
  String expand(String template) {
    return template.replaceAllMapped(RegExp(r'\$\(([^)]+)\)'), (match) {
      final name = match.group(1)!.trim();
      final it = byName(name);
      if (it != null && it.value.isNotEmpty) return it.value;
      return match.group(0)!;
    });
  }

  /// 返回模板中「已定义但未填写值」的变量名。
  /// 用于发送前提示：空变量占位符不会被替换，会以原文发送导致指令异常。
  /// 未定义的占位符视为普通文本，不参与检查。
  List<String> emptyVariableNames(String template) {
    final found = <String>[];
    final re = RegExp(r'\$\(\s*([^()]+?)\s*\)');
    for (final m in re.allMatches(template)) {
      final name = m.group(1)!.trim();
      if (name.isEmpty) continue;
      final it = byName(name);
      if (it != null && it.value.isEmpty && !found.contains(name)) {
        found.add(name);
      }
    }
    return found;
  }

  @override
  void dispose() {
    _db?.close();
    super.dispose();
  }
}

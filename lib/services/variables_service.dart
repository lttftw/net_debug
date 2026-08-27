import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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

/// 加载默认变量定义：优先完整版资源，缺失时回退公开版示例。
/// 返回的均为无默认值的只读模板（value 为空，hint 为说明）。
Future<List<VariableItem>> loadDefaultVariables() async {
  for (final asset in [kVariablesAssetFull, kVariablesAssetPublic]) {
    try {
      final raw = await rootBundle.loadString(asset);
      final list = jsonDecode(raw) as List;
      return [
        for (final item in list)
          if (item is Map)
            VariableItem.fromJson(item.cast<String, dynamic>()),
      ];
    } catch (_) {
      // 尝试下一个资源
    }
  }
  return const [];
}

/// 模板变量统一管理服务。
/// 所有模板（MQTT 主题模板 / client id / 快捷指令等）中的 `{变量名}`
/// 占位符统一由此服务替换，变量值可在此或各使用处的折叠面板中快捷填写。
class VariablesService extends ChangeNotifier {
  final List<VariableItem> _items = [];

  List<VariableItem> get items => List.unmodifiable(_items);
  bool get isEmpty => _items.isEmpty;

  VariableItem? byName(String name) {
    for (final it in _items) {
      if (it.name == name) return it;
    }
    return null;
  }

  String valueOf(String name) => byName(name)?.value ?? '';

  Future<void> load() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File(p.join(dir.path, 'variables.json'));
      if (await file.exists()) {
        final list = jsonDecode(await file.readAsString()) as List;
        _items
          ..clear()
          ..addAll(list.map((e) => VariableItem.fromJson(
              (e as Map).cast<String, dynamic>())));
        // 补齐默认变量定义中缺失的项（不覆盖已有值）
        final defaults = await loadDefaultVariables();
        var changed = false;
        for (final v in defaults) {
          if (byName(v.name) == null) {
            _items.add(VariableItem(name: v.name, value: '', hint: v.hint));
            changed = true;
          }
        }
        if (changed) await _save();
      } else {
        await restoreDefaults();
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File(p.join(dir.path, 'variables.json'));
      await file.writeAsString(
          jsonEncode([for (final it in _items) it.toJson()]));
    } catch (_) {}
  }

  Future<void> setValue(String name, String value) async {
    final it = byName(name);
    if (it == null) return;
    it.value = value;
    await _save();
    notifyListeners();
  }

  Future<void> add(String name, {String value = '', String hint = ''}) async {
    final n = name.trim();
    if (n.isEmpty || byName(n) != null) return;
    _items.add(VariableItem(name: n, value: value, hint: hint));
    await _save();
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
    await _save();
    notifyListeners();
  }

  Future<void> remove(String name) async {
    _items.removeWhere((it) => it.name == name);
    await _save();
    notifyListeners();
  }

  Future<void> restoreDefaults() async {
    final defaults = await loadDefaultVariables();
    _items
      ..clear()
      ..addAll(defaults.map((v) => VariableItem(
            name: v.name,
            value: '',
            hint: v.hint,
          )));
    await _save();
    notifyListeners();
  }

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
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/topic_template.dart';

/// 主题模板统一管理服务。
/// 首次启动把内置模板组（assets）写入本地文件，之后用户可在
/// 「设置 · 主题模板」中增删改模板组与模板，改动持久化到本地 JSON。
class TopicTemplateService extends ChangeNotifier {
  static const String _fileName = 'topic_templates.json';
  final List<TopicTemplateGroup> _groups = [];

  List<TopicTemplateGroup> get groups => List.unmodifiable(_groups);

  Future<void> load() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File(p.join(dir.path, _fileName));
      final defaults = await loadTopicTemplateGroups();
      if (await file.exists()) {
        final list = jsonDecode(await file.readAsString()) as List;
        _groups
          ..clear()
          ..addAll([
            for (final item in list)
              if (item is Map)
                TopicTemplateGroup.fromJson(item.cast<String, dynamic>()),
          ]);
        // 补齐内置组中缺失的项（不覆盖用户改动）
        await _mergeDefaults(defaults);
      } else {
        _groups
          ..clear()
          ..addAll(defaults);
        await _save();
      }
      notifyListeners();
    } catch (_) {
      // 读取/存储失败时回退到内置模板
      _groups
        ..clear()
        ..addAll(await loadTopicTemplateGroups());
      notifyListeners();
    }
  }

  /// 把内置组里没出现过（按名称）的组补充到末尾，保证出厂模板不丢失
  Future<void> _mergeDefaults(List<TopicTemplateGroup> defaults) async {
    var changed = false;
    for (final g in defaults) {
      if (_groups.any((e) => e.name == g.name)) continue;
      _groups.add(g);
      changed = true;
    }
    if (changed) await _save();
  }

  Future<void> _save() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File(p.join(dir.path, _fileName));
      await file.writeAsString(
        jsonEncode([for (final g in _groups) g.toJson()]),
      );
    } catch (_) {}
  }

  Future<void> restoreDefaults() async {
    final defaults = await loadTopicTemplateGroups();
    _groups
      ..clear()
      ..addAll(defaults);
    await _save();
    notifyListeners();
  }

  // ---------- 分组 ----------

  Future<void> addGroup(String name, {String? description}) async {
    final n = name.trim();
    if (n.isEmpty || _groups.any((g) => g.name == n)) return;
    _groups.add(
      TopicTemplateGroup(
        name: n,
        description: (description?.trim().isEmpty ?? true)
            ? null
            : description!.trim(),
      ),
    );
    await _save();
    notifyListeners();
  }

  Future<void> updateGroup(
    int index, {
    required String name,
    String? description,
  }) async {
    if (index < 0 || index >= _groups.length) return;
    final n = name.trim();
    if (n.isEmpty) return;
    if (_groups.any((g) => g.name == n && _groups.indexOf(g) != index)) return;
    final desc = (description?.trim().isEmpty ?? true)
        ? null
        : description!.trim();
    _groups[index] = TopicTemplateGroup(
      name: n,
      description: desc,
      templates: _groups[index].templates,
    );
    await _save();
    notifyListeners();
  }

  Future<void> removeGroup(int index) async {
    if (index < 0 || index >= _groups.length) return;
    _groups.removeAt(index);
    await _save();
    notifyListeners();
  }

  // ---------- 组内模板 ----------

  Future<void> addTemplate(int groupIndex, TopicTemplate template) async {
    final label = template.label.trim();
    final topic = template.topic.trim();
    if (groupIndex < 0 || groupIndex >= _groups.length) return;
    if (label.isEmpty || topic.isEmpty) return;
    final g = _groups[groupIndex];
    _groups[groupIndex] = TopicTemplateGroup(
      name: g.name,
      description: g.description,
      templates: [
        ...g.templates,
        TopicTemplate(
          label: label,
          topic: topic,
          publish: template.publish,
          hint: template.hint,
        ),
      ],
    );
    await _save();
    notifyListeners();
  }

  Future<void> updateTemplate(
    int groupIndex,
    int templateIndex,
    TopicTemplate template,
  ) async {
    if (groupIndex < 0 ||
        groupIndex >= _groups.length ||
        templateIndex < 0 ||
        templateIndex >= _groups[groupIndex].templates.length) {
      return;
    }
    final label = template.label.trim();
    final topic = template.topic.trim();
    if (label.isEmpty || topic.isEmpty) return;
    final g = _groups[groupIndex];
    final items = [...g.templates];
    items[templateIndex] = TopicTemplate(
      label: label,
      topic: topic,
      publish: template.publish,
      hint: template.hint,
    );
    _groups[groupIndex] = TopicTemplateGroup(
      name: g.name,
      description: g.description,
      templates: items,
    );
    await _save();
    notifyListeners();
  }

  Future<void> removeTemplate(int groupIndex, int templateIndex) async {
    if (groupIndex < 0 ||
        groupIndex >= _groups.length ||
        templateIndex < 0 ||
        templateIndex >= _groups[groupIndex].templates.length) {
      return;
    }
    final g = _groups[groupIndex];
    final items = [...g.templates]..removeAt(templateIndex);
    _groups[groupIndex] = TopicTemplateGroup(
      name: g.name,
      description: g.description,
      templates: items,
    );
    await _save();
    notifyListeners();
  }
}

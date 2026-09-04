import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/topic_template.dart';
import 'app_state_db.dart';

/// 主题模板统一管理服务。
///
/// 首次启动把预设模板组（个人完整版 > 内置完整版 > 示例）写入统一
/// sqlite 运行时存储；之后用户可在「设置 · 主题模板」中增删改模板组
/// 与模板。运行时修改一律存 sqlite，程序更新/版本覆盖安装不影响；
/// 用户删除的组不会被内置默认「复活」。
class TopicTemplateService extends ChangeNotifier {
  final List<TopicTemplateGroup> _groups = [];

  List<TopicTemplateGroup> get groups => List.unmodifiable(_groups);

  Future<void> load() async {
    try {
      await AppStateDb.instance.migrateFileToKey(
        AppStateDb.topicTemplatesKey,
        'topic_templates.json',
      );
      final raw = await AppStateDb.instance.read(AppStateDb.topicTemplatesKey);
      if (raw != null) {
        final list = jsonDecode(raw) as List;
        _groups
          ..clear()
          ..addAll([
            for (final item in list)
              if (item is Map)
                TopicTemplateGroup.fromJson(item.cast<String, dynamic>()),
          ]);
      } else {
        // 首次运行：以个人完整版模板（缺失则示例）初始化运行时数据
        _groups
          ..clear()
          ..addAll(await loadTopicTemplateGroups());
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

  Future<void> _save() async {
    await AppStateDb.instance.write(
      AppStateDb.topicTemplatesKey,
      jsonEncode([for (final g in _groups) g.toJson()]),
    );
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

import 'dart:convert';

import 'package:flutter/services.dart';

/// 单个 MQTT 主题模板。
/// [topic] 为模板字符串，其中的 `$(变量名)` 占位符在选用时由「模板变量」替换。
class TopicTemplate {
  /// 模板名称（如「设备属性上报」）
  final String label;

  /// 主题模板（含 `$(变量)` 占位符）
  final String topic;

  /// 方向：true = 发布，false = 订阅
  final bool publish;

  /// 补充说明（可选）
  final String? hint;

  const TopicTemplate({
    required this.label,
    required this.topic,
    required this.publish,
    this.hint,
  });

  factory TopicTemplate.fromJson(Map<String, dynamic> json) => TopicTemplate(
    label: (json['label'] as String?) ?? '',
    topic: (json['topic'] as String?) ?? '',
    publish: (json['publish'] as bool?) ?? false,
    hint: json['hint'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'label': label,
    'topic': topic,
    'publish': publish,
    if (hint != null && hint!.isNotEmpty) 'hint': hint,
  };
}

/// 主题模板组：多个相关模板为一组，选择时先展示组、组内模板放二级列表项。
class TopicTemplateGroup {
  final String name;
  final String? description;
  final List<TopicTemplate> templates;

  const TopicTemplateGroup({
    required this.name,
    this.description,
    this.templates = const [],
  });

  factory TopicTemplateGroup.fromJson(Map<String, dynamic> json) =>
      TopicTemplateGroup(
        name: (json['name'] as String?) ?? '',
        description: json['description'] as String?,
        templates: [
          for (final item in (json['templates'] as List? ?? []))
            if (item is Map)
              TopicTemplate.fromJson(item.cast<String, dynamic>()),
        ],
      );

  Map<String, dynamic> toJson() => {
    'name': name,
    if (description != null && description!.isNotEmpty)
      'description': description,
    'templates': [for (final t in templates) t.toJson()],
  };
}

/// 完整版主题模板资源（本地可选，未随公开仓库发布）
const String kTopicTemplatesAssetFull =
    'assets/presets/topic_templates.full.json';

/// 公开版示例主题模板资源（随仓库发布）
const String kTopicTemplatesAssetPublic = 'assets/presets/topic_templates.json';

/// 加载主题模板组：优先完整版资源，缺失时回退公开版示例。
Future<List<TopicTemplateGroup>> loadTopicTemplateGroups() async {
  for (final asset in [kTopicTemplatesAssetFull, kTopicTemplatesAssetPublic]) {
    try {
      final raw = await rootBundle.loadString(asset);
      final list = jsonDecode(raw) as List;
      return [
        for (final item in list)
          if (item is Map)
            TopicTemplateGroup.fromJson(item.cast<String, dynamic>()),
      ];
    } catch (_) {
      // 尝试下一个资源
    }
  }
  return const [];
}

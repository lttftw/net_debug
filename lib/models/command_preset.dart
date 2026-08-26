import 'dart:convert';

import 'package:flutter/services.dart';

/// 常用指令预设（来源：内置 JSON 资源，见 [loadCommandPresets]）
class CommandPreset {
  final String label;
  final String command;
  final String? hint;

  const CommandPreset(this.label, this.command, {this.hint});

  factory CommandPreset.fromJson(Map<String, dynamic> json) => CommandPreset(
        json['label'] as String? ?? '',
        json['command'] as String? ?? '',
        hint: json['hint'] as String?,
      );
}

/// 快捷指令：内置预设、用户自定义、或覆盖内置的修改版
class QuickCommand {
  /// 数据库 id；内置预设为 null
  final int? id;

  final String label;
  final String command;
  final String? hint;

  /// 覆盖的内置预设索引；纯自定义为 null
  final int? overrideIndex;

  /// 内置预设索引；仅内置预设有效
  final int? builtinIndex;

  /// 是否为内置预设（未被覆盖）
  final bool isBuiltin;

  /// 是否为已覆盖的内置预设（有数据库 id 且 overrideIndex 非负）
  bool get isOverride => id != null && overrideIndex != null && overrideIndex! >= 0;

  const QuickCommand({
    this.id,
    required this.label,
    required this.command,
    this.hint,
    this.overrideIndex,
    this.builtinIndex,
    this.isBuiltin = false,
  });

  /// 由内置预设构造
  factory QuickCommand.builtin(CommandPreset p, int index) => QuickCommand(
        label: p.label,
        command: p.command,
        hint: p.hint,
        builtinIndex: index,
        isBuiltin: true,
      );

  /// 由数据库行构造
  factory QuickCommand.fromDb(Map<String, dynamic> row) => QuickCommand(
        id: row['id'] as int,
        label: row['label'] as String,
        command: row['command'] as String,
        hint: row['hint'] as String?,
        overrideIndex: row['override_index'] as int?,
      );
}

/// 完整版指令模板（本地可选，未随公开仓库发布）
const String kPresetsAssetFull = 'assets/presets/quick_commands.full.json';

/// 公开版示范模板（随仓库发布）
const String kPresetsAssetPublic = 'assets/presets/quick_commands.json';

/// 加载指令预设：优先尝试完整版资源，缺失时回退公开版示范模板。
/// 指令中的 `$(变量名)` 占位符（如 $(wifi_ssid)）在发送时由「模板变量」替换。
Future<List<CommandPreset>> loadCommandPresets() async {
  for (final asset in [kPresetsAssetFull, kPresetsAssetPublic]) {
    try {
      final raw = await rootBundle.loadString(asset);
      final list = jsonDecode(raw) as List;
      return [
        for (final item in list)
          if (item is Map)
            CommandPreset.fromJson(item.cast<String, dynamic>()),
      ];
    } catch (_) {
      // 尝试下一个资源
    }
  }
  return const [];
}
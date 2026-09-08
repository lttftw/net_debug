import 'dart:convert';

import 'package:flutter/services.dart';

/// 单条快捷指令（预设组内的一项）
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

  Map<String, dynamic> toJson() => {
        'label': label,
        'command': command,
        if (hint != null && hint!.isNotEmpty) 'hint': hint,
      };
}

/// 快捷指令预设组：多个相关指令为一组（类似主题模板的分组样式）
class CommandPresetGroup {
  final String name;
  final String? description;
  final List<CommandPreset> commands;

  const CommandPresetGroup({
    required this.name,
    this.description,
    this.commands = const [],
  });

  factory CommandPresetGroup.fromJson(Map<String, dynamic> json) =>
      CommandPresetGroup(
        name: (json['name'] as String?) ?? '',
        description: json['description'] as String?,
        commands: [
          for (final item in (json['commands'] as List? ?? []))
            if (item is Map)
              CommandPreset.fromJson(item.cast<String, dynamic>()),
        ],
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        if (description != null && description!.isNotEmpty)
          'description': description,
        'commands': [for (final c in commands) c.toJson()],
      };
}

/// 完整版指令模板（本地可选，未随公开仓库发布）
const String kPresetsAssetFull = 'assets/presets/quick_commands.full.json';

/// 公开版示范模板（随仓库发布）
const String kPresetsAssetPublic = 'assets/presets/quick_commands.json';

/// 完整版 MQTT 快捷指令（协议白名单子集）
const String kMqttPresetsAssetFull = 'assets/presets/mqtt_commands.full.json';

/// 公开版 MQTT 快捷指令示例
const String kMqttPresetsAssetPublic = 'assets/presets/mqtt_commands.json';

/// 完整版 Modbus 快捷指令（Modbus TCP 主站调试）
const String kModbusPresetsAssetFull = 'assets/presets/modbus_commands.full.json';

/// 公开版 Modbus 快捷指令示例
const String kModbusPresetsAssetPublic = 'assets/presets/modbus_commands.json';

/// 完整版串口快捷指令（串口调试）
const String kSerialPresetsAssetFull = 'assets/presets/serial_commands.full.json';

/// 公开版串口快捷指令示例
const String kSerialPresetsAssetPublic = 'assets/presets/serial_commands.json';

/// 解析预设 JSON：新版为分组数组 `[{name, description, commands:[...]}]`；
/// 兼容旧版扁平数组 `[{label, command, hint}]`，会包装成单个「预设指令」组。
List<CommandPresetGroup> _parsePresetGroups(String raw) {
  final list = jsonDecode(raw) as List;
  if (list.any((e) => e is Map && e.containsKey('commands'))) {
    return [
      for (final item in list)
        if (item is Map)
          CommandPresetGroup.fromJson(item.cast<String, dynamic>()),
    ];
  }
  final commands = [
    for (final item in list)
      if (item is Map)
        CommandPreset.fromJson(item.cast<String, dynamic>()),
  ];
  if (commands.isEmpty) return const [];
  return [
    CommandPresetGroup(name: '预设指令', commands: commands),
  ];
}

/// 加载指令预设组。
///
/// 模板来源唯一：**内嵌 assets**（随程序安装包发布）。完整版资源优先，
/// 公开示例仅作缺失回退；不做任何程序目录外部文件的读取或物化。
/// 指令中的 `$(变量名)` 占位符（如 $(wifi_ssid)）在发送时由「模板变量」替换。
Future<List<CommandPresetGroup>> loadCommandPresetGroups() =>
    _loadCommandPresetGroups(kPresetsAssetFull, kPresetsAssetPublic);

/// 加载 MQTT 快捷指令组（协议 MQTT 白名单子集，指令数比 TCP 少）。
/// 同样只从内嵌 assets 读取：完整版优先、公开示例回退。
Future<List<CommandPresetGroup>> loadMqttCommandPresetGroups() =>
    _loadCommandPresetGroups(kMqttPresetsAssetFull, kMqttPresetsAssetPublic);

/// 加载 Modbus 快捷指令组（Modbus TCP 主站功能码指令）。
/// 只从内嵌 assets 读取：完整版优先、公开示例回退。
Future<List<CommandPresetGroup>> loadModbusCommandPresetGroups() =>
    _loadCommandPresetGroups(kModbusPresetsAssetFull, kModbusPresetsAssetPublic);

/// 加载串口快捷指令组（AT / HEX 帧示例）。
Future<List<CommandPresetGroup>> loadSerialCommandPresetGroups() =>
    _loadCommandPresetGroups(kSerialPresetsAssetFull, kSerialPresetsAssetPublic);

Future<List<CommandPresetGroup>> _loadCommandPresetGroups(
  String fullAsset,
  String publicAsset,
) async {
  for (final asset in [fullAsset, publicAsset]) {
    try {
      final raw = await rootBundle.loadString(asset);
      return _parsePresetGroups(raw);
    } catch (_) {
      // 尝试下一个资源
    }
  }
  return const [];
}

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/command_preset.dart';
import 'app_state_db.dart';

/// 指令预设统一管理服务（按「组」组织，样式与主题模板一致）。
///
/// 四个通道各持一个实例（TCP / MQTT / Modbus / 串口），彼此独立。
/// 数据分层：
/// - 首次启动把预设指令组（个人完整版 > 内置完整版 > 示例）写入统一
///   sqlite 运行时存储（[AppStateDb]，TCP 默认 `tcp_commands`；MQTT 实例
///   使用独立 `mqtt_commands` key 与更小的白名单子集预设）；
/// - 之后用户可像主题模板一样新建/重命名/删除组、拖拽排序，并增删改
///   组内指令，全部运行时修改存 sqlite，程序更新/版本覆盖不影响；
/// - 「恢复默认」从预设整树重建（用户显式操作）。
class CommandPresetService extends ChangeNotifier {
  final List<CommandPresetGroup> _groups = [];

  /// 运行时数据在 [AppStateDb] 中的 key（TCP/MQTT/Modbus/串口各自独立）
  final String storageKey;

  /// 预设源加载器（TCP 完整指令集 / MQTT 白名单子集 / Modbus 功能码 / 串口帧）
  final Future<List<CommandPresetGroup>> Function() presetLoader;

  CommandPresetService({
    String? storageKey,
    Future<List<CommandPresetGroup>> Function()? presetLoader,
  })  : storageKey = storageKey ?? AppStateDb.tcpCommandsKey,
        presetLoader = presetLoader ?? loadTcpCommandPresetGroups;

  /// MQTT 快捷指令实例：独立运行时存储与更小的协议白名单预设
  factory CommandPresetService.mqtt() => CommandPresetService(
    storageKey: AppStateDb.mqttCommandsKey,
    presetLoader: loadMqttCommandPresetGroups,
  );

  /// Modbus 快捷指令实例：独立运行时存储与 Modbus 功能码预设
  factory CommandPresetService.modbus() => CommandPresetService(
    storageKey: AppStateDb.modbusCommandsKey,
    presetLoader: loadModbusCommandPresetGroups,
  );

  /// 串口快捷指令实例：独立运行时存储与 AT/HEX 帧预设
  factory CommandPresetService.serial() => CommandPresetService(
    storageKey: AppStateDb.serialCommandsKey,
    presetLoader: loadSerialCommandPresetGroups,
  );

  /// 运行时指令组（含组顺序与组内指令顺序）
  List<CommandPresetGroup> get groups => List.unmodifiable(_groups);

  /// 组内指令总数
  int get totalCount =>
      _groups.fold(0, (sum, g) => sum + g.commands.length);

  Future<void> load() async {
    try {
      final raw = await AppStateDb.instance.read(storageKey);
      if (raw != null) {
        final list = jsonDecode(raw) as List;
        _groups
          ..clear()
          ..addAll([
            for (final item in list)
              if (item is Map)
                CommandPresetGroup.fromJson(item.cast<String, dynamic>()),
          ]);
        notifyListeners();
        return;
      }
    } catch (_) {
      // 内容异常时回退预设
    }
    await restoreDefaults();
  }

  Future<void> _save() async {
    await AppStateDb.instance.write(
      storageKey,
      jsonEncode([for (final g in _groups) g.toJson()]),
    );
  }

  void _notifyAndSave() {
    notifyListeners();
    _save();
  }

  /// 以预设（个人完整版 > 内置完整版 > 示例）整体重建运行时组树。
  Future<void> restoreDefaults() async {
    _groups
      ..clear()
      ..addAll(await presetLoader());
    await _save();
    notifyListeners();
  }

  // ---------- 组 ----------

  Future<void> addGroup(String name, {String? description}) async {
    final n = name.trim();
    if (n.isEmpty || _groups.any((g) => g.name == n)) return;
    _groups.add(
      CommandPresetGroup(
        name: n,
        description: (description?.trim().isEmpty ?? true)
            ? null
            : description!.trim(),
      ),
    );
    _notifyAndSave();
  }

  Future<void> updateGroup(
    int index, {
    required String name,
    String? description,
  }) async {
    if (index < 0 || index >= _groups.length) return;
    final n = name.trim();
    if (n.isEmpty) return;
    if (_groups.any((g) => g.name == n && _groups.indexOf(g) != index)) {
      return;
    }
    final desc = (description?.trim().isEmpty ?? true)
        ? null
        : description!.trim();
    _groups[index] = CommandPresetGroup(
      name: n,
      description: desc,
      commands: _groups[index].commands,
    );
    _notifyAndSave();
  }

  Future<void> removeGroup(int index) async {
    if (index < 0 || index >= _groups.length) return;
    _groups.removeAt(index);
    _notifyAndSave();
  }

  Future<void> moveGroup(int from, int to) async {
    if (from == to ||
        from < 0 ||
        from >= _groups.length ||
        to < 0 ||
        to >= _groups.length) {
      return;
    }
    final moved = _groups.removeAt(from);
    _groups.insert(to, moved);
    _notifyAndSave();
  }

  // ---------- 组内指令 ----------

  Future<void> addCommand(
    int groupIndex, {
    required String label,
    required String command,
    String? hint,
  }) async {
    if (groupIndex < 0 || groupIndex >= _groups.length) return;
    final l = label.trim();
    final c = command.trim();
    if (l.isEmpty || c.isEmpty) return;
    final g = _groups[groupIndex];
    _groups[groupIndex] = CommandPresetGroup(
      name: g.name,
      description: g.description,
      commands: [
        ...g.commands,
        CommandPreset(l, c, hint: hint),
      ],
    );
    _notifyAndSave();
  }

  Future<void> updateCommand(
    int groupIndex,
    int commandIndex, {
    required String label,
    required String command,
    String? hint,
  }) async {
    if (groupIndex < 0 ||
        groupIndex >= _groups.length ||
        commandIndex < 0 ||
        commandIndex >= _groups[groupIndex].commands.length) {
      return;
    }
    final l = label.trim();
    final c = command.trim();
    if (l.isEmpty || c.isEmpty) return;
    final g = _groups[groupIndex];
    final items = [...g.commands];
    items[commandIndex] = CommandPreset(l, c, hint: hint);
    _groups[groupIndex] = CommandPresetGroup(
      name: g.name,
      description: g.description,
      commands: items,
    );
    _notifyAndSave();
  }

  Future<void> removeCommand(int groupIndex, int commandIndex) async {
    if (groupIndex < 0 ||
        groupIndex >= _groups.length ||
        commandIndex < 0 ||
        commandIndex >= _groups[groupIndex].commands.length) {
      return;
    }
    final g = _groups[groupIndex];
    final items = [...g.commands]..removeAt(commandIndex);
    _groups[groupIndex] = CommandPresetGroup(
      name: g.name,
      description: g.description,
      commands: items,
    );
    _notifyAndSave();
  }

  /// 组内指令排序（拖拽）。
  Future<void> moveCommand(int groupIndex, int from, int to) async {
    if (groupIndex < 0 || groupIndex >= _groups.length) return;
    final items = _groups[groupIndex].commands;
    if (from == to ||
        from < 0 ||
        from >= items.length ||
        to < 0 ||
        to >= items.length) {
      return;
    }
    final g = _groups[groupIndex];
    final moved = [...items];
    final item = moved.removeAt(from);
    moved.insert(to, item);
    _groups[groupIndex] = CommandPresetGroup(
      name: g.name,
      description: g.description,
      commands: moved,
    );
    _notifyAndSave();
  }
}

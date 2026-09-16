import 'package:flutter/material.dart';

import '../models/command_preset.dart';
import '../services/command_preset_service.dart';
import '../services/variables_service.dart';
import '../widgets/app_toast.dart';
import '../widgets/restore_confirm.dart';
import '../widgets/variable_text_field.dart';

/// 二级页：指令预设分组管理（TCP / MQTT / Modbus / 串口共用，标题由调用方指定）。
/// 指令按「组」组织，可新建/重命名/删除组、调整组顺序；
/// 组内指令可增删改并拖拽排序，运行时配置存 sqlite。
class CommandPresetsScreen extends StatefulWidget {
  final CommandPresetService service;
  final VariablesService variables;
  final String title;

  const CommandPresetsScreen({
    super.key,
    required this.service,
    required this.variables,
    this.title = '快捷指令',
  });

  @override
  State<CommandPresetsScreen> createState() => _CommandPresetsScreenState();
}

class _CommandPresetsScreenState extends State<CommandPresetsScreen> {
  CommandPresetService get _service => widget.service;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: ListenableBuilder(
        listenable: _service,
        builder: (context, _) {
          final groups = _service.groups;
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                child: Row(
                  children: [
                    Text(
                      '${groups.length} 组 · ${_service.totalCount} 条指令',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _showAddGroupDialog,
                      icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                      label: const Text('新建组'),
                    ),
                    TextButton.icon(
                      onPressed: () async {
                        if (!mounted) return;
                        if (await confirmRestoreDefaults(context, '快捷指令')) {
                          await _service.restoreDefaults();
                        }
                      },
                      icon: const Icon(Icons.restore, size: 18),
                      label: const Text('恢复默认'),
                    ),
                  ],
                ),
              ),
              if (groups.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                    child: Text('暂无分组，点击右上角「新建组」开始', style: TextStyle(color: Colors.grey)),
                  ),
                ),
              for (var gi = 0; gi < groups.length; gi++)
                _buildGroupCard(gi, groups[gi], groups.length),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '组内指令可拖拽右侧把手排序；拖拽分组卡片可调整组顺序（应用内操作实时保存）',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ---------- 组卡片 ----------

  Widget _buildGroupCard(int gi, CommandPresetGroup g, int groupCount) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        leading: Icon(Icons.folder_outlined, color: theme.colorScheme.primary),
        title: Text(g.name, style: const TextStyle(fontSize: 15)),
        subtitle: (g.description == null || g.description!.isEmpty)
            ? null
            : Text(
                g.description!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '组上移',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.arrow_upward, size: 16),
              onPressed: gi == 0 ? null : () => _service.moveGroup(gi, gi - 1),
            ),
            IconButton(
              tooltip: '组下移',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.arrow_downward, size: 16),
              onPressed: gi == groupCount - 1
                  ? null
                  : () => _service.moveGroup(gi, gi + 1),
            ),
            const Icon(Icons.expand_more),
          ],
        ),
        childrenPadding: const EdgeInsets.only(bottom: 8),
        children: [
          const Divider(height: 1, indent: 16, endIndent: 16),
          Row(
            children: [
              const Spacer(),
              TextButton.icon(
                onPressed: () => _showCommandEditor(groupIndex: gi),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('添加指令', style: TextStyle(fontSize: 12)),
              ),
              IconButton(
                tooltip: '编辑组',
                icon: const Icon(Icons.edit_outlined, size: 18),
                onPressed: () => _showGroupEditor(index: gi, group: g),
              ),
              IconButton(
                tooltip: '删除组',
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: () => _service.removeGroup(gi),
              ),
            ],
          ),
          if (g.commands.isEmpty)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '本组暂无指令',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            )
          else
            ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              onReorderItem: (oldIndex, newIndex) {
                if (oldIndex == newIndex) return;
                _service.moveCommand(gi, oldIndex, newIndex);
              },
              children: [
                for (var ci = 0; ci < g.commands.length; ci++)
                  _buildCommandTile(gi, ci, g.commands[ci]),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildCommandTile(int gi, int ci, CommandPreset c) {
    return ListTile(
      key: ValueKey('$gi-$ci-${c.label}'),
      dense: true,
      contentPadding: const EdgeInsets.only(left: 16, right: 8),
      leading: const Icon(Icons.code, size: 16),
      title: Text(
        c.label,
        style: const TextStyle(fontSize: 13),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        c.command,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.grey),
      ),
      onTap: () => _showCommandEditor(groupIndex: gi, commandIndex: ci, existing: c),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PopupMenuButton<String>(
            tooltip: '操作',
            onSelected: (action) => _handleCommandAction(gi, ci, action),
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'edit', child: Text('编辑')),
              PopupMenuItem(value: 'delete', child: Text('删除')),
            ],
          ),
          ReorderableDragStartListener(
            index: ci,
            child: const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Icon(Icons.drag_indicator, size: 20),
            ),
          ),
        ],
      ),
    );
  }

  void _handleCommandAction(int gi, int ci, String action) {
    switch (action) {
      case 'edit':
        _showCommandEditor(
          groupIndex: gi,
          commandIndex: ci,
          existing: _service.groups[gi].commands[ci],
        );
      case 'delete':
        _service.removeCommand(gi, ci);
    }
  }

  // ---------- 对话框 ----------

  Future<void> _showAddGroupDialog() => _showGroupEditor();

  Future<void> _showGroupEditor({int? index, CommandPresetGroup? group}) async {
    final nameCtrl = TextEditingController(text: group?.name ?? '');
    final descCtrl = TextEditingController(text: group?.description ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(group == null ? '新建分组' : '编辑分组'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              autofocus: true,
              decoration: const InputDecoration(labelText: '组名', isDense: true),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: descCtrl,
              decoration: const InputDecoration(
                labelText: '描述（可选）',
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final name = nameCtrl.text.trim();
    if (name.isEmpty) {
      showAppToast(context, '组名不能为空');
      return;
    }
    if (group == null) {
      await _service.addGroup(name, description: descCtrl.text.trim());
    } else {
      await _service.updateGroup(index!, name: name, description: descCtrl.text);
    }
  }

  Future<void> _showCommandEditor({
    required int groupIndex,
    int? commandIndex,
    CommandPreset? existing,
  }) async {
    final labelCtrl = TextEditingController(text: existing?.label ?? '');
    final cmdCtrl = TextEditingController(text: existing?.command ?? '');
    final hintCtrl = TextEditingController(text: existing?.hint ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? '添加指令' : '编辑指令'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: labelCtrl,
                autofocus: true,
                decoration: const InputDecoration(labelText: '名称', isDense: true),
              ),
              const SizedBox(height: 8),
              VariableAwareTextField(
                controller: cmdCtrl,
                variables: widget.variables,
                maxLines: 3,
                minLines: 1,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                labelText: '指令 (JSON，支持 \$(变量))',
              ),
              const SizedBox(height: 8),
              TextField(
                controller: hintCtrl,
                decoration: const InputDecoration(
                  labelText: '提示（可选）',
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final label = labelCtrl.text.trim();
    final command = cmdCtrl.text.trim();
    final hint = hintCtrl.text.trim();
    if (label.isEmpty || command.isEmpty) {
      showAppToast(context, '名称和指令不能为空');
      return;
    }
    final hintOrNull = hint.isEmpty ? null : hint;
    if (existing == null) {
      await _service.addCommand(
        groupIndex,
        label: label,
        command: command,
        hint: hintOrNull,
      );
    } else {
      await _service.updateCommand(
        groupIndex,
        commandIndex!,
        label: label,
        command: command,
        hint: hintOrNull,
      );
    }
  }
}

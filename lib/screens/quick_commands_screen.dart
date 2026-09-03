import 'package:flutter/material.dart';

import '../models/command_preset.dart';
import '../services/tcp_service.dart';
import '../services/variables_service.dart';
import '../widgets/app_toast.dart';
import '../widgets/variable_text_field.dart';

/// 二级页：快捷指令管理（TCP 工具）
class QuickCommandsScreen extends StatefulWidget {
  final TcpService service;
  final VariablesService variables;

  const QuickCommandsScreen({
    super.key,
    required this.service,
    required this.variables,
  });

  @override
  State<QuickCommandsScreen> createState() => _QuickCommandsScreenState();
}

class _QuickCommandsScreenState extends State<QuickCommandsScreen> {
  TcpService get _service => widget.service;

  /// 本地显示顺序：由 onReorder 直接修改并 setState，
  /// 不依赖 service 通知时序，保证拖拽落位立即生效。
  List<QuickCommand> _items = [];

  @override
  void initState() {
    super.initState();
    _items = _service.quickCommands.toList();
    _service.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    super.dispose();
  }

  /// 服务变化（增删改、恢复默认、拖拽后的持久化等）时同步本地列表
  void _onServiceChanged() {
    if (!mounted) return;
    setState(() => _items = _service.quickCommands.toList());
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: const Text('快捷指令')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: [
                Text(
                  '${items.length} 条指令',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _showAddQuickCommand,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('添加'),
                ),
                if (_service.hasHiddenBuiltins)
                  TextButton.icon(
                    onPressed: _service.restoreAllBuiltins,
                    icon: const Icon(Icons.restore, size: 18),
                    label: const Text('恢复全部'),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ReorderableListView(
              buildDefaultDragHandles: false,
              onReorderItem: (oldIndex, newIndex) {
                if (oldIndex == newIndex) return;
                // 1) 本地立即重排并重建，落位必定生效
                setState(() {
                  final moved = _items.removeAt(oldIndex);
                  _items.insert(newIndex, moved);
                });
                // 2) 同步 service 内存（TCP 页快捷栏联动）并异步持久化
                _service.moveQuickCommand(oldIndex, newIndex);
              },
              children: [
                for (var i = 0; i < items.length; i++)
                  _buildCommandTile(items[i], i),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '拖拽右侧把手可调整显示顺序\n'
              '点击指令自动替换变量后填入输入框，支持 \$(变量)',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ),
        ],
      ),
    );
  }

  /// 列表项稳定 key（内置/覆盖按内置索引，自定义按 id）
  String _keyFor(QuickCommand qc) {
    if (qc.isBuiltin || qc.isOverride) {
      return 'b${qc.builtinIndex ?? qc.overrideIndex}';
    }
    return 'c${qc.id}';
  }

  Widget _buildCommandTile(QuickCommand qc, int index) {
    return ListTile(
      key: ValueKey(_keyFor(qc)),
      dense: true,
      leading: Icon(
        qc.isBuiltin || qc.isOverride
            ? Icons.bookmark_outline
            : Icons.add_box_outlined,
        size: 18,
      ),
      title: Text(qc.label, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        qc.command,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          color: Colors.grey,
        ),
      ),
      onTap: () => _showQuickCommandEditor(existing: qc),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PopupMenuButton<String>(
            tooltip: '操作',
            onSelected: (action) => _handleCommandAction(qc, action),
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'edit', child: Text('编辑')),
              if (qc.isBuiltin && qc.isOverride)
                const PopupMenuItem(value: 'restore', child: Text('恢复默认')),
              PopupMenuItem(
                value: 'delete',
                child: Text(qc.isBuiltin ? '隐藏' : '删除'),
              ),
            ],
          ),
          ReorderableDragStartListener(
            index: index,
            child: const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Icon(Icons.drag_indicator, size: 20),
            ),
          ),
        ],
      ),
    );
  }

  void _handleCommandAction(QuickCommand qc, String action) {
    switch (action) {
      case 'edit':
        _showQuickCommandEditor(existing: qc);
      case 'restore':
        _service.restoreBuiltin(qc.builtinIndex!);
      case 'delete':
        if (qc.isBuiltin) {
          _service.hideBuiltin(qc.builtinIndex!);
        } else {
          _service.deleteQuickCommand(qc.id!);
        }
    }
  }

  Future<void> _showAddQuickCommand() => _showQuickCommandEditor();

  Future<void> _showQuickCommandEditor({QuickCommand? existing}) async {
    final labelCtrl = TextEditingController(text: existing?.label ?? '');
    final cmdCtrl = TextEditingController(text: existing?.command ?? '');
    final hintCtrl = TextEditingController(text: existing?.hint ?? '');
    final isBuiltin = existing?.isBuiltin ?? false;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? '添加快捷指令' : '编辑快捷指令'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: labelCtrl,
                decoration: const InputDecoration(
                  labelText: '名称',
                  isDense: true,
                ),
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
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;

    final label = labelCtrl.text.trim();
    final command = cmdCtrl.text.trim();
    final hint = hintCtrl.text.trim();
    if (label.isEmpty || command.isEmpty) {
      showAppToast(context, '名称和指令不能为空');
      return;
    }
    final hintOrNull = hint.isEmpty ? null : hint;
    if (existing == null) {
      await _service.addQuickCommand(label, command, hint: hintOrNull);
    } else if (isBuiltin) {
      await _service.overrideBuiltin(
        existing.builtinIndex!,
        label,
        command,
        hint: hintOrNull,
      );
    } else {
      await _service.updateQuickCommand(
        existing.id!,
        label,
        command,
        hint: hintOrNull,
      );
    }
  }
}

import 'package:flutter/material.dart';

import '../services/variables_service.dart';

/// 二级页：模板变量统一管理。
/// 所有模板（MQTT 主题模板 / client id / 快捷指令等）中的 `{变量名}`
/// 占位符都由此处的变量值替换。
class VariablesScreen extends StatefulWidget {
  final VariablesService service;

  const VariablesScreen({super.key, required this.service});

  @override
  State<VariablesScreen> createState() => _VariablesScreenState();
}

class _VariablesScreenState extends State<VariablesScreen> {
  VariablesService get _service => widget.service;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('模板变量'),
        actions: [
          IconButton(
            tooltip: '添加变量',
            icon: const Icon(Icons.add),
            onPressed: _showAddDialog,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _service,
        builder: (context, _) {
          final items = _service.items;
          return ListView(
            children: [
              for (final it in items)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.data_object, size: 18),
                  title: Text(
                    '\$(${it.name})',
                    style: const TextStyle(
                      fontSize: 14,
                      fontFamily: 'monospace',
                    ),
                  ),
                  subtitle: Text(
                    it.value.isEmpty
                        ? (it.hint.isEmpty ? '未设置' : it.hint)
                        : '${it.value}${it.hint.isEmpty ? '' : ' · ${it.hint}'}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  trailing: PopupMenuButton<String>(
                    tooltip: '操作',
                    onSelected: (action) => _handleAction(it, action),
                    itemBuilder: (context) => [
                      const PopupMenuItem(value: 'edit', child: Text('编辑')),
                      const PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                ),
              if (items.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(
                    child: Text(
                      '暂无变量，点击右上角 + 添加',
                      style: TextStyle(fontSize: 13, color: Colors.grey),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: OutlinedButton.icon(
                  onPressed: _service.restoreDefaults,
                  icon: const Icon(Icons.restore, size: 18),
                  label: const Text('恢复默认'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _handleAction(VariableItem it, String action) {
    switch (action) {
      case 'edit':
        _showEditDialog(it);
      case 'delete':
        _service.remove(it.name);
    }
  }

  Future<void> _showAddDialog() => _showEditor();

  Future<void> _showEditDialog(VariableItem it) => _showEditor(existing: it);

  Future<void> _showEditor({VariableItem? existing}) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final valueCtrl = TextEditingController(text: existing?.value ?? '');
    final hintCtrl = TextEditingController(text: existing?.hint ?? '');

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? '添加变量' : '编辑变量'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                enabled: existing == null,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: const InputDecoration(
                  labelText: '变量名（不含 \$()）',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: valueCtrl,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  labelText: '变量值',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: hintCtrl,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  labelText: '说明（可选）',
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

    final name = nameCtrl.text.trim();
    final value = valueCtrl.text.trim();
    final hint = hintCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('变量名不能为空')),
      );
      return;
    }
    if (existing == null) {
      await _service.add(name, value: value, hint: hint);
    } else {
      await _service.update(existing.name,
          value: value, hint: hint, newName: name);
    }
  }
}

import 'package:flutter/material.dart';

import '../models/topic_template.dart';
import '../services/topic_template_service.dart';
import '../widgets/app_toast.dart';
import '../widgets/restore_confirm.dart';

/// 二级页：主题模板管理（模板组 + 组内模板的增删改）。
/// 改动实时写入 TopicTemplateService，MQTT 页下拉选择模板时即时生效。
class TopicTemplateScreen extends StatefulWidget {
  final TopicTemplateService service;

  const TopicTemplateScreen({super.key, required this.service});

  @override
  State<TopicTemplateScreen> createState() => _TopicTemplateScreenState();
}

class _TopicTemplateScreenState extends State<TopicTemplateScreen> {
  TopicTemplateService get _service => widget.service;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('主题模板'),
        actions: [
          IconButton(
            tooltip: '添加模板组',
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: () => _showGroupEditor(),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _service,
        builder: (context, _) {
          final groups = _service.groups;
          return ListView(
            padding: const EdgeInsets.only(top: 6, bottom: 16),
            children: [
              for (var gi = 0; gi < groups.length; gi++)
                _buildGroupCard(gi, groups[gi]),
              if (groups.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(
                    child: Text(
                      '暂未添加主题模板组，点击右上角 + 添加',
                      style: TextStyle(fontSize: 13, color: Colors.grey),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: OutlinedButton.icon(
                  onPressed: () async {
                    if (!mounted) return;
                    if (await confirmRestoreDefaults(context, '主题模板')) {
                      await _service.restoreDefaults();
                    }
                  },
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

  Widget _buildGroupCard(int gi, TopicTemplateGroup g) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        // 默认收拢分组，避免模板组一多时页面过长
        leading: Icon(
          Icons.folder_outlined,
          color: Theme.of(context).colorScheme.primary,
        ),
        title: Text(g.name, style: const TextStyle(fontSize: 15)),
        subtitle: (g.description == null || g.description!.isEmpty)
            ? null
            : Text(
                g.description!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
        childrenPadding: const EdgeInsets.only(bottom: 8),
        children: [
          const Divider(height: 1, indent: 16, endIndent: 16),
          Row(
            children: [
              const Spacer(),
              TextButton.icon(
                onPressed: () => _showTemplateEditor(gi),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('添加模板', style: TextStyle(fontSize: 12)),
              ),
              IconButton(
                tooltip: '编辑组',
                icon: const Icon(Icons.edit_outlined, size: 18),
                onPressed: () => _showGroupEditor(index: gi),
              ),
              IconButton(
                tooltip: '删除组',
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: () => _service.removeGroup(gi),
              ),
            ],
          ),
          if (g.templates.isEmpty)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '本组暂无模板',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            ),
          for (var ti = 0; ti < g.templates.length; ti++)
            _buildTemplateTile(gi, ti, g.templates[ti]),
        ],
      ),
    );
  }

  Widget _buildTemplateTile(int gi, int ti, TopicTemplate t) {
    final dirColor = t.publish ? Colors.blue : Colors.teal;
    final dirLabel = t.publish ? '发布' : '订阅';
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 16, right: 8),
      leading: Icon(
        t.publish ? Icons.upload : Icons.download,
        size: 16,
        color: dirColor,
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              t.label,
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: dirColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              dirLabel,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: dirColor,
              ),
            ),
          ),
        ],
      ),
      subtitle: Text(
        t.topic,
        style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: PopupMenuButton<String>(
        tooltip: '操作',
        onSelected: (action) => _handleTemplateAction(gi, ti, action),
        itemBuilder: (context) => [
          const PopupMenuItem(value: 'edit', child: Text('编辑')),
          const PopupMenuItem(value: 'delete', child: Text('删除')),
        ],
      ),
    );
  }

  void _handleTemplateAction(int gi, int ti, String action) {
    switch (action) {
      case 'edit':
        _showTemplateEditor(gi, index: ti);
      case 'delete':
        _service.removeTemplate(gi, ti);
    }
  }

  // ---------- 分组编辑 ----------

  Future<void> _showGroupEditor({int? index}) async {
    final existing = index == null ? null : _service.groups[index];
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final descCtrl = TextEditingController(text: existing?.description ?? '');

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(index == null ? '添加模板组' : '编辑模板组'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  labelText: '组名',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: descCtrl,
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
    if (nameCtrl.text.trim().isEmpty) {
      _showSnack('组名不能为空');
      return;
    }
    if (index == null) {
      await _service.addGroup(nameCtrl.text, description: descCtrl.text);
    } else {
      await _service.updateGroup(
        index,
        name: nameCtrl.text,
        description: descCtrl.text,
      );
    }
  }

  // ---------- 模板编辑 ----------

  Future<void> _showTemplateEditor(int gi, {int? index}) async {
    final group = _service.groups[gi];
    final existing = (index == null || index >= group.templates.length)
        ? null
        : group.templates[index];
    final labelCtrl = TextEditingController(text: existing?.label ?? '');
    final topicCtrl = TextEditingController(text: existing?.topic ?? '');
    final hintCtrl = TextEditingController(text: existing?.hint ?? '');
    var publish = existing?.publish ?? true;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(index == null ? '添加模板' : '编辑模板'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: labelCtrl,
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    labelText: '模板名称（如 设备属性上报）',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: topicCtrl,
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  decoration: const InputDecoration(
                    labelText: '主题（支持 \$(变量)）',
                    hintText: '/sys/\$(pkey)/...',
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
                const SizedBox(height: 12),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('发布')),
                    ButtonSegment(value: false, label: Text('订阅')),
                  ],
                  selected: {publish},
                  onSelectionChanged: (s) => setLocal(() => publish = s.first),
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
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    if (labelCtrl.text.trim().isEmpty || topicCtrl.text.trim().isEmpty) {
      _showSnack('模板名称和主题不能为空');
      return;
    }
    final template = TopicTemplate(
      label: labelCtrl.text,
      topic: topicCtrl.text,
      publish: publish,
      hint: hintCtrl.text.trim().isEmpty ? null : hintCtrl.text.trim(),
    );
    if (index == null) {
      await _service.addTemplate(gi, template);
    } else {
      await _service.updateTemplate(gi, index, template);
    }
  }

  void _showSnack(String message) {
    showAppToast(context, message);
  }
}

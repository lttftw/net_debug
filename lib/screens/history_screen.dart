import 'package:flutter/material.dart';

import '../widgets/app_toast.dart';

/// 历史记录分区数据（指令历史 / 连接历史等）。
class HistorySection {
  final IconData icon;
  final String title;
  final String count;
  final bool canClear;
  final Future<void> Function() onClear;

  const HistorySection({
    required this.icon,
    required this.title,
    required this.count,
    required this.canClear,
    required this.onClear,
  });
}

/// 二级页：历史记录清理（TCP / MQTT 共用）。
///
/// 由使用方通过 [listenable] 与 [buildSections] 提供数据，
/// 列表变化时自动刷新，清空操作带确认弹窗。
class HistoryScreen extends StatefulWidget {
  final String title;
  final Listenable listenable;
  final List<HistorySection> Function() buildSections;

  const HistoryScreen({
    super.key,
    required this.title,
    required this.listenable,
    required this.buildSections,
  });

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: ListenableBuilder(
        listenable: widget.listenable,
        builder: (context, _) {
          final sections = widget.buildSections();
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              for (var i = 0; i < sections.length; i++) ...[
                if (i > 0) const SizedBox(height: 12),
                _buildCard(sections[i]),
              ],
              const SizedBox(height: 16),
              Text(
                '清空后不可恢复。',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildCard(HistorySection section) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(section.icon, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    section.title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  section.count,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: section.canClear ? () => _clear(section) : null,
                  icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                  label: const Text('清空'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _clear(HistorySection section) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('清空${section.title}'),
        content: Text('确定删除全部 ${section.count}${section.title}？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogCtx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await section.onClear();
    if (mounted) {
      showAppToast(context, '已清空');
    }
  }
}

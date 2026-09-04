import 'package:flutter/material.dart';

/// 最近连接历史区：供 TCP / MQTT 配置弹窗共用。
///
/// 以可点击回填的地址 chips 展示，右上角可选「清空」（带确认弹窗）。
/// [labels] 与数据源的顺序一一对应，[onSelected] 回调索引，由使用方回填输入框。
class RecentConnectionsSection extends StatelessWidget {
  final List<String> labels;
  final ValueChanged<int> onSelected;
  final Future<void> Function()? onClear;

  const RecentConnectionsSection({
    super.key,
    required this.labels,
    required this.onSelected,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    if (labels.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('最近连接', style: theme.textTheme.bodySmall),
            const Spacer(),
            if (onClear != null)
              TextButton(
                onPressed: () => _confirmClear(context),
                child: const Text('清空'),
              ),
          ],
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var i = 0; i < labels.length; i++)
              ActionChip(
                label: Text(labels[i]),
                onPressed: () => onSelected(i),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('清空连接历史'),
        content: const Text('确定删除全部连接历史？此操作不可恢复。'),
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
    if (ok == true) await onClear?.call();
  }
}

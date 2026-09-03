import 'package:flutter/material.dart';

import '../services/tcp_service.dart';
import '../widgets/app_toast.dart';

/// 二级页：历史记录清理（TCP 工具）
class HistoryScreen extends StatefulWidget {
  final TcpService service;

  const HistoryScreen({super.key, required this.service});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  TcpService get _service => widget.service;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('历史记录')),
      body: ListenableBuilder(
        listenable: _service,
        builder: (context, _) {
          final historyCount = _service.history.length;
          final connCount = _service.connections.length;
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _buildCard(
                icon: Icons.send_outlined,
                title: '指令历史',
                count: '$historyCount 条',
                canClear: historyCount > 0,
                onClear: _confirmClearCommandHistory,
              ),
              const SizedBox(height: 12),
              _buildCard(
                icon: Icons.link_off,
                title: '连接历史',
                count: '$connCount 条',
                canClear: connCount > 0,
                onClear: _confirmClearConnections,
              ),
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

  Widget _buildCard({
    required IconData icon,
    required String title,
    required String count,
    required bool canClear,
    required VoidCallback onClear,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  count,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: canClear ? onClear : null,
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

  Future<void> _confirmClearCommandHistory() => _confirmClear(
        '清空指令历史',
        '确定删除全部 ${_service.history.length} 条指令历史？此操作不可恢复。',
        _service.clearHistory,
      );

  Future<void> _confirmClearConnections() => _confirmClear(
        '清空连接历史',
        '确定删除全部 ${_service.connections.length} 条连接配置？此操作不可恢复。',
        _service.clearConnections,
      );

  Future<void> _confirmClear(
    String title,
    String message,
    Future<void> Function() action,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(title),
        content: Text(message),
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
    await action();
    if (mounted) {
      showAppToast(context, '已清空');
    }
  }
}

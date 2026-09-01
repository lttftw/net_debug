import 'package:flutter/material.dart';

import 'qr_tool_screen.dart';

/// 二级页：小工具合集入口，集中收纳各独立小工具。
class ToolsScreen extends StatelessWidget {
  const ToolsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('小工具合集')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 22, 4, 8),
                child: Text(
                  '编码与识别',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Card(
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  leading: Icon(
                    Icons.qr_code_2,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  title: const Text('文本与二维码互转'),
                  subtitle: Text(
                    '文本生成二维码 · 从图片识别二维码',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const QrToolScreen()),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

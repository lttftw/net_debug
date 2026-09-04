import 'package:flutter/material.dart';

/// 弹出「恢复默认」确认框。
///
/// 说明文案固定：将清除指定数据当前保存在 sqlite 中的运行时内容
/// （增删改与排序），并读取程序目录的预设文件为基准重新初始化，
/// 此操作不可撤销。
Future<bool> confirmRestoreDefaults(
  BuildContext context,
  String targetLabel,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(
        Icons.warning_amber_rounded,
        color: Theme.of(ctx).colorScheme.error,
      ),
      title: const Text('恢复默认'),
      content: Text(
        '将清除「$targetLabel」当前的自定义内容（sqlite 运行时数据，'
        '包括增删改与排序），并以程序目录的预设文件为基准重新初始化。\n\n'
        '此操作不可撤销，确定继续吗？',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('恢复默认'),
        ),
      ],
    ),
  );
  return ok == true;
}

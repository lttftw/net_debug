import 'package:flutter/material.dart';

import '../models/message_display_style.dart';

/// 日志/记录单条展示（TCP 与 MQTT 通用）：
/// 上行 = 时间戳 + 类型标签（+ 可选主题），下行 = 轻量底色的等宽消息文本。
class LogLineView extends StatelessWidget {
  final DateTime time;
  final String tag;
  final Color color;
  final Color? backgroundColor;
  final String message;
  final double fontSize;
  final MessageDisplayStyle displayStyle;

  /// 可选主题/来源标签，显示在时间戳行
  final String? label;

  const LogLineView({
    super.key,
    required this.time,
    required this.tag,
    required this.color,
    this.backgroundColor,
    required this.message,
    required this.fontSize,
    required this.displayStyle,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    final fillColor = backgroundColor ?? color;
    final displayMessage = formatMessageForDisplay(message, displayStyle);
    final t = time;
    final timeText =
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}.'
        '${t.millisecond.toString().padLeft(3, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                timeText,
                style: TextStyle(
                  color: Colors.grey.shade600,
                  fontSize: fontSize - 1,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: fillColor.withValues(
                    alpha: backgroundColor == null ? 0.15 : 0.20,
                  ),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  tag,
                  style: TextStyle(
                    color: color,
                    fontSize: fontSize - 2,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (label != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label!,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: color.withValues(alpha: 0.85),
                      fontSize: fontSize - 2,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 2),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: fillColor.withValues(
                alpha: backgroundColor == null ? 0.08 : 0.18,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            child: SelectableText(
              displayMessage,
              style: TextStyle(
                color: color,
                fontSize: fontSize,
                fontFamily: 'monospace',
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

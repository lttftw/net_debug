import 'dart:convert';

enum MessageDisplayStyle { original, formattedJson }

/// 仅格式化完整且有效的 JSON；普通文本与解析失败内容保持原样。
String formatMessageForDisplay(String message, MessageDisplayStyle style) {
  if (style == MessageDisplayStyle.original) return message;
  try {
    final value = jsonDecode(message);
    return const JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    return message;
  }
}

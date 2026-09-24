import 'dart:convert';

enum MessageDisplayStyle { original, formattedJson }

/// 格式化结果缓存的最大条数。
///
/// 消息区每次重建都会重算可见行的展示文本，高频收包时同一批消息会被
/// 反复重建；缓存可避免重复执行 `jsonDecode` + 缩进打印（消息越多收益越大）。
const int _maxCacheEntries = 256;

/// 超过该长度的消息不进入缓存，避免少量超大报文占满内存。
const int _maxCacheableLength = 32 * 1024;

final Map<String, String> _formatCache = <String, String>{};

/// 仅格式化完整且有效的 JSON；普通文本与解析失败内容保持原样。
///
/// 结果按「显示样式 + 原文」缓存，重复调用直接复用，语义与手工调用一致。
String formatMessageForDisplay(String message, MessageDisplayStyle style) {
  if (style == MessageDisplayStyle.original) return message;
  final key = '${style.name}\u0000$message';
  final cached = _formatCache[key];
  if (cached != null) return cached;
  final formatted = _formatJson(message);
  if (message.length <= _maxCacheableLength) {
    // 简单批量淘汰：清空后重新累积，避免维护 LRU 的额外开销
    if (_formatCache.length >= _maxCacheEntries) _formatCache.clear();
    _formatCache[key] = formatted;
  }
  return formatted;
}

String _formatJson(String message) {
  try {
    final value = jsonDecode(message);
    return const JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    return message;
  }
}

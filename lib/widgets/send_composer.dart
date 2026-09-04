import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/variables_service.dart';
import 'app_toast.dart';
import 'variable_text_field.dart';

/// 发送内容格式
enum ComposerFormat { json, text }

/// 通用发送内容输入组件（TCP 指令 / MQTT 内容共用）。
///
/// 能力：
/// - 多行 monospace 输入 + 内容清理按钮；
/// - 变量自动展开：发送前 `expand()` 展开 `$(变量)`，未填变量拦截并提示；
/// - JSON/文本格式切换 + JSON 格式化（JSON 模式可用）；
/// - 发送历史回溯（[history] 非空时显示历史按钮，[onClearHistory] 可选清空）；
/// - 变量插入按钮；
/// - 发送按钮：[onSend] 收到展开并校验后的内容，返回是否成功，成功则清空输入。
///
/// 主题、QoS、折叠展开等发送参数由使用页面负责；[collapsed] 简化态
/// 显示「编写…」按钮 + 发送按钮。
class SendComposer extends StatefulWidget {
  final TextEditingController controller;
  final VariablesService variables;
  final FocusNode? focusNode;
  final Future<bool> Function(String content) onSend;
  final String labelText;
  final String? hintText;
  final int minLines;
  final int maxLines;
  final ValueChanged<String>? onChanged;
  final List<String>? history;
  final Future<void> Function()? onClearHistory;
  final ComposerFormat initialFormat;
  final bool sending;
  final String sendLabel;
  final bool showInsertButton;
  final bool collapsed;
  final VoidCallback? onExpand;

  const SendComposer({
    super.key,
    required this.controller,
    required this.variables,
    required this.onSend,
    required this.labelText,
    this.focusNode,
    this.hintText,
    this.minLines = 2,
    this.maxLines = 6,
    this.onChanged,
    this.history,
    this.onClearHistory,
    this.initialFormat = ComposerFormat.json,
    this.sending = false,
    this.sendLabel = '发送',
    this.showInsertButton = true,
    this.collapsed = false,
    this.onExpand,
  });

  @override
  State<SendComposer> createState() => _SendComposerState();
}

class _SendComposerState extends State<SendComposer> {
  late ComposerFormat _format;

  @override
  void initState() {
    super.initState();
    _format = widget.initialFormat;
  }

  String? _validateJson(String text) {
    if (text.trim().isEmpty) return null;
    try {
      jsonDecode(text);
      return null;
    } on FormatException catch (e) {
      return e.message;
    }
  }

  void _snack(String message) {
    showAppToast(context, message);
  }

  void _formatPayload() {
    final text = widget.controller.text.trim();
    if (text.isEmpty) {
      _showFormatDialog('内容为空', '请先输入要格式化的 JSON 内容');
      return;
    }
    final err = _validateJson(text);
    if (err != null) {
      _showFormatDialog('不是有效的 JSON', 'JSON 语法错误：$err');
      return;
    }
    widget.controller.text = const JsonEncoder.withIndent('  ')
        .convert(jsonDecode(widget.controller.text));
  }

  /// 格式化失败时弹窗提示（非 JSON 内容）。
  Future<void> _showFormatDialog(String title, String message) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _clear() {
    widget.controller.clear();
    setState(() {});
  }

  Future<void> _send() async {
    final text = widget.controller.text.trim();
    if (text.isEmpty) {
      _snack('${widget.labelText}不能为空');
      return;
    }
    final missing = widget.variables.emptyVariableNames(text);
    if (missing.isNotEmpty) {
      _snack('变量 ${missing.map((n) => '\$($n)').join('、')} 未填写，无法展开');
      return;
    }
    final expanded = widget.variables.expand(text);
    if (_format == ComposerFormat.json) {
      final err = _validateJson(expanded);
      if (err != null) {
        _snack('JSON 语法错误: $err');
        return;
      }
    }
    final ok = await widget.onSend(expanded);
    if (ok && mounted) {
      widget.controller.clear();
      widget.focusNode?.requestFocus();
    }
  }

  void _showHistory() {
    final history = widget.history;
    if (history == null || history.isEmpty) {
      _snack('暂无历史记录');
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
              child: Row(
                children: [
                  Text(
                    '发送历史 (${history.length})',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  if (widget.onClearHistory != null)
                    TextButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        widget.onClearHistory!();
                      },
                      icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                      label: const Text('清空'),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final entry in history)
                    ListTile(
                      dense: true,
                      title: Text(
                        entry,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                        ),
                      ),
                      trailing: const Icon(Icons.north_west, size: 16),
                      onTap: () {
                        Navigator.pop(ctx);
                        widget.controller.text = entry;
                        widget.controller.selection = TextSelection.collapsed(
                          offset: entry.length,
                        );
                        setState(() {});
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.collapsed) {
      return SizedBox(
        height: 52,
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: widget.onExpand,
                icon: const Icon(Icons.data_object, size: 18),
                label: Text(
                  widget.controller.text.trim().isEmpty
                      ? '编写 ${widget.labelText}'
                      : widget.controller.text.trim().replaceAll('\n', ' '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: 8),
            _buildSendButton(),
          ],
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildField(),
        const SizedBox(height: 8),
        Row(
          children: [
            if (widget.history != null && widget.history!.isNotEmpty)
              IconButton.outlined(
                tooltip: '发送历史',
                style: _squareButtonStyle,
                onPressed: _showHistory,
                icon: const Icon(Icons.history, size: 18),
              ),
            const Spacer(),
            // JSON 格式化按钮始终占位：文本模式下禁用，
            // 避免切换模式时后续按键位置移动
            IconButton.outlined(
              tooltip: _format == ComposerFormat.json
                  ? '格式化 / 校验 JSON'
                  : '格式化 / 校验 JSON（需切到 JSON 模式）',
              style: _squareButtonStyle,
              onPressed:
                  _format == ComposerFormat.json ? _formatPayload : null,
              icon: const Icon(Icons.auto_fix_high, size: 18),
            ),
            const SizedBox(width: 8),
            _buildFormatDropdown(),
            const SizedBox(width: 8),
            _buildSendButton(),
          ],
        ),
      ],
    );
  }

  /// 操作按钮统一样式：40×40 圆角矩形，不高过同行其他按钮。
  ButtonStyle get _squareButtonStyle => IconButton.styleFrom(
    fixedSize: const Size.square(40),
    padding: EdgeInsets.zero,
  );

  /// JSON/文本格式切换：紧凑下拉框。
  /// 以最长文案「JSON」的实测宽度为固定宽度，两种模式一致且不折叠。
  Widget _buildFormatDropdown() {
    final scheme = Theme.of(context).colorScheme;
    // 与渲染使用完全一致的字样式（含主题字体），避免测量与渲染字体不一致
    // 导致宽度偏小、内容溢出；再留 4px 安全余量
    final labelStyle = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: scheme.onSurface,
      fontFamily: DefaultTextStyle.of(context).style.fontFamily,
    );
    final measure = TextPainter(
      text: TextSpan(text: 'JSON', style: labelStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    final width = measure.width + 2 + 16 + 12 + 2 + 4; // 文本+间距+箭头+内边距+边框+余量
    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          onPressed: () => setState(() => _format = ComposerFormat.text),
          child: const Text('文本'),
        ),
        MenuItemButton(
          onPressed: () => setState(() => _format = ComposerFormat.json),
          child: const Text('JSON'),
        ),
      ],
      builder: (context, controller, child) {
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () =>
              controller.isOpen ? controller.close() : controller.open(),
          child: Container(
            width: width,
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              border: Border.all(color: scheme.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _format == ComposerFormat.json ? 'JSON' : '文本',
                  style: labelStyle,
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.arrow_drop_down,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildField() {
    return Focus(
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.enter &&
            HardwareKeyboard.instance.isControlPressed) {
          _send();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: TextField(
        controller: widget.controller,
        focusNode: widget.focusNode,
        onChanged: (s) {
          widget.onChanged?.call(s);
          setState(() {});
        },
        minLines: widget.minLines,
        maxLines: widget.maxLines,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        decoration: InputDecoration(
          labelText: widget.labelText,
          hintText: widget.hintText,
          isDense: true,
          alignLabelWithHint: true,
          border: const OutlineInputBorder(),
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.controller.text.isNotEmpty)
                IconButton(
                  tooltip: '清空内容',
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: _clear,
                ),
              if (widget.showInsertButton)
                VariableInsertButton(
                  controller: widget.controller,
                  variables: widget.variables,
                ),
            ],
          ),
          suffixIconConstraints: const BoxConstraints(minHeight: 48),
        ),
      ),
    );
  }

  Widget _buildSendButton() {
    // 固定最小宽度：发送/发送中/发布文案不同也不会引起按键尺寸变化
    return FilledButton.icon(
      style: FilledButton.styleFrom(minimumSize: const Size(104, 46)),
      onPressed: widget.sending ? null : _send,
      icon: widget.sending
          ? const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.send, size: 18),
      label: Text(widget.sending ? '发送中' : widget.sendLabel),
    );
  }
}

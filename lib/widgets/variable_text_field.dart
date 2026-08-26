import 'package:flutter/material.dart';

import '../services/variables_service.dart';

/// 在 [controller] 光标处插入 `$(name)` 并把光标移到插入内容之后。
void insertVariableAtCursor(TextEditingController controller, String name) {
  final sel = controller.selection;
  final text = controller.text;
  final start = sel.isValid ? sel.start : text.length;
  final end = sel.isValid ? sel.end : text.length;
  final token = '\$($name)';
  final newText = text.replaceRange(start, end, token);
  controller.value = TextEditingValue(
    text: newText,
    selection: TextSelection.collapsed(offset: start + token.length),
  );
}

/// 任意输入框旁的「插入变量」按钮：弹出已定义变量列表，选中后在
/// [controller] 光标处插入 `$(变量名)`。没有任何变量时自动隐藏。
class VariableInsertButton extends StatelessWidget {
  final TextEditingController controller;
  final VariablesService variables;
  final double iconSize;
  final String? tooltip;

  const VariableInsertButton({
    super.key,
    required this.controller,
    required this.variables,
    this.iconSize = 18,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: variables,
      builder: (context, _) {
        final items = variables.items;
        if (items.isEmpty) return const SizedBox.shrink();
        return PopupMenuButton<String>(
          tooltip: tooltip ?? '插入变量',
          icon: Icon(Icons.data_object, size: iconSize),
          onSelected: (name) => insertVariableAtCursor(controller, name),
          itemBuilder: (context) => [
            for (final it in items)
              PopupMenuItem<String>(
                value: it.name,
                child: SizedBox(
                  width: 220,
                  child: Text(
                    '\$(${it.name}) · ${it.value.isEmpty ? '未填' : it.value}',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 可插入模板变量的输入框：右侧提供「插入变量」按钮，选中后在光标处
/// 插入 `$(变量名)`。发送时由「模板变量」统一展开。
class VariableAwareTextField extends StatelessWidget {
  final TextEditingController controller;
  final VariablesService variables;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final String? labelText;
  final String? hintText;
  final int? minLines;
  final int? maxLines;
  final TextStyle? style;
  final TextInputType? keyboardType;
  final bool showInsertButton;
  final bool bordered;
  final bool isDense;
  final bool alignLabelWithHint;
  final List<Widget> trailingSuffixes;

  const VariableAwareTextField({
    super.key,
    required this.controller,
    required this.variables,
    this.focusNode,
    this.onChanged,
    this.labelText,
    this.hintText,
    this.minLines,
    this.maxLines,
    this.style,
    this.keyboardType,
    this.showInsertButton = true,
    this.bordered = false,
    this.isDense = true,
    this.alignLabelWithHint = true,
    this.trailingSuffixes = const [],
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      minLines: minLines,
      maxLines: maxLines,
      style: style,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: labelText,
        hintText: hintText,
        isDense: isDense,
        alignLabelWithHint: alignLabelWithHint,
        border: bordered ? const OutlineInputBorder() : null,
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final w in trailingSuffixes) w,
            if (showInsertButton)
              VariableInsertButton(controller: controller, variables: variables),
          ],
        ),
        suffixIconConstraints: const BoxConstraints(minHeight: 48),
      ),
    );
  }
}

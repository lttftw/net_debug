import 'package:flutter/material.dart';

import '../models/message_display_style.dart';
import '../services/theme_service.dart';

/// 二级页：主题外观设置。主色（seed）与收发记录色统一在此配置。
class ThemeScreen extends StatefulWidget {
  final ThemeService theme;

  const ThemeScreen({super.key, required this.theme});

  @override
  State<ThemeScreen> createState() => _ThemeScreenState();
}

class _ThemeScreenState extends State<ThemeScreen> {
  ThemeService get _theme => widget.theme;

  /// 预设配色方案
  static const _presets = <(String, Color)>[
    ('青蓝', Color(0xFF26C6DA)),
    ('天蓝', Color(0xFF2196F3)),
    ('靛蓝', Color(0xFF3F51B5)),
    ('蓝绿', Color(0xFF009688)),
    ('紫色', Color(0xFF9C27B0)),
  ];

  Future<void> _pickColor(
    Color current,
    Future<void> Function(Color) set,
  ) async {
    final picked = await showDialog<Color>(
      context: context,
      builder: (ctx) => _ColorPicker(current: current),
    );
    if (picked != null) {
      await set(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('外观')),
      body: ListenableBuilder(
        listenable: _theme,
        builder: (context, _) {
          return ListView(
            children: [
              _sectionTitle('背景模式'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                      value: false,
                      label: Text('亮色'),
                      icon: Icon(Icons.light_mode_outlined, size: 16),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text('暗色'),
                      icon: Icon(Icons.dark_mode_outlined, size: 16),
                    ),
                  ],
                  selected: {_theme.isDark},
                  onSelectionChanged: (s) => _theme.setDark(s.first),
                ),
              ),
              _sectionTitle('主题主色'),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text(
                  '决定界面按钮、选中态、输入框聚焦等整体配色',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Wrap(
                  spacing: 10,
                  children: [
                    for (final (name, color) in _presets)
                      ChoiceChip(
                        label: Text(name),
                        selected:
                            _theme.seedColor.toARGB32() == color.toARGB32(),
                        onSelected: (_) => _theme.setSeed(color),
                      ),
                    ActionChip(
                      avatar: CircleAvatar(
                        backgroundColor: _theme.seedColor,
                        radius: 10,
                      ),
                      label: const Text('自定义'),
                      onPressed: () =>
                          _pickColor(_theme.seedColor, _theme.setSeed),
                    ),
                  ],
                ),
              ),
              const Divider(height: 24),
              _sectionTitle('收发记录色'),
              _colorTile(
                title: '发送 (TX)',
                color: _theme.txColor,
                onTap: () => _pickColor(_theme.txColor, _theme.setTx),
              ),
              _colorTile(
                title: '接收 (RX)',
                color: _theme.rxColor,
                onTap: () => _pickColor(_theme.rxColor, _theme.setRx),
              ),
              const Divider(height: 24),
              _sectionTitle('消息默认显示样式'),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  'JSON 格式化仅作用于有效 JSON，普通文本保持原样',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: SegmentedButton<MessageDisplayStyle>(
                  segments: const [
                    ButtonSegment(
                      value: MessageDisplayStyle.original,
                      label: Text('原始文本'),
                      icon: Icon(Icons.subject, size: 16),
                    ),
                    ButtonSegment(
                      value: MessageDisplayStyle.formattedJson,
                      label: Text('JSON 格式化'),
                      icon: Icon(Icons.data_object, size: 16),
                    ),
                  ],
                  selected: {_theme.messageDisplayStyle},
                  onSelectionChanged: (styles) =>
                      _theme.setMessageDisplayStyle(styles.first),
                ),
              ),
              const Divider(height: 24),
              _sectionTitle('日志字体大小'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Slider(
                        value: _theme.logFontSize,
                        min: 10,
                        max: 16,
                        divisions: 6,
                        label: '${_theme.logFontSize.round()}',
                        onChanged: (v) => _theme.setLogFontSize(v),
                      ),
                    ),
                    SizedBox(
                      width: 32,
                      child: Text(
                        '${_theme.logFontSize.round()}',
                        style: const TextStyle(
                          fontSize: 13,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: OutlinedButton.icon(
                  onPressed: _theme.reset,
                  icon: const Icon(Icons.restore, size: 18),
                  label: const Text('恢复默认外观'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(text, style: Theme.of(context).textTheme.titleSmall),
    );
  }

  Widget _colorTile({
    required String title,
    required Color color,
    required VoidCallback onTap,
  }) {
    return ListTile(
      dense: true,
      leading: CircleAvatar(backgroundColor: color, radius: 12),
      title: Text(title),
      subtitle: Text(
        '#${color.toARGB32().toRadixString(16).toUpperCase().padLeft(8, '0')}',
        style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
      ),
      trailing: const Icon(Icons.edit_outlined, size: 18),
      onTap: onTap,
    );
  }
}

/// 简易取色器：常用色板 + 滑块微调
class _ColorPicker extends StatefulWidget {
  final Color current;

  const _ColorPicker({required this.current});

  @override
  State<_ColorPicker> createState() => _ColorPickerState();
}

class _ColorPickerState extends State<_ColorPicker> {
  late Color _color = widget.current;

  static const _palette = <Color>[
    Color(0xFFF44336),
    Color(0xFFFF9800),
    Color(0xFFFFEB3B),
    Color(0xFF4CAF50),
    Color(0xFF009688),
    Color(0xFF26C6DA),
    Color(0xFF2196F3),
    Color(0xFF3F51B5),
    Color(0xFF9C27B0),
    Color(0xFFE91E63),
    Color(0xFF795548),
    Color(0xFF607D8B),
  ];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('选择颜色'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final c in _palette)
                  InkWell(
                    onTap: () => setState(() => _color = c),
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: _color == c
                            ? Border.all(color: Colors.white, width: 3)
                            : null,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              '当前: #${_color.toARGB32().toRadixString(16).toUpperCase().padLeft(8, '0')}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            const SizedBox(height: 12),
            // 红绿蓝滑块微调
            _slider('R', _color.r, 255, (v) => _color = _withR(v)),
            _slider('G', _color.g, 255, (v) => _color = _withG(v)),
            _slider('B', _color.b, 255, (v) => _color = _withB(v)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _color),
          child: const Text('确定'),
        ),
      ],
    );
  }

  Color _withR(double v) => Color.from(
    alpha: _color.a,
    red: v / 255,
    green: _color.g,
    blue: _color.b,
  );
  Color _withG(double v) => Color.from(
    alpha: _color.a,
    red: _color.r,
    green: v / 255,
    blue: _color.b,
  );
  Color _withB(double v) => Color.from(
    alpha: _color.a,
    red: _color.r,
    green: _color.g,
    blue: v / 255,
  );

  Widget _slider(
    String label,
    double value,
    double max,
    ValueChanged<double> on,
  ) {
    return Row(
      children: [
        SizedBox(
          width: 20,
          child: Text(label, style: const TextStyle(fontSize: 12)),
        ),
        Expanded(
          child: Slider(
            value: value,
            max: max,
            activeColor: _color,
            onChanged: on,
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(
            (value).round().toString(),
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          ),
        ),
      ],
    );
  }
}

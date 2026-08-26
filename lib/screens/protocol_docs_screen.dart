import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

/// 二级页：内嵌指令协议文档（Markdown 渲染，带悬浮目录）
class ProtocolDocsScreen extends StatefulWidget {
  const ProtocolDocsScreen({super.key});

  @override
  State<ProtocolDocsScreen> createState() => _ProtocolDocsScreenState();
}

class _ProtocolDocsScreenState extends State<ProtocolDocsScreen> {
  /// 完整版文档（本地可选，未随公开仓库发布）
  static const _fullAsset = 'assets/docs/TCP_JSON_PROTOCOL.full.md';

  /// 公开版示范文档（随仓库发布）
  static const _publicAsset = 'assets/docs/TCP_JSON_PROTOCOL.md';

  /// 宽度达到该值时显示常驻侧边目录，否则使用悬浮按钮 + 弹层目录
  static const _tocBreakpoint = 900.0;

  late final Future<String> _future = _load();
  final ScrollController _scrollController = ScrollController();

  /// 优先尝试完整版文档，缺失时回退公开版示范文档
  Future<String> _load() async {
    for (final asset in [_fullAsset, _publicAsset]) {
      try {
        return await rootBundle.loadString(asset);
      } catch (_) {
        // 尝试下一个资源
      }
    }
    return '文档加载失败';
  }

  /// 内容区 key，用于定位滚动视口以计算各标题的滚动偏移
  final GlobalKey _contentKey = GlobalKey();

  /// 文档标题（目录项，含各自 GlobalKey 与滚动偏移）
  List<_TocEntry> _headings = const [];

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  // ---------- 目录解析 / 定位 ----------

  List<_TocEntry> _parseHeadings(String content) {
    final result = <_TocEntry>[];
    try {
      void walk(List<md.Node> nodes) {
        for (final n in nodes) {
          if (n is md.Element) {
            final tag = n.tag;
            if (tag == 'h1' || tag == 'h2' || tag == 'h3' || tag == 'h4') {
              result.add(
                _TocEntry(
                  level: int.parse(tag.substring(1)),
                  title: n.textContent.trim(),
                ),
              );
            }
            if (n.children != null) walk(n.children!);
          }
        }
      }

      walk(md.Document().parse(content));
    } catch (_) {}
    return result;
  }

  /// 依据当前布局计算各标题在滚动空间中的偏移（标题置顶时所需的滚动量）。
  void _computeHeadingOffsets() {
    if (_headings.isEmpty) return;
    final ctx = _contentKey.currentContext;
    if (ctx == null) return;
    final renderObject = ctx.findRenderObject();
    if (renderObject == null) return;
    final viewport = RenderAbstractViewport.maybeOf(renderObject);
    if (viewport == null) return;
    for (final e in _headings) {
      final box = e.key.currentContext?.findRenderObject();
      if (box is RenderBox) {
        e.offset = viewport.getOffsetToReveal(box, 0.0).offset;
      }
    }
  }

  void _jumpTo(int index) {
    final ctx = _headings[index].key.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      alignment: 0.0,
    );
  }

  void _openTocSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.62,
          child: _TocView(
            controller: _scrollController,
            entries: _headings,
            onJump: (i) {
              Navigator.pop(context);
              _jumpTo(i);
            },
          ),
        ),
      ),
    );
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('协议文档')),
      body: FutureBuilder<String>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final content = snapshot.data ?? '';
          if (_headings.isEmpty) {
            _headings = _parseHeadings(content);
          }
          // 布局完成后重算标题偏移（含窗口尺寸变化）
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _computeHeadingOffsets(),
          );
          return LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= _tocBreakpoint) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _buildContent(content)),
                    _buildSideToc(),
                  ],
                );
              }
              return Stack(
                children: [
                  Positioned.fill(child: _buildContent(content)),
                  Positioned(
                    right: 16,
                    bottom: 16,
                    child: FloatingActionButton.small(
                      heroTag: 'docs_toc_fab',
                      tooltip: '目录',
                      onPressed: _headings.isEmpty ? null : _openTocSheet,
                      child: const Icon(Icons.menu_book_outlined),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildContent(String content) {
    final headingBuilder = _HeadingBuilder(_headings);
    return SingleChildScrollView(
      controller: _scrollController,
      child: Padding(
        key: _contentKey,
        padding: const EdgeInsets.all(16),
        child: MarkdownBody(
          data: content,
          selectable: true,
          styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
          builders: {
            // 指令块：一键复制
            'pre': _CopyableCodeBlockBuilder(),
            // 标题：挂载 GlobalKey 供目录定位
            'h1': headingBuilder,
            'h2': headingBuilder,
            'h3': headingBuilder,
            'h4': headingBuilder,
          },
        ),
      ),
    );
  }

  Widget _buildSideToc() {
    final theme = Theme.of(context);
    return Container(
      width: 240,
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: _TocView(
        controller: _scrollController,
        entries: _headings,
        onJump: _jumpTo,
      ),
    );
  }
}

/// 目录项：标题层级、文本、定位用 GlobalKey 及计算出的滚动偏移
class _TocEntry {
  final int level;
  final String title;
  final GlobalKey key;
  double? offset;

  _TocEntry({required this.level, required this.title}) : key = GlobalKey();
}

/// 目录视图：监听滚动，高亮当前章节；可复用于侧边栏与底部弹层。
class _TocView extends StatefulWidget {
  final ScrollController controller;
  final List<_TocEntry> entries;
  final void Function(int index) onJump;

  const _TocView({
    required this.controller,
    required this.entries,
    required this.onJump,
  });

  @override
  State<_TocView> createState() => _TocViewState();
}

class _TocViewState extends State<_TocView> {
  int _active = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    final off = widget.controller.offset;
    var active = 0;
    for (var i = 0; i < widget.entries.length; i++) {
      final o = widget.entries[i].offset;
      if (o == null) continue;
      if (o <= off + 4) active = i;
    }
    if (active != _active) setState(() => _active = active);
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.entries;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          child: Text('目录', style: Theme.of(context).textTheme.titleSmall),
        ),
        for (var i = 0; i < entries.length; i++) _buildItem(i),
      ],
    );
  }

  Widget _buildItem(int index) {
    final e = widget.entries[index];
    final active = index == _active;
    final theme = Theme.of(context);
    final indent = (e.level - 1) * 12.0;
    return InkWell(
      onTap: () => widget.onJump(index),
      child: Container(
        color: active
            ? theme.colorScheme.primary.withValues(alpha: 0.10)
            : null,
        padding: EdgeInsets.only(
          left: 8 + indent,
          right: 8,
          top: 6,
          bottom: 6,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1, right: 6),
              child: Icon(
                active ? Icons.arrow_right : Icons.circle,
                size: active ? 16 : 6,
                color: active
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outline,
              ),
            ),
            Expanded(
              child: Text(
                e.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.3,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  color: active
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 标题构建器：按文档顺序把 `h1`~`h4` 逐个挂到 _TocEntry 的 GlobalKey 上。
class _HeadingBuilder extends MarkdownElementBuilder {
  final List<_TocEntry> entries;
  int _index = 0;

  _HeadingBuilder(this.entries);

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    if (_index >= entries.length) return null;
    final entry = entries[_index];
    _index++;
    final style = (preferredStyle ?? const TextStyle(fontWeight: FontWeight.w600))
        .copyWith(height: 1.35);
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 6),
      child: SelectableText(
        element.textContent.trim(),
        key: entry.key,
        style: style,
      ),
    );
  }
}

/// 为 `pre` 代码块注入「一键复制」按钮的自定义构建器。
/// 仅替换代码块内部内容；外层圆角背景（codeblockDecoration）仍由
/// flutter_markdown 包裹，视觉样式与默认保持一致。
class _CopyableCodeBlockBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    return _CodeBlock(code: element.textContent, style: preferredStyle);
  }
}

/// 代码块内容：横向可滚动 + 右上角一键复制按钮。
/// 用 SizedBox 撑满宽度，保持与 markdown 默认代码块一致的整行背景。
class _CodeBlock extends StatelessWidget {
  final String code;
  final TextStyle? style;

  const _CodeBlock({required this.code, this.style});

  @override
  Widget build(BuildContext context) {
    // 右侧预留按钮空间，避免代码文字被复制按钮遮挡
    const padding = EdgeInsets.fromLTRB(8, 8, 44, 8);
    final codeStyle = (style ?? const TextStyle(fontFamily: 'monospace'))
        .copyWith(height: 1.4);
    return SizedBox(
      width: double.infinity,
      child: Stack(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: padding,
            child: SelectableText(code, style: codeStyle),
          ),
          Positioned(
            top: 2,
            right: 2,
            child: _CopyButton(code: code),
          ),
        ],
      ),
    );
  }
}

/// 复制按钮：点击复制代码到剪贴板，短暂显示对勾作为反馈
class _CopyButton extends StatefulWidget {
  final String code;

  const _CopyButton({required this.code});

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    final copyText = widget.code.endsWith('\n')
        ? widget.code.substring(0, widget.code.length - 1)
        : widget.code;
    await Clipboard.setData(ClipboardData(text: copyText));
    if (!mounted) return;
    setState(() => _copied = true);
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('已复制到剪贴板'),
          duration: Duration(milliseconds: 1200),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.85),
      shape: const CircleBorder(),
      child: IconButton(
        tooltip: '复制指令',
        visualDensity: VisualDensity.compact,
        iconSize: 15,
        padding: const EdgeInsets.all(4),
        constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
        onPressed: _copy,
        icon: Icon(
          _copied ? Icons.check : Icons.copy,
          size: 15,
          color: _copied
              ? Colors.greenAccent
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
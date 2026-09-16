import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../widgets/app_toast.dart';

/// 二级页：内嵌指令协议文档（Markdown 渲染，带悬浮目录）。
///
/// 两种模式：
/// - 多文档模式（未传 [assetPath]）：展示内置的 TCP / MQTT / Modbus
///   三份协议文档，顶栏提供切换按键（PopupMenu）在几份文档间切换；
/// - 单文档模式（传入 [assetPath]，如 OTA 文档入口）：只加载指定文档，
///   不显示切换按键。
///
/// 加载机制（懒加载）：
/// - 内容进程内缓存：按文档键控，首次打开时从 assets 读取并切分为章节，
///   之后复用；
/// - 章节懒渲染：ListView.builder 只构建视口附近的章节，
///   长文档打开不再整页一次性渲染；
/// - 目录跳转：目标章节已构建则直接滚到精确偏移；未构建则按已测
///   章节的平均高度估算位置快速跳转，随后帧间修正到精确位置。
class ProtocolDocsScreen extends StatefulWidget {
  /// 自定义文档资产路径；为 null 时使用内置多文档模式（TCP/MQTT/Modbus）
  final String? assetPath;

  /// 页面标题
  final String title;

  const ProtocolDocsScreen({
    super.key,
    this.assetPath,
    this.title = '协议文档',
  });

  @override
  State<ProtocolDocsScreen> createState() => _ProtocolDocsScreenState();
}

/// 文档分节数据（不可变，进程内缓存共享）
class _DocSection {
  /// 标题层级（h1~h4）；null 表示首个标题之前的正文前言
  final int? level;
  final String title;
  final String text;

  const _DocSection({required this.level, required this.title, required this.text});
}

/// 文档缓存：加载 + 切分的结果
class _DocCache {
  final List<_DocSection> sections;

  const _DocCache(this.sections);
}

/// 一份可切换文档的资产配置：完整版优先、公开版示范回退
class _DocEntry {
  final String label;
  final String fullAsset;
  final String publicAsset;

  const _DocEntry(this.label, this.fullAsset, this.publicAsset);
}

/// 分节的页面级运行时视图。
/// GlobalKey 与测量出的偏移属于当前页面实例，不能跨实例复用。
class _SectionView {
  final _DocSection section;
  final GlobalKey key = GlobalKey();

  /// 构建后测量：滚动偏移与高度；未构建的章节为 null
  double? offset;
  double? height;

  _SectionView(this.section);
}

class _ProtocolDocsScreenState extends State<ProtocolDocsScreen> {
  /// 内置多文档清单：TCP / MQTT / Modbus（完整版优先，公开示范版回退）
  static const _builtinDocs = <_DocEntry>[
    _DocEntry(
      'TCP',
      'assets/docs/TCP_JSON_PROTOCOL.full.md',
      'assets/docs/TCP_JSON_PROTOCOL.md',
    ),
    _DocEntry(
      'MQTT',
      'assets/docs/MQTT_PROTOCOL.full.md',
      'assets/docs/MQTT_PROTOCOL.md',
    ),
    _DocEntry(
      'Modbus',
      'assets/docs/MODBUS_TCP_PROTOCOL.full.md',
      'assets/docs/MODBUS_TCP_PROTOCOL.md',
    ),
  ];

  /// 宽度达到该值时显示常驻侧边目录，否则使用悬浮按钮 + 弹层目录
  static const _tocBreakpoint = 900.0;

  /// 预构建范围（视口外提前构建的像素高度），兼顾滚动流畅度与懒加载
  static const _cacheExtent = 1200.0;

  /// 目录跳转的最大修正次数（防止极长文档估算不收敛）
  static const _maxJumpAttempts = 10;

  static final _headingRe = RegExp(r'^ {0,3}(#{1,4})\s+(.*)$');

  /// 进程内缓存：按资产路径键控，内容加载 + 章节切分每份文档只执行一次
  static final Map<String, Future<_DocCache>> _cacheFutures = {};

  /// 是否为多文档模式（未显式指定 assetPath）
  bool get _multiDoc => widget.assetPath == null;

  /// 当前文档索引（多文档模式）
  int _docIndex = 0;

  late Future<_DocCache> _future = _load();
  final ScrollController _scrollController = ScrollController();

  List<_SectionView> _sections = const [];
  List<_SectionView> _toc = const [];
  bool _ready = false;
  double? _lastWidth;
  bool _measureQueued = false;
  bool _jumping = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_queueMeasure);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final width = MediaQuery.sizeOf(context).width;
    if (_lastWidth != null && _lastWidth != width) {
      // 宽度变化导致重新布局，已测偏移全部失效，重建后重新测量
      for (final s in _sections) {
        s.offset = null;
        s.height = null;
      }
      _queueMeasure();
    }
    _lastWidth = width;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  // ---------- 加载与切分 ----------

  Future<_DocCache> _load() {
    // 缓存键统一用「当前要加载的文档」
    final key = _currentAsset;
    return _cacheFutures.putIfAbsent(key, () => _loadAndSplit(key));
  }

  /// 当前要加载的资产路径：
  /// - 单文档模式：显式指定的资产；
  /// - 多文档模式：当前条目的完整版资产（缺失时在 _loadAndSplit 内回退公开版）
  String get _currentAsset =>
      widget.assetPath ?? _builtinDocs[_docIndex].fullAsset;

  /// 加载并切分一份文档。
  ///
  /// 内置多文档模式按「完整版优先、公开版示范回退」顺序尝试；
  /// 显式指定的单文档（如 OTA）直接加载，失败时给出错误章节。
  static Future<_DocCache> _loadAndSplit(String asset) async {
    // 完整版资产是否属于内置清单（决定是否需要公开版回退）
    _DocEntry? entry;
    for (final e in _builtinDocs) {
      if (e.fullAsset == asset) {
        entry = e;
        break;
      }
    }
    if (entry != null) {
      for (final a in [entry.fullAsset, entry.publicAsset]) {
        try {
          return _splitSections(await rootBundle.loadString(a));
        } catch (_) {
          // 尝试下一个资源
        }
      }
      return const _DocCache([
        _DocSection(level: null, title: '', text: '文档加载失败'),
      ]);
    }
    try {
      return _splitSections(await rootBundle.loadString(asset));
    } catch (_) {
      return const _DocCache([
        _DocSection(level: null, title: '', text: '文档加载失败'),
      ]);
    }
  }

  /// 多文档模式下切换当前文档：重建加载 Future 并重置分节/滚动状态。
  void _switchDoc(int index) {
    if (index < 0 || index >= _builtinDocs.length || index == _docIndex) return;
    setState(() {
      _docIndex = index;
      _future = _load();
      _sections = const [];
      _toc = const [];
      _ready = false;
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    });
  }

  /// 按标题行（h1~h4）切分文档；代码围栏内的 `#` 不视为标题。
  /// 行尾先统一为 LF：CRLF 文件中 `split('\n')` 的行尾会残留 `\r`，
  /// 导致标题正则的 `(.*)$` 失配（`.` 与 `$` 均不跨越 `\r`），
  /// 全部标题识别失败、整篇文档退化为单个章节。
  static _DocCache _splitSections(String content) {
    final normalized = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final sections = <_DocSection>[];
    final buf = <String>[];
    var inFence = false;
    var level = 0;
    var title = '';

    void flush() {
      if (buf.isNotEmpty) {
        sections.add(_DocSection(
          level: level == 0 ? null : level,
          title: title,
          text: buf.join('\n'),
        ));
      }
      buf.clear();
    }

    for (final line in normalized.split('\n')) {
      if (line.trimLeft().startsWith('```')) {
        inFence = !inFence;
        buf.add(line);
        continue;
      }
      final m = inFence ? null : _headingRe.firstMatch(line);
      if (m != null) {
        flush();
        level = m.group(1)!.length;
        title = _stripInline(m.group(2)!);
        buf.add(line);
      } else {
        buf.add(line);
      }
    }
    flush();
    return _DocCache(sections);
  }

  /// 去掉标题行内的行内标记（加粗/斜体/代码等）供目录显示
  static String _stripInline(String s) => s
      .replaceAll(RegExp(r'\s+#+\s*$'), '')
      .replaceAll(RegExp(r'[*`_]'), '')
      .trim();

  // ---------- 偏移测量 ----------

  /// 滚动或布局变化后，在帧末测量新构建章节的偏移（去抖：每帧至多一次）
  void _queueMeasure() {
    if (_measureQueued || !mounted) return;
    _measureQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureQueued = false;
      if (mounted) _measureBuilt();
    });
  }

  void _measureBuilt() {
    for (final s in _sections) {
      if (s.offset != null) continue;
      final ctx = s.key.currentContext;
      // 元素可能处于 inactive/failed 状态（跳转触发列表重建时被停用、
      // 或构建异常遗留），此时 findRenderObject 会抛异常，跳过测量
      if (ctx == null || !ctx.mounted) continue;
      final RenderBox? ro;
      try {
        ro = ctx.findRenderObject() as RenderBox?;
      } catch (_) {
        continue;
      }
      if (ro == null) continue;
      final viewport = RenderAbstractViewport.maybeOf(ro);
      if (viewport == null) continue;
      s.offset = viewport.getOffsetToReveal(ro, 0.0).offset;
      s.height = ro.size.height;
    }
  }

  // ---------- 目录跳转 ----------

  Future<void> _jumpTo(int index) async {
    if (index < 0 || index >= _toc.length) return;
    if (!_scrollController.hasClients || _jumping) return;
    _jumping = true;
    try {
      final target = _toc[index];
      if (target.offset != null) {
        await _scrollTo(target.offset!);
        return;
      }
      // 目标章节尚未构建：按已测章节的平均高度估算位置快速跳转，
      // 帧间逐步构建并修正，直到测出目标章节的精确偏移。
      for (var attempt = 0; attempt < _maxJumpAttempts; attempt++) {
        final estimate = _estimateOffset(target);
        if (estimate == null) break;
        _scrollController.jumpTo(
          estimate.clamp(0.0, _scrollController.position.maxScrollExtent),
        );
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
        _measureBuilt();
        if (target.offset != null) {
          await _scrollTo(target.offset!);
          return;
        }
      }
      // 估算未收敛（文档极长）：跳到底部由用户继续微调
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    } finally {
      _jumping = false;
    }
  }

  Future<void> _scrollTo(double offset) => _scrollController.animateTo(
        offset,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );

  /// 从最近已测量边界 + 平均章节高度外推目标偏移
  double? _estimateOffset(_SectionView target) {
    var sum = 0.0;
    var count = 0;
    for (final s in _sections) {
      final h = s.height;
      if (h != null) {
        sum += h;
        count++;
      }
    }
    if (count == 0) return null;
    final avg = sum / count;
    final idx = _sections.indexOf(target);
    var base = 0.0;
    var baseIdx = -1;
    for (var i = 0; i < idx; i++) {
      final off = _sections[i].offset;
      if (off != null) {
        base = off;
        baseIdx = i;
      }
    }
    return base + (idx - baseIdx - 1) * avg;
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
            entries: _toc,
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
    final multi = _multiDoc;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          multi ? '${widget.title} · ${_builtinDocs[_docIndex].label}' : widget.title,
        ),
        actions: [
          if (multi)
            PopupMenuButton<int>(
              tooltip: '切换文档',
              icon: const Icon(Icons.swap_horiz),
              initialValue: _docIndex,
              onSelected: _switchDoc,
              itemBuilder: (context) => [
                for (var i = 0; i < _builtinDocs.length; i++)
                  PopupMenuItem<int>(
                    value: i,
                    child: Row(
                      children: [
                        Icon(
                          i == _docIndex ? Icons.check : Icons.code,
                          size: 18,
                          color: i == _docIndex
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                        const SizedBox(width: 10),
                        Text(_builtinDocs[i].label),
                      ],
                    ),
                  ),
              ],
            ),
        ],
      ),
      body: FutureBuilder<_DocCache>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!_ready && snapshot.data != null) {
            _ready = true;
            _sections = [
              for (final s in snapshot.data!.sections) _SectionView(s),
            ];
            _toc = [
              for (final s in _sections)
                if (s.section.level != null) s,
            ];
            _queueMeasure();
          }
          return LayoutBuilder(
            builder: (context, constraints) {
              final list = _buildList();
              if (constraints.maxWidth >= _tocBreakpoint) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: list),
                    _buildSideToc(),
                  ],
                );
              }
              return Stack(
                children: [
                  Positioned.fill(child: list),
                  Positioned(
                    right: 16,
                    bottom: 16,
                    child: FloatingActionButton.small(
                      heroTag: 'docs_toc_fab',
                      tooltip: '目录',
                      onPressed: _toc.isEmpty ? null : _openTocSheet,
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

  /// 章节懒渲染列表：只构建视口 + cacheExtent 范围内的章节
  Widget _buildList() {
    return ListView.builder(
      controller: _scrollController,
      scrollCacheExtent: const ScrollCacheExtent.pixels(_cacheExtent),
      padding: const EdgeInsets.symmetric(vertical: 10),
      itemCount: _sections.length,
      itemBuilder: (context, index) {
        final s = _sections[index];
        return Padding(
          key: s.key,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: MarkdownBody(
            data: s.section.text,
            selectable: true,
            styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
            builders: {
              // 指令块：一键复制
              'pre': _CopyableCodeBlockBuilder(),
            },
          ),
        );
      },
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
        entries: _toc,
        onJump: _jumpTo,
      ),
    );
  }
}

/// 目录视图：监听滚动，高亮当前章节；可复用于侧边栏与底部弹层。
class _TocView extends StatefulWidget {
  final ScrollController controller;
  final List<_SectionView> entries;
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
    final indent = (e.section.level! - 1) * 12.0;
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
                e.section.title,
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

/// 为 `pre` 代码块注入「一键复制」按钮的自定义构建器。
/// 仅替换代码块内部内容；外层圆角背景（codeblockDecoration）仍由
/// flutter_markdown 包裹，视觉样式与默认保持一致。
class _CopyableCodeBlockBuilder extends MarkdownElementBuilder {
  /// 必须返回非 null：flutter_markdown 的 visitText 对注册了自定义
  /// 构建器的块标签会改调此方法，返回 null 会导致代码文本不进入
  /// 内联记账，`pre` 块结束后内联列表无法清空，最终触发
  /// `assert(_inlines.isEmpty)`（章节以代码围栏结尾时必然复现）。
  /// 返回的内容仅用于记账，实际渲染由 visitElementAfterWithContext
  /// 返回的 _CodeBlock 替换，不会重复显示。
  @override
  Widget? visitText(md.Text text, TextStyle? preferredStyle) {
    return Text(text.text, style: preferredStyle);
  }

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
    showAppToast(context, '已复制到剪贴板');
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

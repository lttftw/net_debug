import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_toast.dart';

/// 通信消息区统一容器（TCP / MQTT / 串口 / Modbus / 系统日志共用）。
///
/// 相比旧写法（每条消息各自 `SelectableText`、每个页面各自 `ScrollController`）：
///
/// 1. **跨消息选择复制**：整块交由 [SelectionArea] 托管，可拖选、框选、
///    Ctrl+A 全选，右键 / 长按弹出系统复制菜单，选择范围不再被单条消息截断；
/// 2. **懒渲染 + 稳定身份**：`ListView.builder` 只构建视口内的条目，[keyOf]
///    保证条目被条数上限淘汰（头部整体前移）后行 Element 不会错位复用；
/// 3. **粘性到底**：仅当用户停在底部时自动跟随新消息；向上翻阅历史时不会
///    被新消息强行拉回底部，右下角浮标显示未读条数并可一键回到底部。
class MessageLogView<T extends Object> extends StatefulWidget {
  /// 当前要展示的条目（按展示顺序）
  final List<T> entries;

  /// 单条渲染
  final Widget Function(BuildContext context, int index, T entry) itemBuilder;

  /// 条目身份：同一条目需返回相等的 Key（通常传 `ObjectKey.new`）
  final Key Function(T entry)? keyOf;

  /// 空列表时的占位视图
  final Widget? empty;

  /// 列表内容内边距
  final EdgeInsets padding;

  /// 是否自动跟随到底部；为 false 时完全由用户控制滚动
  final bool autoFollow;

  /// 外部滚动控制器（可选，不传则内部自建并负责释放）
  final ScrollController? controller;

  const MessageLogView({
    super.key,
    required this.entries,
    required this.itemBuilder,
    this.keyOf,
    this.empty,
    this.padding = const EdgeInsets.all(8),
    this.autoFollow = true,
    this.controller,
  });

  /// 判定「已到底部」的像素容差
  static const double _bottomTolerance = 24;

  @override
  State<MessageLogView<T>> createState() => _MessageLogViewState<T>();
}

class _MessageLogViewState<T extends Object> extends State<MessageLogView<T>> {
  late ScrollController _controller;
  late bool _ownsController;

  /// 用户是否停在底部（决定是否自动跟随新消息）
  bool _atBottom = true;

  /// 离开底部后累计的新消息条数
  int _unseen = 0;

  /// 上一次构建观察到的条目数（用于识别新增消息）
  int _lastCount = -1;

  @override
  void initState() {
    super.initState();
    _bindController(widget.controller);
  }

  @override
  void didUpdateWidget(covariant MessageLogView<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      _unbindController();
      _bindController(widget.controller);
    }
  }

  @override
  void dispose() {
    _unbindController();
    super.dispose();
  }

  void _bindController(ScrollController? external) {
    _ownsController = external == null;
    _controller = external ?? ScrollController();
    _controller.addListener(_onScroll);
  }

  void _unbindController() {
    _controller.removeListener(_onScroll);
    if (_ownsController) _controller.dispose();
  }

  void _onScroll() {
    if (!_controller.hasClients) return;
    final pos = _controller.position;
    final atBottom =
        pos.maxScrollExtent - pos.pixels <= MessageLogView._bottomTolerance;
    if (atBottom == _atBottom) return;
    setState(() {
      _atBottom = atBottom;
      if (atBottom) _unseen = 0;
    });
  }

  /// 条目数变化：跟随到底部，或累计未读并提示。
  /// 在 build 中调度，避免 build 期间 setState。
  void _onEntriesChanged(int added) {
    final follow = widget.autoFollow && _atBottom;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      if (follow) {
        // 直接跳转而非动画：高频收包时动画会互相打断并拖慢跟手程度
        _controller.jumpTo(_controller.position.maxScrollExtent);
      } else if (!_atBottom) {
        setState(() => _unseen += added);
      }
    });
  }

  void _jumpToBottom() {
    if (!_controller.hasClients) return;
    _controller.animateTo(
      _controller.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.entries;
    final count = entries.length;
    if (count != _lastCount) {
      // 首次构建时 _lastCount 为 -1：有内容则直接定位到最新一条
      final added = _lastCount < 0 ? count : count - _lastCount;
      _lastCount = count;
      if (added > 0) _onEntriesChanged(added);
    }
    if (count == 0) {
      // 清空后重置跟随状态：下一条消息重新从底部开始跟随
      _atBottom = true;
      _unseen = 0;
      return widget.empty ?? const SizedBox.shrink();
    }
    final keyOf = widget.keyOf;
    return Stack(
      children: [
        Positioned.fill(
          child: SelectionArea(
            child: ListView.builder(
              controller: _controller,
              padding: widget.padding,
              itemCount: count,
              itemBuilder: (context, index) {
                final entry = entries[index];
                final child = widget.itemBuilder(context, index, entry);
                final key = keyOf?.call(entry);
                return key == null
                    ? child
                    : KeyedSubtree(key: key, child: child);
              },
            ),
          ),
        ),
        if (!_atBottom)
          Positioned(right: 12, bottom: 12, child: _buildJumpToBottom(context)),
      ],
    );
  }

  Widget _buildJumpToBottom(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primaryContainer,
      shape: const StadiumBorder(),
      elevation: 3,
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: _jumpToBottom,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.arrow_downward,
                size: 16,
                color: scheme.onPrimaryContainer,
              ),
              const SizedBox(width: 6),
              Text(
                _unseen > 0 ? '$_unseen 条新消息' : '回到底部',
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 复制多条消息到剪贴板并给出提示（「复制全部」通用实现）。
Future<void> copyMessages(
  BuildContext context,
  Iterable<String> messages, {
  String unit = '条消息',
}) async {
  final list = messages.toList();
  if (list.isEmpty) return;
  await Clipboard.setData(ClipboardData(text: list.join('\n')));
  if (!context.mounted) return;
  showAppToast(context, '已复制 ${list.length} $unit');
}

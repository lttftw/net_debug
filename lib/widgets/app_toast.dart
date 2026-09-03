import 'dart:async';

import 'package:flutter/material.dart';

/// 当前正在展示的顶部提示；再次调用时先移除旧条，避免堆叠
OverlayEntry? _activeToast;

/// 显示一条顶部悬浮提示（toast）。
///
/// 相比底部全宽的 SnackBar，它悬浮在窗口顶部、宽度收敛、自动淡出，
/// 不会遮挡屏幕底部的输入框 / 发送按钮等操作区。
/// 支持点击穿透，提示存在期间不影响其它交互。
void showAppToast(
  BuildContext context,
  String message, {
  Duration duration = const Duration(milliseconds: 1800),
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  _activeToast?.remove();
  late final OverlayEntry entry;
  void dismiss() {
    if (_activeToast == entry) _activeToast = null;
    entry.remove();
  }
  entry = OverlayEntry(
    builder: (_) => _AppToast(
      message: message,
      duration: duration,
      onDismiss: dismiss,
    ),
  );
  _activeToast = entry;
  overlay.insert(entry);
}

class _AppToast extends StatefulWidget {
  final String message;
  final Duration duration;
  final VoidCallback onDismiss;

  const _AppToast({
    required this.message,
    required this.duration,
    required this.onDismiss,
  });

  @override
  State<_AppToast> createState() => _AppToastState();
}

class _AppToastState extends State<_AppToast> {
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    // 首帧完成后淡入
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _visible = true);
    });
    // 停留时长后淡出并移除
    Timer(widget.duration, () {
      if (!mounted) return;
      setState(() => _visible = false);
      Future.delayed(const Duration(milliseconds: 220), widget.onDismiss);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: SafeArea(
          bottom: false,
          child: AnimatedSlide(
            offset: _visible ? Offset.zero : const Offset(0, -0.25),
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            child: AnimatedOpacity(
              opacity: _visible ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: Align(
                alignment: Alignment.topCenter,
                child: Container(
                  margin: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                  constraints: const BoxConstraints(maxWidth: 560),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.inverseSurface,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.16),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Text(
                    widget.message,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onInverseSurface,
                      height: 1.35,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

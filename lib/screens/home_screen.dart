import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/command_preset.dart';
import '../models/message_display_style.dart';
import '../services/tcp_service.dart';
import '../services/theme_service.dart';
import '../services/variables_service.dart';
import '../widgets/log_line_view.dart';
import '../widgets/send_composer.dart';
import '../widgets/variable_text_field.dart';

/// TCP 工具页：连接栏 + 常用指令 + 日志区 + 指令输入
class HomeScreen extends StatefulWidget {
  final TcpService service;
  final VariablesService variables;
  final ThemeService theme;

  const HomeScreen({
    super.key,
    required this.service,
    required this.variables,
    required this.theme,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final TcpService _service = widget.service;
  late final VariablesService _vars = widget.variables;
  late final ThemeService _theme = widget.theme;
  final TextEditingController _hostCtrl = TextEditingController();
  final TextEditingController _portCtrl = TextEditingController(text: '8080');
  final TextEditingController _cmdCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final FocusNode _cmdFocus = FocusNode();
  bool _connectionInitialized = false;
  String? _connectionError;
  bool _sending = false;
  bool _commandExpanded = true;
  bool _focusMode = false;

  @override
  void initState() {
    super.initState();
    // 历史与快捷指令由主框架（MainShell）统一加载，此处仅监听
    _service.addListener(_onServiceChanged);
  }

  void _onServiceChanged() {
    if (!_connectionInitialized && _service.connections.isNotEmpty) {
      _connectionInitialized = true;
      final latest = _service.connections.first;
      _hostCtrl.text = latest.host;
      _portCtrl.text = latest.port.toString();
    }
    if (!mounted || !_service.autoScroll) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    // service 生命周期由主框架（MainShell）统一管理
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _cmdCtrl.dispose();
    _scrollCtrl.dispose();
    _cmdFocus.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final host = _hostCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim());
    if (host.isEmpty || port == null || port < 1 || port > 65535) {
      setState(() => _connectionError = '请输入有效的服务器地址和 1–65535 端口');
      return;
    }
    setState(() => _connectionError = null);
    await _service.connect(host, port);
    if (_service.status != TcpStatus.connected) {
      setState(() => _connectionError = '连接失败，请检查地址和端口是否正确');
    }
  }

  /// 发送回调（SendComposer 已展开/校验内容）：更新发送中状态并交给 TcpService。
  Future<bool> _handleTcpSend(String content) async {
    setState(() => _sending = true);
    final ok = await _service.send(content);
    if (mounted) setState(() => _sending = false);
    return ok;
  }

  /// 发送历史（供 SendComposer 回溯）
  List<String> get _tcpHistory => [for (final e in _service.history) e.command];

  /// 快捷指令：点击自动替换变量后填入输入框（不自动发送），便于修改后手动发送。
  /// 填入时给出 toast 提示；未填写的变量会额外提示，引导去模板变量页填写。
  void _sendPreset(QuickCommand qc) {
    _cmdCtrl.text = _vars.expand(qc.command);
    _cmdFocus.requestFocus();
    final missing = _vars.emptyVariableNames(qc.command);
    if (missing.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '变量 ${missing.map((n) => '\$($n)').join('、')} 未填写，'
            '发送前请先在「设置 · 模板变量」中填写',
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已填入快捷指令「${qc.label}」，可编辑后发送'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /// 清空连接历史（带确认）
  Future<void> _confirmClearConnections() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('清空连接历史'),
        content: const Text('确定删除全部连接历史？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogCtx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _service.clearConnections();
  }

  void _showOtaPanel() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => OtaPanel(service: _service),
    );
  }

  Future<void> _confirmClearLogs() async {
    if (_service.logs.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.delete_sweep_outlined),
        title: const Text('清空往来记录？'),
        content: const Text('当前页面中的 TCP 收发和系统记录将被清空。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok == true) _service.clearLogs();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _focusMode
          ? null
          : AppBar(
              title: const Text('TCP 调试'),
              actions: [
                if (_service.otaEnabled)
                  IconButton(
                    tooltip: 'OTA 固件升级',
                    icon: const Icon(Icons.system_update_alt),
                    onPressed: _showOtaPanel,
                  ),
                IconButton(
                  tooltip: '通信专注模式',
                  icon: const Icon(Icons.fullscreen),
                  onPressed: () => setState(() {
                    _focusMode = true;
                    _commandExpanded = false;
                  }),
                ),
                IconButton(
                  tooltip: '清空日志',
                  icon: const Icon(Icons.delete_sweep_outlined),
                  onPressed: _confirmClearLogs,
                ),
              ],
            ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (_focusMode) {
            return Column(
              children: [
                _buildFocusHeader(),
                Expanded(child: _buildLogView()),
                _buildInputBar(collapsible: true),
              ],
            );
          }
          final wide = constraints.maxWidth >= 1000;
          if (wide) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _buildLogView(margin: EdgeInsets.zero)),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 360,
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildConnectionBar(compact: false),
                          const SizedBox(height: 12),
                          _buildPresetPanel(),
                          const SizedBox(height: 12),
                          _buildCommandPanel(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                child: _buildConnectionBar(compact: true),
              ),
              _buildPresetBar(),
              Expanded(child: _buildLogView()),
              _buildInputBar(collapsible: true),
            ],
          );
        },
      ),
    );
  }

  Widget _buildFocusHeader() {
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
        final connected = _service.status == TcpStatus.connected;
        return SafeArea(
          bottom: false,
          child: SizedBox(
            height: 44,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Icon(
                    connected ? Icons.circle : Icons.circle_outlined,
                    size: 11,
                    color: connected
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      '${_hostCtrl.text}:${_portCtrl.text} · ${_service.logs.length} 条记录',
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  IconButton(
                    tooltip: '退出专注模式',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.fullscreen_exit),
                    onPressed: () => setState(() => _focusMode = false),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildConnectionBar({required bool compact}) {
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
        final connected = _service.status == TcpStatus.connected;
        final connecting = _service.status == TcpStatus.connecting;
        final statusText = connected ? '已连接' : (connecting ? '连接中' : '未连接');
        final statusColor = connected
            ? Theme.of(context).colorScheme.primary
            : (connecting
                  ? Colors.orange
                  : Theme.of(context).colorScheme.onSurfaceVariant);
        final fields = Row(
          children: [
            Expanded(
              child: TextField(
                controller: _hostCtrl,
                enabled: !connected && !connecting,
                onChanged: (_) => setState(() => _connectionError = null),
                decoration: InputDecoration(
                  labelText: '服务器地址',
                  hintText: '例如 192.168.1.100',
                  suffixIcon: ListenableBuilder(
                    listenable: _service,
                    builder: (context, _) {
                      final conns = _service.connections;
                      if (conns.isEmpty) return const SizedBox.shrink();
                      return PopupMenuButton<int>(
                        tooltip: '历史连接',
                        icon: const Icon(Icons.history, size: 20),
                        onSelected: (v) {
                          if (v < 0) {
                            _confirmClearConnections();
                            return;
                          }
                          final c = conns[v];
                          _hostCtrl.text = c.host;
                          _portCtrl.text = c.port.toString();
                        },
                        itemBuilder: (context) => [
                          for (var i = 0; i < conns.length; i++)
                            PopupMenuItem(
                              value: i,
                              child: Text(
                                conns[i].label,
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                          const PopupMenuDivider(),
                          const PopupMenuItem(
                            value: -1,
                            child: Row(
                              children: [
                                Icon(Icons.delete_sweep_outlined, size: 16),
                                SizedBox(width: 8),
                                Text('清空连接历史'),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 88,
              child: TextField(
                controller: _portCtrl,
                enabled: !connected && !connecting,
                onChanged: (_) => setState(() => _connectionError = null),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '端口'),
              ),
            ),
          ],
        );
        return Card(
          child: Padding(
            padding: EdgeInsets.all(compact ? 10 : 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      connected
                          ? Icons.check_circle
                          : (connecting ? Icons.sync : Icons.circle_outlined),
                      size: 18,
                      color: statusColor,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      statusText,
                      style: TextStyle(
                        color: statusColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (!compact) ...[
                      const Spacer(),
                      Text(
                        '${_hostCtrl.text}:${_portCtrl.text}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                fields,
                if (_connectionError != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    _connectionError!,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: connecting
                      ? null
                      : (connected ? _service.disconnect : _connect),
                  icon: connecting
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(connected ? Icons.link_off : Icons.link),
                  label: Text(
                    connected ? '断开连接' : (connecting ? '正在连接…' : '连接'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPresetBar() {
    return SizedBox(
      height: 46,
      child: ListenableBuilder(
        listenable: _service,
        builder: (context, _) {
          final items = _service.quickCommands;
          return ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            itemCount: items.length + 1 + (_service.hasHiddenBuiltins ? 1 : 0),
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, i) {
              if (i == items.length) {
                return ActionChip(
                  avatar: const Icon(Icons.add, size: 16),
                  label: const Text('添加', style: TextStyle(fontSize: 12)),
                  visualDensity: VisualDensity.compact,
                  onPressed: _showAddQuickCommand,
                );
              }
              if (i == items.length + 1 && _service.hasHiddenBuiltins) {
                return ActionChip(
                  avatar: const Icon(Icons.restore, size: 16),
                  label: const Text('恢复全部', style: TextStyle(fontSize: 12)),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _service.restoreAllBuiltins(),
                );
              }
              // 跳过末尾的"添加"和"恢复全部"chip，取实际指令
              final qc = items[i];
              return GestureDetector(
                onLongPress: () => _showQuickCommandMenu(qc),
                child: ActionChip(
                  label: Text(qc.label, style: const TextStyle(fontSize: 12)),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _sendPreset(qc),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildPresetPanel() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ListenableBuilder(
          listenable: _service,
          builder: (context, _) {
            final items = _service.quickCommands;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('快捷指令', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  '点击填入编辑器，长按可编辑',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    for (final command in items)
                      GestureDetector(
                        onLongPress: () => _showQuickCommandMenu(command),
                        child: ActionChip(
                          avatar: const Icon(Icons.code, size: 15),
                          label: Text(command.label),
                          onPressed: () => _sendPreset(command),
                        ),
                      ),
                    ActionChip(
                      avatar: const Icon(Icons.add, size: 16),
                      label: const Text('添加'),
                      onPressed: _showAddQuickCommand,
                    ),
                    if (_service.hasHiddenBuiltins)
                      ActionChip(
                        avatar: const Icon(Icons.restore, size: 16),
                        label: const Text('恢复全部'),
                        onPressed: _service.restoreAllBuiltins,
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _showAddQuickCommand() {
    _showQuickCommandEditor();
  }

  /// 长按快捷指令弹出操作菜单
  void _showQuickCommandMenu(QuickCommand qc) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                qc.label,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                qc.command,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑'),
              onTap: () {
                Navigator.pop(ctx);
                _showQuickCommandEditor(existing: qc);
              },
            ),
            if (qc.isBuiltin && qc.isOverride)
              ListTile(
                leading: const Icon(Icons.restore),
                title: const Text('恢复默认'),
                onTap: () {
                  Navigator.pop(ctx);
                  _service.restoreBuiltin(qc.builtinIndex!);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除'),
              onTap: () {
                Navigator.pop(ctx);
                if (qc.isBuiltin) {
                  _service.hideBuiltin(qc.builtinIndex!);
                } else {
                  _service.deleteQuickCommand(qc.id!);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 添加/编辑快捷指令弹窗
  Future<void> _showQuickCommandEditor({QuickCommand? existing}) async {
    final result =
        await showDialog<({String label, String command, String hint})>(
          context: context,
          builder: (ctx) =>
              _QuickCommandEditorDialog(existing: existing, variables: _vars),
        );
    if (result == null) return;

    final label = result.label.trim();
    final command = result.command.trim();
    final hint = result.hint.trim();
    if (label.isEmpty || command.isEmpty) {
      _service.addSystemLog('名称和指令不能为空');
      return;
    }
    final hintOrNull = hint.isEmpty ? null : hint;
    if (existing == null) {
      await _service.addQuickCommand(label, command, hint: hintOrNull);
    } else if (existing.isBuiltin) {
      await _service.overrideBuiltin(
        existing.builtinIndex!,
        label,
        command,
        hint: hintOrNull,
      );
    } else {
      await _service.updateQuickCommand(
        existing.id!,
        label,
        command,
        hint: hintOrNull,
      );
    }
  }

  Widget _buildLogView({
    EdgeInsets margin = const EdgeInsets.symmetric(horizontal: 12),
  }) {
    return ListenableBuilder(
      listenable: Listenable.merge([_service, _theme]),
      builder: (context, _) {
        final logs = _service.logs;
        return Padding(
          padding: margin,
          child: logs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.forum_outlined,
                        size: 36,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                      const SizedBox(height: 10),
                      const Text('等待数据'),
                      const SizedBox(height: 4),
                      Text(
                        '连接后发送 JSON 指令，响应会显示在这里',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.all(8),
                  itemCount: logs.length,
                  itemBuilder: (context, i) => _LogTile(
                    entry: logs[i],
                    txColor: _theme.effectiveTxColor,
                    rxColor: _theme.effectiveRxColor,
                    fontSize: _theme.logFontSize,
                    displayStyle: _theme.messageDisplayStyle,
                  ),
                ),
        );
      },
    );
  }

  Widget _buildInputBar({bool collapsible = false}) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (collapsible && _commandExpanded)
              Row(
                children: [
                  Text('发送指令', style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  IconButton(
                    tooltip: '收起指令区',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.keyboard_arrow_down),
                    onPressed: () => setState(() => _commandExpanded = false),
                  ),
                ],
              ),
            SendComposer(
              controller: _cmdCtrl,
              variables: _vars,
              focusNode: _cmdFocus,
              onSend: _handleTcpSend,
              labelText: 'JSON 指令',
              hintText: '{"get":"status"}',
              minLines: 2,
              maxLines: 4,
              onChanged: (_) => setState(() {}),
              history: _tcpHistory,
              onClearHistory: _service.clearHistory,
              sending: _sending,
              collapsed: collapsible && !_commandExpanded,
              onExpand: () => setState(() => _commandExpanded = true),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCommandPanel() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('发送指令', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Ctrl + Enter 快速发送',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            SendComposer(
              controller: _cmdCtrl,
              variables: _vars,
              focusNode: _cmdFocus,
              onSend: _handleTcpSend,
              labelText: 'JSON 指令',
              hintText: '{"get":"status"}',
              minLines: 4,
              maxLines: 10,
              onChanged: (_) => setState(() {}),
              history: _tcpHistory,
              onClearHistory: _service.clearHistory,
              sending: _sending,
            ),
          ],
        ),
      ),
    );
  }
}

/// 快捷指令编辑弹窗（独立 StatefulWidget，确保 TextEditingController 正确释放）
class _QuickCommandEditorDialog extends StatefulWidget {
  final QuickCommand? existing;
  final VariablesService variables;

  const _QuickCommandEditorDialog({this.existing, required this.variables});

  @override
  State<_QuickCommandEditorDialog> createState() =>
      _QuickCommandEditorDialogState();
}

class _QuickCommandEditorDialogState extends State<_QuickCommandEditorDialog> {
  late final TextEditingController _labelCtrl;
  late final TextEditingController _cmdCtrl;
  late final TextEditingController _hintCtrl;

  @override
  void initState() {
    super.initState();
    _labelCtrl = TextEditingController(text: widget.existing?.label ?? '');
    _cmdCtrl = TextEditingController(text: widget.existing?.command ?? '');
    _hintCtrl = TextEditingController(text: widget.existing?.hint ?? '');
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _cmdCtrl.dispose();
    _hintCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? '添加快捷指令' : '编辑快捷指令'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _labelCtrl,
              decoration: const InputDecoration(labelText: '名称', isDense: true),
            ),
            const SizedBox(height: 8),
            VariableAwareTextField(
              controller: _cmdCtrl,
              variables: widget.variables,
              maxLines: 3,
              minLines: 1,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              labelText: '指令 (JSON，支持 \$(变量))',
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _hintCtrl,
              decoration: const InputDecoration(
                labelText: '提示（可选）',
                isDense: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, (
            label: _labelCtrl.text,
            command: _cmdCtrl.text,
            hint: _hintCtrl.text,
          )),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 单条日志展示
class _LogTile extends StatelessWidget {
  final LogEntry entry;
  final Color txColor;
  final Color rxColor;
  final double fontSize;
  final MessageDisplayStyle displayStyle;

  const _LogTile({
    required this.entry,
    required this.txColor,
    required this.rxColor,
    required this.fontSize,
    required this.displayStyle,
  });

  @override
  Widget build(BuildContext context) {
    final (color, tag) = switch (entry.kind) {
      LogKind.tx => (txColor, 'TX'),
      LogKind.rx => (rxColor, 'RX'),
      LogKind.system => (Colors.grey, 'SYS'),
      LogKind.error => (Colors.redAccent, 'ERR'),
    };
    return LogLineView(
      time: entry.time,
      tag: tag,
      color: color,
      message: entry.message,
      fontSize: fontSize,
      displayStyle: displayStyle,
    );
  }
}

/// OTA 固件升级面板
class OtaPanel extends StatefulWidget {
  final TcpService service;

  const OtaPanel({super.key, required this.service});

  @override
  State<OtaPanel> createState() => _OtaPanelState();
}

class _OtaPanelState extends State<OtaPanel> {
  Uint8List? _firmware;
  String? _fileName;
  OtaProgress? _progress;
  String? _statusText;
  bool _uploading = false;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    if (widget.service.status != TcpStatus.connected) {
      setState(() => _statusText = '未连接');
      return;
    }
    try {
      final resp = await widget.service.otaStatus();
      setState(() {
        _statusText = _formatStatus(resp);
        final state = resp['state'];
        final written = (resp['written'] as num?)?.toInt() ?? 0;
        final total = (resp['total'] as num?)?.toInt() ?? 0;
        if (state == 'receiving' || state == 'ready') {
          _progress = OtaProgress(
            written,
            total,
            total == 0 ? 0 : (written * 100 / total).floor(),
            state,
          );
        }
      });
    } catch (e) {
      setState(() => _statusText = '查询失败: $e');
    }
  }

  String _formatStatus(Map<String, dynamic> resp) {
    final state = resp['state'] ?? 'unknown';
    final written = (resp['written'] as num?)?.toInt() ?? 0;
    final total = (resp['total'] as num?)?.toInt() ?? 0;
    final running = resp['running'] ?? '';
    final update = resp['update'] ?? '';
    final parts = <String>[
      '状态: $state',
      if (total > 0) '已接收: $written / $total 字节',
      if (running is String && running.isNotEmpty) '运行版本: $running',
      if (update is String && update.isNotEmpty) '待更新: $update',
    ];
    return parts.join('\n');
  }

  Future<void> _pickFile() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['bin'],
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    setState(() {
      _firmware = bytes;
      _fileName = file.name;
      _progress = null;
    });
  }

  Future<void> _upload() async {
    final data = _firmware;
    if (data == null) return;
    if (data.isEmpty) {
      setState(() => _statusText = '固件文件为空，请重新选择');
      return;
    }
    setState(() {
      _uploading = true;
      _progress = null;
    });
    try {
      await widget.service.otaUpload(
        data,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (mounted) {
        setState(() => _statusText = '上传完成，可点击「应用并重启」');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _statusText = '上传失败: $e');
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _apply() async {
    setState(() => _applying = true);
    try {
      final resp = await widget.service.otaApply();
      if (mounted) {
        setState(() => _statusText = '应用成功: ${jsonEncode(resp)}');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _statusText = '应用失败: $e');
      }
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  Future<void> _abort() async {
    try {
      final resp = await widget.service.otaAbort();
      if (mounted) {
        setState(() {
          _statusText = '已中止: ${jsonEncode(resp)}';
          _progress = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _statusText = '中止失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = widget.service.status == TcpStatus.connected;
    final progress = _progress;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.system_update_alt),
              const SizedBox(width: 8),
              const Text(
                'OTA 固件升级',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: connected ? _refreshStatus : null,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('刷新状态'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_statusText != null)
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(_statusText!, style: const TextStyle(fontSize: 13)),
            ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: connected && !_uploading ? _pickFile : null,
            icon: const Icon(Icons.folder_open),
            label: Text(_fileName ?? '选择固件文件 (.bin)'),
          ),
          if (_fileName != null && _firmware != null) ...[
            const SizedBox(height: 8),
            Text(
              '$_fileName  ·  ${_firmware!.length} 字节',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
          if (progress != null) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: progress.total == 0
                  ? 0
                  : progress.written / progress.total,
              minHeight: 8,
              borderRadius: BorderRadius.circular(4),
            ),
            const SizedBox(height: 4),
            Text(
              '${progress.percent}%  (${progress.written} / ${progress.total} 字节)',
              style: const TextStyle(fontSize: 12),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: connected && _firmware != null && !_uploading
                      ? _upload
                      : null,
                  icon: const Icon(Icons.cloud_upload),
                  label: Text(_uploading ? '上传中...' : '上传固件'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: connected && !_uploading && !_applying
                      ? _apply
                      : null,
                  icon: const Icon(Icons.restart_alt),
                  label: Text(_applying ? '应用中...' : '应用并重启'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: connected && !_uploading ? _abort : null,
                  icon: const Icon(Icons.cancel),
                  label: const Text('中止'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

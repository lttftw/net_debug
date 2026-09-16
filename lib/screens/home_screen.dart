import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/command_preset.dart';
import '../models/message_display_style.dart';
import '../services/command_preset_service.dart';
import '../services/tcp_service.dart';
import '../services/theme_service.dart';
import '../services/variables_service.dart';
import '../widgets/app_toast.dart';
import '../widgets/log_line_view.dart';
import '../widgets/recent_connections_section.dart';
import '../widgets/send_composer.dart';
import 'command_presets_screen.dart';

/// TCP 工具页：连接栏 + 常用指令 + 日志区 + 指令输入
class HomeScreen extends StatefulWidget {
  final TcpService service;
  final VariablesService variables;
  final ThemeService theme;
  final CommandPresetService quickCommands;

  const HomeScreen({
    super.key,
    required this.service,
    required this.variables,
    required this.theme,
    required this.quickCommands,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final TcpService _service = widget.service;
  late final VariablesService _vars = widget.variables;
  late final ThemeService _theme = widget.theme;
  late final CommandPresetService _qcs = widget.quickCommands;
  final TextEditingController _hostCtrl = TextEditingController();
  final TextEditingController _portCtrl = TextEditingController(text: '8080');
  final TextEditingController _cmdCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final FocusNode _cmdFocus = FocusNode();
  bool _connectionInitialized = false;
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
      // 未配置时引导打开配置面板
      _openConfigPanel();
      return;
    }
    await _service.connect(host, port);
    if (!mounted) return;
    if (_service.status != TcpStatus.connected) {
      showAppToast(context, '连接失败，请检查地址和端口是否正确');
    }
  }

  /// 打开连接配置弹窗（对齐 MQTT 配置面板）；返回后回填 host/port 并可触发连接。
  Future<void> _openConfigPanel() async {
    final result = await showModalBottomSheet<TcpConfigResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _TcpConfigPanel(
        service: _service,
        initialHost: _hostCtrl.text,
        initialPort: _portCtrl.text,
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _hostCtrl.text = result.host;
      _portCtrl.text = result.port.toString();
    });
    if (result.connect) {
      await _connect();
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

  /// 点选一条快捷指令：展开变量后填入输入框（不自动发送），便于修改后手动发送。
  /// 填入时给出 toast 提示；未填写的变量会额外提示，引导去模板变量页填写。
  void _applyPreset(CommandPreset preset) {
    _cmdCtrl.text = _vars.expand(preset.command);
    _cmdFocus.requestFocus();
    final missing = _vars.emptyVariableNames(preset.command);
    if (missing.isNotEmpty) {
      showAppToast(
        context,
        '变量 ${missing.map((n) => '\$($n)').join('、')} 未填写，'
        '发送前请先在「设置 · 模板变量」中填写',
        duration: const Duration(seconds: 3),
      );
    } else {
      showAppToast(
        context,
        '已填入快捷指令「${preset.label}」，可编辑后发送',
        duration: const Duration(seconds: 2),
      );
    }
  }

  /// 打开快捷指令管理页
  void _openQuickCommandManager() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CommandPresetsScreen(
          service: _qcs,
          variables: _vars,
        ),
      ),
    );
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
                  tooltip: '连接配置',
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: _openConfigPanel,
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
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildConnectionBar(),
                        Expanded(child: _buildLogView()),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 360,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(14),
                      child: _buildSendAreaContent(collapsible: false),
                    ),
                  ),
                ],
              ),
            );
          }
          return Column(
            children: [
              _buildConnectionBar(),
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

  /// 紧凑连接状态栏（对齐 MQTT）：状态徽标 + 端点 + 连接按钮。
  /// 连接配置（地址/端口/历史）收纳在底部弹窗中。
  Widget _buildConnectionBar() {
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
        final connected = _service.status == TcpStatus.connected;
        final connecting = _service.status == TcpStatus.connecting;
        final statusText = connected ? '已连接' : (connecting ? '连接中' : '未连接');
        final color = connected
            ? Colors.greenAccent
            : (connecting ? Colors.amber : Colors.grey);
        final endpoint = _hostCtrl.text.trim().isEmpty
            ? '未配置服务器'
            : '${_hostCtrl.text.trim()}:${_portCtrl.text.trim()}';
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  statusText,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  endpoint,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${_service.logs.length}/${_service.maxLogs}',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                // 固定宽度：连接/连接中…/断开 文案不同也不会引起尺寸变化
                style: FilledButton.styleFrom(minimumSize: const Size(104, 46)),
                onPressed: connecting
                    ? null
                    : (connected ? _service.disconnect : _connect),
                icon: connecting
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        connected ? Icons.link_off : Icons.link,
                        size: 18,
                      ),
                label: Text(
                  connected
                      ? '断开'
                      : (connecting ? '连接中…' : '连接'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 快捷指令入口：分组二级菜单（组 → 指令）选择填入；右侧提供管理入口。
  Widget _buildQuickCommandBar() {
    return ListenableBuilder(
      listenable: _qcs,
      builder: (context, _) {
        final groups = _qcs.groups;
        final hasCommands = _qcs.totalCount > 0;
        return Row(
          children: [
            Expanded(
              child: hasCommands
                  ? MenuAnchor(
                      alignmentOffset: const Offset(0, 6),
                      menuChildren: [
                        for (final g in groups)
                          if (g.commands.isNotEmpty)
                            SubmenuButton(
                              menuChildren: [
                                for (final c in g.commands)
                                  MenuItemButton(
                                    leadingIcon: const Icon(Icons.code, size: 16),
                                    onPressed: () => _applyPreset(c),
                                    child: Text(c.label),
                                  ),
                              ],
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 8,
                                ),
                                child: Text(
                                  g.name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                      ],
                      builder: (context, menuController, child) {
                        return OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(40),
                          ),
                          onPressed: () => menuController.isOpen
                              ? menuController.close()
                              : menuController.open(),
                          icon: const Icon(Icons.playlist_play, size: 18),
                          label: Text('快捷指令（${_qcs.totalCount} 条）'),
                        );
                      },
                    )
                  : OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(40),
                      ),
                      onPressed: _openQuickCommandManager,
                      icon: const Icon(Icons.playlist_add, size: 18),
                      label: const Text('快捷指令（空，点击添加）'),
                    ),
            ),
            IconButton(
              tooltip: '管理快捷指令',
              icon: const Icon(Icons.manage_search),
              onPressed: _openQuickCommandManager,
            ),
          ],
        );
      },
    );
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
        child: _buildSendAreaContent(collapsible: collapsible),
      ),
    );
  }

  /// 发送区内容：标题行 + 快捷指令 + 输入框，统一 Card 背景。
  /// 窄屏底部与宽屏右侧共用；[collapsible] 为 true 时支持折叠。
  Widget _buildSendAreaContent({required bool collapsible}) {
    final expanded = !collapsible || _commandExpanded;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: expanded
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.terminal,
                        size: 18,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '发送指令',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const Spacer(),
                      if (collapsible)
                        IconButton(
                          tooltip: '收起指令区',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.keyboard_arrow_down),
                          onPressed: () =>
                              setState(() => _commandExpanded = false),
                        )
                      else
                        Text(
                          'Ctrl + Enter 快速发送',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _buildQuickCommandBar(),
                  const SizedBox(height: 8),
                  SendComposer(
                    controller: _cmdCtrl,
                    variables: _vars,
                    focusNode: _cmdFocus,
                    onSend: _handleTcpSend,
                    labelText: 'JSON 指令',
                    hintText: '{"get":"status"}',
                    minLines: collapsible ? 2 : 4,
                    maxLines: collapsible ? 4 : 10,
                    onChanged: (_) => setState(() {}),
                    history: _tcpHistory,
                    onClearHistory: _service.clearHistory,
                    sending: _sending,
                  ),
                ],
              )
            : SendComposer(
                controller: _cmdCtrl,
                variables: _vars,
                focusNode: _cmdFocus,
                onSend: _handleTcpSend,
                labelText: 'JSON 指令',
                hintText: '{"get":"status"}',
                collapsed: true,
                onExpand: () => setState(() => _commandExpanded = true),
                sending: _sending,
              ),
      ),
    );
  }
}

/// 连接配置弹窗返回值：host/port 与是否立即连接。
class TcpConfigResult {
  final String host;
  final int port;
  final bool connect;

  const TcpConfigResult(this.host, this.port, this.connect);
}

/// TCP 连接配置弹窗（对齐 MQTT 配置面板）：地址/端口 + 最近连接 + 保存/连接。
class _TcpConfigPanel extends StatefulWidget {
  final TcpService service;
  final String initialHost;
  final String initialPort;

  const _TcpConfigPanel({
    required this.service,
    required this.initialHost,
    required this.initialPort,
  });

  @override
  State<_TcpConfigPanel> createState() => _TcpConfigPanelState();
}

class _TcpConfigPanelState extends State<_TcpConfigPanel> {
  late final TextEditingController _hostCtrl = TextEditingController(
    text: widget.initialHost,
  );
  late final TextEditingController _portCtrl = TextEditingController(
    text: widget.initialPort,
  );

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    super.dispose();
  }

  (String, int)? _parse() {
    final host = _hostCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim());
    if (host.isEmpty || port == null || port < 1 || port > 65535) return null;
    return (host, port);
  }

  void _finish({required bool connect}) {
    final parsed = _parse();
    if (parsed == null) {
      showAppToast(context, '请输入有效的服务器地址和 1–65535 端口');
      return;
    }
    Navigator.pop(context, TcpConfigResult(parsed.$1, parsed.$2, connect));
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('连接配置', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                SizedBox(
                  width: 240,
                  child: TextField(
                    controller: _hostCtrl,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      labelText: '服务器地址',
                      hintText: '例如 192.168.1.100',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                SizedBox(
                  width: 100,
                  child: TextField(
                    controller: _portCtrl,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      labelText: '端口',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ListenableBuilder(
              listenable: widget.service,
              builder: (context, _) {
                final conns = widget.service.connections;
                return RecentConnectionsSection(
                  labels: [for (final c in conns) c.label],
                  onSelected: (i) {
                    final c = conns[i];
                    setState(() {
                      _hostCtrl.text = c.host;
                      _portCtrl.text = c.port.toString();
                    });
                  },
                  onClear: widget.service.clearConnections,
                );
              },
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _finish(connect: true),
                    icon: const Icon(Icons.link, size: 18),
                    label: const Text('连接'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _finish(connect: false),
                    icon: const Icon(Icons.save_outlined, size: 18),
                    label: const Text('仅保存'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
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

  /// 目录 + 版本升级通道的固件目录输入框（设备自行下载）
  final TextEditingController _urlController = TextEditingController();
  /// 同一通道的版本号输入框（`ota_apply` 的参数，必须 ≥1）
  final TextEditingController _versionController = TextEditingController();
  bool _savingUrl = false;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _versionController.dispose();
    super.dispose();
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
        // 设备上已保存的地址回填输入框；用户已输入内容时不覆盖
        final savedUrl = resp['url'];
        if (_urlController.text.isEmpty &&
            savedUrl is String &&
            savedUrl.isNotEmpty) {
          _urlController.text = savedUrl;
        }
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

  /// 保存固件目录（`ota_set`）：只保存、不下载；末尾 `/` 可省略，设备补全后
  /// 在状态 `url` 里回显；空文本即清除目录。
  /// 保存后刷新状态，让面板立刻反映设备上的目录与 state。
  Future<void> _saveUrl() async {
    final url = _urlController.text.trim();
    setState(() => _savingUrl = true);
    try {
      final resp = await widget.service.otaSetUrl(url);
      if (!mounted) return;
      if (resp['ok'] != true) {
        setState(() => _statusText = '保存失败: ${jsonEncode(resp)}');
        return;
      }
      await _refreshStatus();
      if (!mounted) return;
      final msg = url.isEmpty
          ? '已清除固件目录'
          : '目录已保存，填版本号后点「下载并应用该版本」';
      setState(() => _statusText = '${_statusText ?? ''}\n$msg');
    } catch (e) {
      if (mounted) setState(() => _statusText = '保存失败: $e');
    } finally {
      if (mounted) setState(() => _savingUrl = false);
    }
  }

  String _formatStatus(Map<String, dynamic> resp) {
    final state = resp['state'] ?? 'unknown';
    final source = resp['source'];
    final reason = resp['reason'];
    final written = (resp['written'] as num?)?.toInt() ?? 0;
    final total = (resp['total'] as num?)?.toInt() ?? 0;
    final running = resp['running'] ?? '';
    final update = resp['update'] ?? '';
    final url = resp['url'];
    final ver = resp['ver'];
    final parts = <String>[
      '状态: $state'
          '${source is String && source.isNotEmpty ? '（来源: $source）' : ''}',
      if (reason is String && reason.isNotEmpty) '失败原因: $reason',
      if (total > 0) '已接收: $written / $total 字节',
      if (ver is String && ver.isNotEmpty) '当前版本: $ver',
      if (running is String && running.isNotEmpty) '运行分区: $running',
      if (update is String && update.isNotEmpty) '目标分区: $update',
      if (url is String && url.isNotEmpty) '已存目录: $url',
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

  /// 按版本升级（`{"ota_apply":<版本>}`，版本必须 ≥1）：目标是已保存目录 +
  /// `<版本>.bin`，设备去下载（秒级返回 receiving），校验通过后自行切分区重启。
  Future<void> _apply(int version) async {
    setState(() => _applying = true);
    try {
      final resp = await widget.service.otaApply(version);
      if (!mounted) return;
      if (resp['ok'] != true) {
        setState(() => _statusText = '应用失败: ${jsonEncode(resp)}');
        return;
      }
      final rebooting = resp['action'] == 'ota_rebooting';
      setState(() => _statusText = rebooting
          ? '已切换启动分区，设备即将重启'
          : '已受理 ota_apply:$version，设备正在下载校验');
      if (!rebooting) await _refreshStatus();
    } catch (e) {
      if (mounted) {
        setState(() => _statusText = '应用失败: $e');
      }
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  /// 分块推送的收尾（`{"ota_push_apply":true}`，仅本地 TCP）：把已校验（ready）
  /// 镜像切为启动分区，回复发出后设备重启。
  Future<void> _pushApply() async {
    setState(() => _applying = true);
    try {
      final resp = await widget.service.otaPushApply();
      if (!mounted) return;
      if (resp['ok'] != true) {
        setState(() => _statusText = '应用失败: ${jsonEncode(resp)}');
        return;
      }
      setState(() => _statusText = resp['action'] == 'ota_rebooting'
          ? '已切换启动分区，设备即将重启'
          : '没有已就绪镜像可应用');
      await _refreshStatus();
    } catch (e) {
      if (mounted) {
        setState(() => _statusText = '应用失败: $e');
      }
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  /// 版本号输入框的值（1–99999999）；非法或 ≤0 返回 null（0 会被设备判参数错误）。
  int? _versionInput() {
    final value = int.tryParse(_versionController.text.trim());
    if (value == null || value <= 0 || value > 99999999) return null;
    return value;
  }

  /// 按版本号升级：先保存输入的目录（幂等），再下发该版本。
  Future<void> _applyVersion() async {
    final version = _versionInput();
    if (version == null) {
      setState(() => _statusText = '版本号必须是 1–99999999 的整数（0 会被判参数错误）');
      return;
    }
    final dir = _urlController.text.trim();
    if (dir.isEmpty) {
      setState(() => _statusText = '请先填写固件目录，例如 http://192.168.100.157:8088');
      return;
    }
    setState(() => _savingUrl = true);
    try {
      final saved = await widget.service.otaSetUrl(dir);
      if (!mounted) return;
      if (saved['ok'] != true) {
        setState(() => _statusText = '保存目录失败: ${jsonEncode(saved)}');
        return;
      }
    } catch (e) {
      if (mounted) setState(() => _statusText = '保存目录失败: $e');
      return;
    } finally {
      if (mounted) setState(() => _savingUrl = false);
    }
    await _apply(version);
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
    final busy = _uploading || _applying || _savingUrl;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      // 键盘弹出或内容变高时整体可滚动，避免底部按钮被挤出可视区
      child: SingleChildScrollView(
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
            const SizedBox(height: 14),
            const Text(
              '目录 + 版本升级（设备自行下载）',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlController,
                    enabled: connected && !busy,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      labelText: '固件目录（末尾 / 可省略，≤192 字节）',
                      hintText: 'http://192.168.100.157:8088',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: FilledButton(
                    onPressed: connected && !busy ? _saveUrl : null,
                    child: Text(_savingUrl ? '保存中...' : '保存目录'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 132,
                  child: TextField(
                    controller: _versionController,
                    enabled: connected && !busy,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      labelText: '版本号',
                      helperText: '必须 ≥1',
                      helperStyle: TextStyle(fontSize: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: FilledButton.icon(
                    onPressed: connected && !busy ? _applyVersion : null,
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('下载并应用该版本'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              '只保存目录、不下载：设备按「目录 + 版本号」自己拼出 <版本>.bin。'
              '填版本号后点「下载并应用该版本」（会先保存目录）→ 下载 → 校验 → '
              '切分区 → 自动重启；版本号必须 ≥1（0 会被判参数错误）。'
              '留空保存即清除目录。',
              style: TextStyle(fontSize: 11.5, color: Colors.grey),
            ),
            const Divider(height: 26),
            const Text(
              '分块推送（本机直推，仅本地 TCP）',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed: connected && !busy ? _pickFile : null,
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
                    onPressed:
                        connected && _firmware != null && !busy ? _upload : null,
                    icon: const Icon(Icons.cloud_upload),
                    label: Text(_uploading ? '上传中...' : '上传固件'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: connected && !busy ? _pushApply : null,
                    icon: const Icon(Icons.restart_alt),
                    label: Text(_applying ? '应用中...' : '应用并重启'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: connected && !busy ? _abort : null,
                    icon: const Icon(Icons.cancel),
                    label: const Text('中止'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../models/command_preset.dart';
import '../models/modbus_command.dart';
import '../services/modbus_service.dart';
import '../services/quick_command_service.dart';
import '../services/theme_service.dart';
import '../services/variables_service.dart';
import '../widgets/app_toast.dart';
import '../widgets/log_line_view.dart';
import '../widgets/modbus_form.dart';
import '../widgets/recent_connections_section.dart';
import 'quick_commands_screen.dart';

/// Modbus TCP 主站调试页：连接栏 + 快捷指令 + 指令表单 + 日志/解析区。
class ModbusScreen extends StatefulWidget {
  final ModbusTcpService service;
  final QuickCommandService quickCommands;
  final ThemeService theme;
  final VariablesService variables;

  const ModbusScreen({
    super.key,
    required this.service,
    required this.quickCommands,
    required this.theme,
    required this.variables,
  });

  @override
  State<ModbusScreen> createState() => _ModbusScreenState();
}

class _ModbusScreenState extends State<ModbusScreen> {
  final TextEditingController _hostCtrl = TextEditingController();
  final TextEditingController _portCtrl = TextEditingController(text: '502');
  final ScrollController _scrollCtrl = ScrollController();
  final GlobalKey<ModbusFormState> _formKey = GlobalKey<ModbusFormState>();
  bool _sending = false;
  bool _connectionInitialized = false;

  ModbusTcpService get _service => widget.service;
  QuickCommandService get _qcs => widget.quickCommands;
  ThemeService get _theme => widget.theme;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onServiceChanged() {
    if (!_connectionInitialized && _service.connections.isNotEmpty) {
      _connectionInitialized = true;
      final latest = _service.connections.first;
      _hostCtrl.text = latest.host;
      _portCtrl.text = latest.port.toString();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
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
    if (_service.status != ModbusStatus.connected) {
      showAppToast(context, '连接失败，请检查地址和端口');
    }
  }

  /// 打开连接配置弹窗；返回后回填 host/port 并可触发连接。
  Future<void> _openConfigPanel() async {
    final result = await showModalBottomSheet<ModbusConfigResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ModbusConfigPanel(
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

  Future<bool> _handleSend(ModbusCommand cmd) async {
    setState(() => _sending = true);
    try {
      await _service.send(cmd);
      if (mounted) setState(() => _sending = false);
      return true;
    } catch (_) {
      if (mounted) setState(() => _sending = false);
      return false;
    }
  }

  /// 点选快捷指令：解析为 ModbusCommand 并回填表单。
  void _applyPreset(CommandPreset preset) {
    final cmd = ModbusCommand.tryParse(preset.command);
    if (cmd == null) {
      showAppToast(context, '无法解析该指令');
      return;
    }
    _formKey.currentState?.setCommand(cmd);
    showAppToast(
      context,
      '已填入「${preset.label}」，可编辑后发送',
      duration: const Duration(seconds: 2),
    );
  }

  void _openQuickCommandManager() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => QuickCommandsScreen(
          service: _qcs,
          variables: widget.variables,
          title: 'Modbus 快捷指令',
        ),
      ),
    );
  }

  Future<void> _confirmClearLogs() async {
    if (_service.logs.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.delete_sweep_outlined),
        title: const Text('清空往来记录？'),
        content: const Text('当前页面中的 Modbus 收发和系统记录将被清空。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
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
      appBar: AppBar(
        title: const Text('Modbus 调试'),
        actions: [
          IconButton(
            tooltip: '连接配置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openConfigPanel,
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
                    width: 380,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(14),
                      child: _buildFormArea(),
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
              SafeArea(
                top: false,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  child: _buildFormArea(),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildFormArea() {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.tune,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text('指令构造', style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            _buildQuickCommandBar(),
            const SizedBox(height: 12),
            ModbusForm(
              key: _formKey,
              onSend: _handleSend,
              sending: _sending,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionBar() {
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
        final connected = _service.status == ModbusStatus.connected;
        final connecting = _service.status == ModbusStatus.connecting;
        final statusText = connected
            ? '已连接'
            : (connecting ? '连接中' : '未连接');
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

  Widget _buildLogView({EdgeInsets margin = const EdgeInsets.symmetric(horizontal: 12)}) {
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
                        Icons.settings_input_component,
                        size: 36,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                      const SizedBox(height: 10),
                      const Text('等待数据'),
                      const SizedBox(height: 4),
                      Text(
                        '连接后发送 Modbus 指令，响应会显示在这里',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.all(8),
                  itemCount: logs.length,
                  itemBuilder: (context, i) => _logTile(logs[i]),
                ),
        );
      },
    );
  }

  Widget _logTile(ModbusLogEntry entry) {
    final (color, tag) = switch (entry.kind) {
      ModbusLogKind.tx => (_theme.effectiveTxColor, 'TX'),
      ModbusLogKind.rx => (_theme.effectiveRxColor, 'RX'),
      ModbusLogKind.system => (Colors.grey, 'SYS'),
      ModbusLogKind.error => (Colors.redAccent, 'ERR'),
    };
    return LogLineView(
      time: entry.time,
      tag: tag,
      color: color,
      message: entry.message,
      fontSize: _theme.logFontSize,
      displayStyle: _theme.messageDisplayStyle,
    );
  }
}

/// 连接配置弹窗返回值：host/port 与是否立即连接。
class ModbusConfigResult {
  final String host;
  final int port;
  final bool connect;

  const ModbusConfigResult(this.host, this.port, this.connect);
}

/// Modbus 连接配置弹窗（对齐 TCP/MQTT）：地址/端口 + 最近连接 + 连接/仅保存。
class _ModbusConfigPanel extends StatefulWidget {
  final ModbusTcpService service;
  final String initialHost;
  final String initialPort;

  const _ModbusConfigPanel({
    required this.service,
    required this.initialHost,
    required this.initialPort,
  });

  @override
  State<_ModbusConfigPanel> createState() => _ModbusConfigPanelState();
}

class _ModbusConfigPanelState extends State<_ModbusConfigPanel> {
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
    Navigator.pop(context, ModbusConfigResult(parsed.$1, parsed.$2, connect));
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
                      hintText: '502',
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

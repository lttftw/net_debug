import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';

import '../models/command_preset.dart';
import '../services/quick_command_service.dart';
import '../services/serial_service.dart';
import '../services/theme_service.dart';
import '../services/variables_service.dart';
import '../widgets/app_toast.dart';
import '../widgets/log_line_view.dart';
import '../widgets/send_composer.dart';
import 'quick_commands_screen.dart';

/// 串口调试页（Windows）：端口/参数配置 + 收发日志 + 发送区。
///
/// 发送支持文本（可选行结束符）与 HEX 两种格式；日志支持 文本/HEX
/// 双模式切换显示（切换对历史条目即时生效）。
class SerialScreen extends StatefulWidget {
  final SerialService service;
  final QuickCommandService quickCommands;
  final ThemeService theme;
  final VariablesService variables;

  const SerialScreen({
    super.key,
    required this.service,
    required this.quickCommands,
    required this.theme,
    required this.variables,
  });

  @override
  State<SerialScreen> createState() => _SerialScreenState();
}

/// 日志展示模式
enum _DisplayMode { text, hex }

/// 文本发送的行结束符
enum _LineEnding { none, lf, crlf, cr }

/// 发送内容格式
enum _SendFormat { text, hex }

class _SerialScreenState extends State<SerialScreen> {
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  _DisplayMode _displayMode = _DisplayMode.text;
  _LineEnding _lineEnding = _LineEnding.lf;
  _SendFormat _sendFormat = _SendFormat.text;

  /// 最近一次在配置面板确认并打开的连接参数（未配置为 null）。
  /// 连接栏的「打开」直接用该参数重连，改参数需进配置面板。
  SerialPortConfig2? _lastConfig;

  /// 窄屏发送区折叠状态：默认收起，让消息区尽量可见。
  bool _composerExpanded = false;

  SerialService get _service => widget.service;
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
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onServiceChanged() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  /// 打开配置弹窗（端口 + 参数）。用户点「打开」返回配置并连接，
  /// 点「仅保存」只记忆配置不连接。
  Future<void> _openConfigPanel() async {
    final result = await showModalBottomSheet<_SerialConfigResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) =>
          _SerialConfigPanel(service: _service, initialConfig: _lastConfig),
    );
    if (result == null || !mounted) return;
    setState(() => _lastConfig = result.config);
    if (result.connect) {
      await _service.open(result.config);
      if (!mounted) return;
      if (_service.status != SerialStatus.connected) {
        showAppToast(context, '打开串口失败，请检查参数或设备占用');
      }
    }
  }

  /// 连接栏「打开」：直接用最近一次配置连接；未配置过则引导到配置面板。
  Future<void> _openPort() async {
    final cfg = _lastConfig;
    if (cfg == null) {
      await _openConfigPanel();
      return;
    }
    await _service.open(cfg);
  }

  Future<bool> _handleSend(String content) async {
    final Uint8List bytes;
    if (_sendFormat == _SendFormat.hex) {
      final parsed = SerialService.parseHex(content);
      if (parsed == null) {
        showAppToast(context, 'HEX 内容非法（示例：AA 55 01）');
        return false;
      }
      bytes = parsed;
    } else {
      final ending = switch (_lineEnding) {
        _LineEnding.none => '',
        _LineEnding.lf => '\n',
        _LineEnding.crlf => '\r\n',
        _LineEnding.cr => '\r',
      };
      bytes = Uint8List.fromList(utf8.encode('$content$ending'));
    }
    final ok = await _service.write(bytes);
    if (ok) _service.recordSent(content);
    return ok;
  }

  void _applyPreset(CommandPreset preset) {
    _inputCtrl.text = preset.command;
    showAppToast(context, '已填入「${preset.label}」');
  }

  void _openQuickCommandManager() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => QuickCommandsScreen(
          service: _qcs,
          variables: widget.variables,
          title: '串口快捷指令',
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
        content: const Text('当前页面中的串口收发和系统记录将被清空。'),
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
    if (!_service.isSupported) {
      return Scaffold(
        appBar: AppBar(title: const Text('串口调试')),
        body: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.usb_off_outlined, size: 40, color: Colors.grey),
              SizedBox(height: 12),
              Text('当前平台暂不支持串口'),
              SizedBox(height: 4),
              Text(
                '串口调试目前仅支持 Windows，移动端支持规划中',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('串口调试'),
        actions: [
          IconButton(
            tooltip: '连接配置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openConfigPanel,
          ),
          IconButton(
            tooltip: _displayMode == _DisplayMode.text
                ? '当前为文本显示，点击切换 HEX'
                : '当前为 HEX 显示，点击切换文本',
            icon: Icon(
              _displayMode == _DisplayMode.text
                  ? Icons.text_fields
                  : Icons.code,
            ),
            onPressed: () => setState(() {
              _displayMode = _displayMode == _DisplayMode.text
                  ? _DisplayMode.hex
                  : _DisplayMode.text;
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
                    width: 420,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(14),
                      child: _buildComposerArea(collapsible: false),
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
              _buildInputBar(),
            ],
          );
        },
      ),
    );
  }

  /// 窄屏底部发送区（可折叠收起，让消息区尽量可见）。
  Widget _buildInputBar() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
        child: _buildComposerArea(collapsible: true),
      ),
    );
  }

  // ---------- 连接栏 ----------

  /// 简洁连接状态栏：状态徽标 + 当前连接 + 打开/关闭。
  /// 端口与参数配置统一收进二级配置弹窗（AppBar 设置按钮 / 未配置时打开）。
  Widget _buildConnectionBar() {
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
        final connected = _service.status == SerialStatus.connected;
        final connecting = _service.status == SerialStatus.connecting;
        final statusText =
            connected ? '已打开' : (connecting ? '打开中' : '未打开');
        final color = connected
            ? Colors.greenAccent
            : (connecting ? Colors.amber : Colors.grey);
        final endpoint = _service.activeConfig?.label ??
            _lastConfig?.portName ??
            '未配置端口';
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
          child: Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
                    : (connected ? _service.close : _openPort),
                icon: connecting
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        connected ? Icons.link_off : Icons.usb_outlined,
                        size: 18,
                      ),
                label: Text(connected ? '关闭' : '打开'),
              ),
            ],
          ),
        );
      },
    );
  }

  // ---------- 日志区 ----------

  Widget _buildLogView() {
    return ListenableBuilder(
      listenable: Listenable.merge([_service, _theme]),
      builder: (context, _) {
        final logs = _service.logs;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: logs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.settings_input_composite,
                        size: 36,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                      const SizedBox(height: 10),
                      const Text('等待数据'),
                      const SizedBox(height: 4),
                      Text(
                        '选择端口并打开后，收发数据会显示在这里',
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

  Widget _logTile(SerialLogEntry entry) {
    final (color, tag) = switch (entry.kind) {
      SerialLogKind.tx => (_theme.effectiveTxColor, 'TX'),
      SerialLogKind.rx => (_theme.effectiveRxColor, 'RX'),
      SerialLogKind.system => (Colors.grey, 'SYS'),
      SerialLogKind.error => (Colors.redAccent, 'ERR'),
    };
    final message = entry.rawBytes == null
        ? entry.message
        : (_displayMode == _DisplayMode.hex
            ? SerialService.bytesToHex(entry.rawBytes!)
            : SerialService.bytesToText(entry.rawBytes!));
    return LogLineView(
      time: entry.time,
      tag: tag,
      color: color,
      message: message,
      fontSize: _theme.logFontSize,
      displayStyle: _theme.messageDisplayStyle,
    );
  }

  // ---------- 发送区 ----------

  /// 发送卡片（与 TCP/MQTT 一致：标题行 + 快捷指令 + 格式选项 + 输入区）。
  /// 整卡监听 [_service]：发送成功写入历史后自动重建，历史按钮随即出现。
  /// [collapsible] 为 true（窄屏底部）时支持折叠成单行，让消息区尽量可见。
  Widget _buildComposerArea({bool collapsible = false}) {
    final expanded = !collapsible || _composerExpanded;
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
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
                            Icons.send_outlined,
                            size: 18,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '发送数据',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const Spacer(),
                          if (collapsible)
                            IconButton(
                              tooltip: '收起发送区',
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.keyboard_arrow_down),
                              onPressed: () =>
                                  setState(() => _composerExpanded = false),
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
                      _buildSendOptions(),
                      const SizedBox(height: 8),
                      SendComposer(
                        controller: _inputCtrl,
                        variables: widget.variables,
                        onSend: _handleSend,
                        labelText: _sendFormat == _SendFormat.hex
                            ? 'HEX 内容'
                            : '发送内容',
                        hintText: _sendFormat == _SendFormat.hex
                            ? 'AA 55 01'
                            : null,
                        initialFormat: ComposerFormat.text,
                        history: _service.history,
                        onClearHistory: _service.clearHistory,
                        sendLabel: '发送',
                      ),
                    ],
                  )
                : SendComposer(
                    controller: _inputCtrl,
                    variables: widget.variables,
                    onSend: _handleSend,
                    labelText: '发送内容',
                    collapsed: true,
                    onExpand: () => setState(() => _composerExpanded = true),
                    sendLabel: '发送',
                  ),
          ),
        );
      },
    );
  }

  /// 发送格式与行结束符选项
  Widget _buildSendOptions() {
    return Row(
      children: [
        SegmentedButton<_SendFormat>(
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
          ),
          segments: const [
            ButtonSegment(value: _SendFormat.text, label: Text('文本')),
            ButtonSegment(value: _SendFormat.hex, label: Text('HEX')),
          ],
          selected: {_sendFormat},
          onSelectionChanged: (s) => setState(() => _sendFormat = s.first),
        ),
        const SizedBox(width: 8),
        if (_sendFormat == _SendFormat.text)
          SizedBox(
            width: 120,
            child: _labelDropdown<_LineEnding>(
              label: '行结束符',
              value: _lineEnding,
              items: _LineEnding.values,
              display: (v) => switch (v) {
                _LineEnding.none => '无',
                _LineEnding.lf => '\\n',
                _LineEnding.crlf => '\\r\\n',
                _LineEnding.cr => '\\r',
              },
              enabled: true,
              onChanged: (v) => setState(() => _lineEnding = v),
            ),
          ),
      ],
    );
  }

  /// 发送区通用紧凑下拉（标签 + 选项，禁用时置灰）。
  Widget _labelDropdown<T>({
    required String label,
    required T value,
    required List<T> items,
    required String Function(T) display,
    required bool enabled,
    required ValueChanged<T> onChanged,
  }) {
    return DropdownButtonFormField<T>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      ),
      items: [
        for (final v in items)
          DropdownMenuItem(value: v, child: Text(display(v))),
      ],
      onChanged: enabled
          ? (v) {
              if (v != null) onChanged(v);
            }
          : null,
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
                                    leadingIcon:
                                        const Icon(Icons.code, size: 16),
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
}

/// 串口连接配置弹窗：端口选择（带刷新）+ 通信参数 + 打开。
/// 返回 [_SerialConfigResult] 表示「确认并打开 / 仅保存」；关闭弹窗则不改动当前配置。
class _SerialConfigPanel extends StatefulWidget {
  static const _baudRates = [
    9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600,
  ];

  final SerialService service;
  final SerialPortConfig2? initialConfig;

  const _SerialConfigPanel({required this.service, this.initialConfig});

  @override
  State<_SerialConfigPanel> createState() => _SerialConfigPanelState();
}

class _SerialConfigPanelState extends State<_SerialConfigPanel> {
  List<SerialPortInfo> _ports = [];
  String? _selectedPort;
  int _baud = 115200;
  int _dataBits = 8;
  int _parity = SerialPortParity.none;
  int _stopBits = 1;

  SerialService get _service => widget.service;

  @override
  void initState() {
    super.initState();
    final init = widget.initialConfig;
    if (init != null) {
      _selectedPort = init.portName;
      _baud = init.baudRate;
      _dataBits = init.dataBits;
      _parity = init.parity;
      _stopBits = init.stopBits;
    }
    _loadPorts();
  }

  void _loadPorts() {
    final ports = _service.listPorts();
    setState(() {
      _ports = ports;
      if (_selectedPort == null ||
          !ports.any((p) => p.name == _selectedPort)) {
        _selectedPort = ports.isNotEmpty ? ports.first.name : null;
      }
    });
  }

  SerialPortConfig2? _buildConfig() {
    final name = _selectedPort;
    if (name == null) return null;
    return SerialPortConfig2(
      portName: name,
      baudRate: _baud,
      dataBits: _dataBits,
      parity: _parity,
      stopBits: _stopBits,
    );
  }

  void _finish({required bool connect}) {
    final cfg = _buildConfig();
    if (cfg == null) {
      showAppToast(context, '未检测到可用串口，请插入设备后刷新');
      return;
    }
    Navigator.pop(context, _SerialConfigResult(cfg, connect));
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
            DropdownButtonFormField<String>(
              initialValue: _selectedPort,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: '端口',
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: '刷新端口列表',
                  icon: const Icon(Icons.refresh, size: 20),
                  onPressed: _loadPorts,
                ),
              ),
              items: [
                for (final p in _ports)
                  DropdownMenuItem(
                    value: p.name,
                    child: Text(p.label, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) => setState(() => _selectedPort = v),
              hint: _ports.isEmpty ? const Text('未检测到串口') : null,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                _paramDropdown<int>(
                  label: '波特率',
                  value: _baud,
                  items: [for (final b in _SerialConfigPanel._baudRates) b],
                  display: (b) => '$b',
                  onChanged: (v) => setState(() => _baud = v),
                ),
                _paramDropdown<int>(
                  label: '数据位',
                  value: _dataBits,
                  items: const [7, 8],
                  display: (v) => '$v',
                  onChanged: (v) => setState(() => _dataBits = v),
                ),
                _paramDropdown<int>(
                  label: '校验',
                  value: _parity,
                  items: const [
                    SerialPortParity.none,
                    SerialPortParity.even,
                    SerialPortParity.odd,
                  ],
                  display: (v) => switch (v) {
                    SerialPortParity.even => '偶',
                    SerialPortParity.odd => '奇',
                    _ => '无',
                  },
                  onChanged: (v) => setState(() => _parity = v),
                ),
                _paramDropdown<int>(
                  label: '停止位',
                  value: _stopBits,
                  items: const [1, 2],
                  display: (v) => '$v',
                  onChanged: (v) => setState(() => _stopBits = v),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _selectedPort == null
                        ? null
                        : () => _finish(connect: true),
                    icon: const Icon(Icons.usb_outlined, size: 18),
                    label: const Text('打开'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _selectedPort == null
                        ? null
                        : () => _finish(connect: false),
                    child: const Text('仅保存'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 参数紧凑下拉（配置弹窗用）。
  Widget _paramDropdown<T>({
    required String label,
    required T value,
    required List<T> items,
    required String Function(T) display,
    required ValueChanged<T> onChanged,
  }) {
    return SizedBox(
      width: label == '波特率' ? 130 : 92,
      child: DropdownButtonFormField<T>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        ),
        items: [
          for (final v in items)
            DropdownMenuItem(value: v, child: Text(display(v))),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }
}

/// 串口配置弹窗返回结果：选定的连接参数与是否立即连接。
class _SerialConfigResult {
  final SerialPortConfig2 config;
  final bool connect;

  const _SerialConfigResult(this.config, this.connect);
}

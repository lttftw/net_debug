import 'package:flutter/material.dart';

import '../services/mqtt_broker_service.dart';
import '../services/mqtt_service.dart';
import '../services/theme_service.dart';
import '../services/variables_service.dart';
import '../widgets/log_line_view.dart';
import '../widgets/send_composer.dart';
import '../widgets/variable_text_field.dart';
import 'variables_screen.dart';

/// MQTT 工具页：独立的 MQTT 调试客户端，与 TCP 工具完全解耦。
/// 框架对齐 TCP 工具：AppBar 右上角为配置/清空操作，body 为
/// Column（连接栏 + 订阅行 + Expanded 自适应记录区 + 底部固定发送栏）。
class MqttScreen extends StatefulWidget {
  final MqttService service;

  /// 内置测试 Broker 服务（可在配置面板中启动/停止）
  final MqttBrokerService broker;
  final VariablesService variables;
  final ThemeService theme;

  const MqttScreen({
    super.key,
    required this.service,
    required this.broker,
    required this.variables,
    required this.theme,
  });

  @override
  State<MqttScreen> createState() => _MqttScreenState();
}

class _MqttScreenState extends State<MqttScreen> {
  final _subTopicCtrl = TextEditingController();
  final _pubTopicCtrl = TextEditingController();
  final _payloadCtrl = TextEditingController();
  final ScrollController _recordScroll = ScrollController();
  int _qos = 0;
  bool _composerExpanded = false;
  bool _focusMode = false;
  final List<String> _pubHistory = [];

  MqttService get _service => widget.service;
  VariablesService get _vars => widget.variables;
  ThemeService get _theme => widget.theme;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    _subTopicCtrl.dispose();
    _pubTopicCtrl.dispose();
    _payloadCtrl.dispose();
    _recordScroll.dispose();
    super.dispose();
  }

  /// 记录区自动滚动到底部（与 TCP 工具日志区一致）
  void _onServiceChanged() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_recordScroll.hasClients) return;
      _recordScroll.animateTo(
        _recordScroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _toggleConnect() async {
    if (_service.status != MqttConnStatus.disconnected) {
      await _service.disconnect();
      return;
    }
    final cfg = _service.config;
    if (cfg.host.trim().isEmpty) {
      _openConfigPanel(); // 未配置先弹出配置面板
      return;
    }
    // 点击后立即给出反馈，连接状态 badge 同步变为「连接中」
    _showSnack('正在连接 ${cfg.host}:${cfg.port} ...');
    try {
      await _service.connect(clientId: _vars.expand(cfg.clientIdTemplate));
    } catch (e) {
      _showSnack('连接失败: $e');
    }
  }

  Future<void> _openConfigPanel() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ConfigPanel(
        service: _service,
        broker: widget.broker,
        variables: _vars,
      ),
    );
    // 配置面板要求「使用内置 Broker 连接」时，自动发起连接
    if (action == 'connect_local' && mounted) {
      await _toggleConnect();
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  // ---------- 订阅 / 发布 ----------

  void _subscribe() {
    if (!_service.isConnected) {
      _showSnack('请先连接 MQTT Broker');
      return;
    }
    final missing = _vars.emptyVariableNames(_subTopicCtrl.text);
    if (missing.isNotEmpty) {
      _showSnack(
        '变量 ${missing.map((n) => '\$($n)').join('、')} 未填写，'
        '无法展开订阅主题',
      );
      return;
    }
    final topic = _vars.expand(_subTopicCtrl.text);
    if (topic.trim().isEmpty) {
      _showSnack('订阅主题不能为空');
      return;
    }
    _service.subscribe(topic);
  }

  /// 发布回调（SendComposer 已展开/校验内容）：检查连接与主题后发布。
  Future<bool> _handlePublish(String content) async {
    if (!_service.isConnected) {
      _showSnack('请先连接 MQTT Broker');
      return false;
    }
    final missing = {
      ..._vars.emptyVariableNames(_pubTopicCtrl.text),
      ..._vars.emptyVariableNames(content),
    };
    if (missing.isNotEmpty) {
      _showSnack(
        '变量 ${missing.map((n) => '\$($n)').join('、')} 未填写，'
        '无法展开主题或内容',
      );
      return false;
    }
    final topic = _vars.expand(_pubTopicCtrl.text).trim();
    if (topic.isEmpty) {
      _showSnack('发送主题不能为空');
      return false;
    }
    _service.publish(topic, content, qos: _qos);
    _pubHistory.insert(0, content);
    if (_pubHistory.length > 50) _pubHistory.removeLast();
    return true;
  }

  // ---------- 可输入 + 可选模板的 topic 下拉框 ----------

  Widget _buildTopicMenu({
    required TextEditingController controller,
    required List<String> topics,
    required String label,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return DropdownMenu<String>(
          width: constraints.maxWidth,
          controller: controller,
          requestFocusOnTap: true,
          enableFilter: true,
          label: Text(label),
          textStyle: const TextStyle(fontSize: 13),
          menuHeight: topics.length > 8 ? 280 : null,
          dropdownMenuEntries: [
            for (final t in topics)
              DropdownMenuEntry<String>(value: t, label: t),
          ],
          onSelected: (t) {
            if (t == null) return;
            controller.text = _vars.expand(t);
            final missing = _vars.emptyVariableNames(t);
            if (missing.isNotEmpty) {
              _showSnack(
                '变量 ${missing.map((n) => '\$($n)').join('、')} 未填写，'
                '主题未展开，请先在「设置 · 模板变量」中填写',
              );
            }
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _focusMode
          ? null
          : AppBar(
              title: const Text('MQTT 消息工具'),
              actions: [
                IconButton(
                  tooltip: '连接配置',
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: _openConfigPanel,
                ),
                IconButton(
                  tooltip: '消息专注模式',
                  icon: const Icon(Icons.fullscreen),
                  onPressed: () => setState(() {
                    _focusMode = true;
                    _composerExpanded = false;
                  }),
                ),
                IconButton(
                  tooltip: '清空往来记录',
                  icon: const Icon(Icons.delete_sweep_outlined),
                  onPressed: _service.clearLogs,
                ),
              ],
            ),
      // 监听 MqttService + ThemeService，连接/消息/订阅/主题变化时自动刷新
      body: ListenableBuilder(
        listenable: Listenable.merge([_service, _theme, widget.broker]),
        builder: (context, _) {
          return LayoutBuilder(
            builder: (context, constraints) {
              if (_focusMode) {
                return Column(
                  children: [
                    _buildFocusHeader(),
                    Expanded(child: _buildRecordView()),
                    _buildSendPanel(compact: true),
                  ],
                );
              }
              if (constraints.maxWidth >= 1000) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Column(
                          children: [
                            _buildConnectionBar(),
                            _buildSubscribeBar(),
                            Expanded(
                              child: _buildRecordView(
                                margin: const EdgeInsets.only(top: 2),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 360,
                        child: Card(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(14),
                            child: _buildSendPanel(
                              compact: false,
                              embedded: true,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }
              return Column(
                children: [
                  _buildConnectionBar(),
                  _buildSubscribeBar(),
                  Expanded(child: _buildRecordView()),
                  _buildSendPanel(compact: true),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildFocusHeader() {
    final status = _service.status;
    final connected = status == MqttConnStatus.connected;
    final cfg = _service.config;
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
                  cfg.host.isEmpty
                      ? '未配置 MQTT Broker'
                      : '${cfg.host}:${cfg.port} · ${_service.logs.length} 条消息',
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
  }

  // ---------- 连接栏（顶部） ----------

  Widget _buildConnectionBar() {
    final status = _service.status;
    final statusText = switch (status) {
      MqttConnStatus.connected => '已连接',
      MqttConnStatus.connecting => '连接中',
      MqttConnStatus.disconnected => '未连接',
    };
    final color = switch (status) {
      MqttConnStatus.connected => Colors.greenAccent,
      MqttConnStatus.connecting => Colors.amber,
      MqttConnStatus.disconnected => Colors.grey,
    };
    final cfg = _service.config;
    final cid = _vars.expand(cfg.clientIdTemplate);
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
              cfg.host.isEmpty
                  ? '未配置'
                  : '${cfg.host}:${cfg.port} · ${cid.isEmpty ? '?' : cid}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          if (widget.broker.running) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: '内置测试 Broker 运行中，点击打开配置',
              child: InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: _openConfigPanel,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.greenAccent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.hub,
                        size: 12,
                        color: Colors.greenAccent,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '本地:${widget.broker.port}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.greenAccent,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
          FilledButton.icon(
            onPressed: _toggleConnect,
            icon: Icon(
              status == MqttConnStatus.disconnected
                  ? Icons.link
                  : Icons.link_off,
              size: 18,
            ),
            label: Text(
              status == MqttConnStatus.connected
                  ? '断开'
                  : status == MqttConnStatus.connecting
                  ? '取消'
                  : '连接',
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 订阅行（与记录区计数/清空合并为一行） ----------

  Widget _buildSubscribeBar() {
    final topics = _service.config.topics;
    final logs = _service.logs;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _buildTopicMenu(
                  controller: _subTopicCtrl,
                  topics: topics,
                  label: '订阅主题',
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _service.isConnected ? _subscribe : null,
                icon: const Icon(Icons.subscriptions, size: 16),
                label: const Text('订阅'),
              ),
              const SizedBox(width: 4),
              Text(
                '${logs.length}/${_service.maxLogs}',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
            ],
          ),
          if (_service.subscriptions.isNotEmpty) ...[
            const SizedBox(height: 4),
            SizedBox(
              height: 38,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _service.subscriptions.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (context, index) {
                  final t = _service.subscriptions[index];
                  return InputChip(
                    backgroundColor: _service
                        .colorForTopic(t)
                        .withValues(alpha: 0.20),
                    side: BorderSide(
                      color: _service.colorForTopic(t).withValues(alpha: 0.55),
                    ),
                    label: Text(
                      t,
                      style: TextStyle(
                        fontSize: 12,
                        color: _theme.effectiveRxColor,
                      ),
                    ),
                    deleteIconColor: _theme.effectiveRxColor,
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _subTopicCtrl.text = t,
                    onDeleted: () => _service.unsubscribe(t),
                    deleteButtonTooltipMessage: '取消订阅 $t',
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRecordView({
    EdgeInsets margin = const EdgeInsets.symmetric(horizontal: 12),
  }) {
    final logs = _service.logs;
    return Card(
      margin: margin,
      child: logs.isEmpty
          ? const Center(
              child: Text(
                '暂无记录',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            )
          : ListView.builder(
              controller: _recordScroll,
              padding: const EdgeInsets.all(8),
              itemCount: logs.length,
              itemBuilder: (context, i) => _RecordTile(
                entry: logs[i],
                service: _service,
                txColor: _theme.effectiveTxColor,
                rxColor: _theme.effectiveRxColor,
                fontSize: _theme.logFontSize,
              ),
            ),
    );
  }

  // ---------- 发布面板（窄屏折叠 / 宽屏右侧常驻） ----------

  Widget _buildSendPanel({required bool compact, bool embedded = false}) {
    final topics = _service.config.topics;
    final expanded = !compact || _composerExpanded;
    final panel = expanded
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.outbox_outlined,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text('发布消息', style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  if (compact)
                    IconButton(
                      tooltip: '收起发布区',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.keyboard_arrow_down),
                      onPressed: () =>
                          setState(() => _composerExpanded = false),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _buildTopicMenu(
                      controller: _pubTopicCtrl,
                      topics: topics,
                      label: '发送主题',
                    ),
                  ),
                  const SizedBox(width: 8),
                  DropdownButton<int>(
                    value: _qos,
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('QoS 0')),
                      DropdownMenuItem(value: 1, child: Text('QoS 1')),
                      DropdownMenuItem(value: 2, child: Text('QoS 2')),
                    ],
                    onChanged: (v) => setState(() => _qos = v ?? 0),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SendComposer(
                controller: _payloadCtrl,
                variables: _vars,
                onSend: _handlePublish,
                labelText: '发送内容',
                hintText: '{"msg":"hello"}',
                minLines: compact ? 2 : 5,
                maxLines: compact ? 4 : 10,
                history: _pubHistory,
                sendLabel: '发布',
              ),
            ],
          )
        : SendComposer(
            controller: _payloadCtrl,
            variables: _vars,
            onSend: _handlePublish,
            labelText: '发送内容',
            hintText: '{"msg":"hello"}',
            collapsed: true,
            onExpand: () => setState(() => _composerExpanded = true),
            sendLabel: '发布',
          );
    if (embedded) return panel;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
        child: panel,
      ),
    );
  }
}

/// 记录单行（与 TCP 工具日志区 _LogTile 样式一致）
class _RecordTile extends StatelessWidget {
  final MqttLogEntry entry;
  final MqttService service;
  final Color txColor;
  final Color rxColor;
  final double fontSize;

  const _RecordTile({
    required this.entry,
    required this.service,
    required this.txColor,
    required this.rxColor,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    // topic 随机色只用于背景；文字仍使用主题设置中的 TX/RX 色。
    final isRx = entry.kind == MqttLogKind.rx && entry.topic != null;
    final textColor = switch (entry.kind) {
      MqttLogKind.tx => txColor,
      MqttLogKind.rx => rxColor,
      MqttLogKind.system => Colors.grey,
      MqttLogKind.error => Colors.redAccent,
    };
    final topicBackground = isRx ? service.colorForTopic(entry.topic!) : null;
    final tag = switch (entry.kind) {
      MqttLogKind.tx => 'TX',
      MqttLogKind.rx => 'RX',
      MqttLogKind.system => 'SYS',
      MqttLogKind.error => 'ERR',
    };
    return LogLineView(
      time: entry.time,
      tag: tag,
      color: textColor,
      backgroundColor: topicBackground,
      message: entry.message,
      fontSize: fontSize,
      label: entry.topic,
    );
  }
}

/// 单个模板变量编辑行：独立 StatefulWidget 持有稳定的 controller，
/// 输入时不因外层重建而失焦；文本强制 LTR。
class _VariableEditRow extends StatefulWidget {
  final VariableItem item;
  final VariablesService service;

  const _VariableEditRow({
    super.key,
    required this.item,
    required this.service,
  });

  @override
  State<_VariableEditRow> createState() => _VariableEditRowState();
}

class _VariableEditRowState extends State<_VariableEditRow> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.item.value,
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(
              '\$(${widget.item.name})',
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          Expanded(
            child: TextField(
              controller: _ctrl,
              textDirection: TextDirection.ltr,
              style: const TextStyle(fontSize: 12),
              decoration: InputDecoration(
                labelText: widget.item.hint.isEmpty
                    ? widget.item.name
                    : widget.item.hint,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              onChanged: (s) => widget.service.setValue(widget.item.name, s),
            ),
          ),
        ],
      ),
    );
  }
}

/// 可视化配置面板：服务器 / client id 模板 / 账号 / 多个主题模板 /
/// 可折叠模板变量
class _ConfigPanel extends StatefulWidget {
  final MqttService service;
  final MqttBrokerService broker;
  final VariablesService variables;

  const _ConfigPanel({
    required this.service,
    required this.broker,
    required this.variables,
  });

  @override
  State<_ConfigPanel> createState() => _ConfigPanelState();
}

class _ConfigPanelState extends State<_ConfigPanel> {
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '1883');
  final _cidCtrl = TextEditingController(text: 'tcp_flutter');
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final List<TextEditingController> _topicCtrls = [];

  MqttService get _service => widget.service;
  MqttBrokerService get _broker => widget.broker;
  VariablesService get _vars => widget.variables;

  @override
  void initState() {
    super.initState();
    final cfg = _service.config;
    _hostCtrl.text = cfg.host;
    _portCtrl.text = cfg.port.toString();
    _cidCtrl.text = cfg.clientIdTemplate;
    _userCtrl.text = cfg.username;
    _passCtrl.text = cfg.password;
    for (final t in cfg.topics) {
      _topicCtrls.add(TextEditingController(text: t));
    }
    if (_topicCtrls.isEmpty) {
      _topicCtrls.add(TextEditingController());
    }
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _cidCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    for (final c in _topicCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final config = MqttClientConfig(
      host: _hostCtrl.text.trim(),
      port: int.tryParse(_portCtrl.text.trim()) ?? 1883,
      username: _userCtrl.text.trim(),
      password: _passCtrl.text.trim(),
      clientIdTemplate: _cidCtrl.text.trim(),
      topics: [
        for (final c in _topicCtrls)
          if (c.text.trim().isNotEmpty) c.text.trim(),
      ],
    );
    _service.saveConfig(config);
    Navigator.pop(context);
  }

  Future<void> _startBroker() async {
    final error = await _broker.start();
    if (error != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error), duration: const Duration(seconds: 3)),
      );
    }
  }

  Future<void> _stopBroker() => _broker.stop();

  /// 将连接配置切换为内置 Broker，并关闭面板触发自动连接
  void _connectLocal() {
    final cfg = _service.config;
    _service.saveConfig(cfg.copyWith(host: '127.0.0.1', port: _broker.port));
    Navigator.pop(context, 'connect_local');
  }

  Widget _buildBrokerCard() {
    final running = _broker.running;
    final port = _broker.port;
    final lanIp = _broker.lanIpV4;
    final logColor = Theme.of(context).colorScheme.primary;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      running ? Icons.hub : Icons.hub_outlined,
                      size: 18,
                      color: logColor,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      '内置测试 Broker',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: (running
                                ? Colors.greenAccent
                                : Colors.grey)
                            .withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        running ? '运行中' : '已停止',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: running ? Colors.greenAccent : Colors.grey,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (running) ...[
                  _brokerInfoRow('监听', '0.0.0.0:$port'),
                  _brokerInfoRow('本机连接', '127.0.0.1:$port'),
                  if (lanIp != null) _brokerInfoRow('局域网设备', '$lanIp:$port'),
                  _brokerInfoRow('在线客户端', '${_broker.clientCount} 个'),
                ] else
                  const Text(
                    '在应用进程内运行一个 MQTT 3.1.1 broker，'
                    '无需外部服务，可用于本机或局域网临时测试。',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: running ? _stopBroker : _startBroker,
                        icon: Icon(
                          running ? Icons.stop : Icons.play_arrow,
                          size: 18,
                        ),
                        label: Text(running ? '停止' : '启动'),
                      ),
                    ),
                    if (running) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _connectLocal,
                          icon: const Icon(Icons.link, size: 18),
                          label: const Text('用此 Broker 连接'),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          if (running) ...[
            const Divider(height: 1),
            ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 12),
              title: const Text(
                '运行日志',
                style: TextStyle(fontSize: 12),
              ),
              children: [
                if (_broker.logs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text(
                      '暂无事件',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  )
                else
                  SizedBox(
                    height: 140,
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      itemCount: _broker.logs.length,
                      itemBuilder: (context, i) {
                        final e = _broker.logs[i];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: Text.rich(
                            TextSpan(
                              style: const TextStyle(
                                fontSize: 11,
                                fontFamily: 'monospace',
                              ),
                              children: [
                                TextSpan(
                                  text:
                                      '${e.time.hour.toString().padLeft(2, '0')}:'
                                      '${e.time.minute.toString().padLeft(2, '0')}:'
                                      '${e.time.second.toString().padLeft(2, '0')}  ',
                                  style: TextStyle(
                                    color: Colors.grey.shade500,
                                  ),
                                ),
                                TextSpan(
                                  text: e.message,
                                  style: TextStyle(
                                    color: _brokerLogColor(e.kind),
                                  ),
                                ),
                              ],
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 4),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _brokerInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _brokerLogColor(MqttBrokerLogKind kind) {
    return switch (kind) {
      MqttBrokerLogKind.system => Colors.grey,
      MqttBrokerLogKind.connect => Colors.greenAccent,
      MqttBrokerLogKind.disconnect => Colors.orangeAccent,
      MqttBrokerLogKind.subscribe => Colors.lightBlueAccent,
      MqttBrokerLogKind.publish => Theme.of(context).colorScheme.primary,
      MqttBrokerLogKind.error => Colors.redAccent,
    };
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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListenableBuilder(
              listenable: _broker,
              builder: (context, _) => _buildBrokerCard(),
            ),
            const SizedBox(height: 16),
            Text('连接配置', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                SizedBox(
                  width: 220,
                  child: TextField(
                    controller: _hostCtrl,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      labelText: 'broker 地址',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                SizedBox(
                  width: 90,
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
                SizedBox(
                  width: 200,
                  child: VariableAwareTextField(
                    controller: _cidCtrl,
                    variables: _vars,
                    style: const TextStyle(fontSize: 13),
                    labelText: 'client id（支持 \$(变量)）',
                    bordered: true,
                  ),
                ),
                SizedBox(
                  width: 140,
                  child: TextField(
                    controller: _userCtrl,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      labelText: '用户名',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                SizedBox(
                  width: 140,
                  child: TextField(
                    controller: _passCtrl,
                    obscureText: true,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      labelText: '密码',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text('主题模板', style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                TextButton.icon(
                  onPressed: () =>
                      setState(() => _topicCtrls.add(TextEditingController())),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('添加'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            for (var i = 0; i < _topicCtrls.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: VariableAwareTextField(
                        controller: _topicCtrls[i],
                        variables: _vars,
                        style: const TextStyle(fontSize: 13),
                        labelText: '主题模板 ${i + 1}',
                        hintText:
                            'sensors/\$(device_id)/data',
                        bordered: true,
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: '删除',
                      onPressed: _topicCtrls.length > 1
                          ? () {
                              final c = _topicCtrls.removeAt(i);
                              c.dispose();
                              setState(() {});
                            }
                          : null,
                      icon: const Icon(Icons.delete_outline, size: 20),
                    ),
                  ],
                ),
              ),
            const Text(
              '支持 \$(变量)',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            // 模板变量（可折叠快捷填写，与设置页联动）
            Card(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: ExpansionTile(
                leading: const Icon(Icons.data_object, size: 20),
                title: Text(
                  '模板变量（${_vars.items.length}）',
                  style: const TextStyle(fontSize: 14),
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: ListenableBuilder(
                      listenable: _vars,
                      builder: (context, _) {
                        return Column(
                          children: [
                            // 每行使用独立 StatefulWidget，controller 稳定，输入不失焦
                            for (final it in _vars.items)
                              _VariableEditRow(
                                key: ValueKey('panel_var_${it.name}'),
                                item: it,
                                service: _vars,
                              ),
                            if (_vars.isEmpty)
                              const Text(
                                '暂无变量，请到「设置 · 模板变量」添加',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                            const SizedBox(height: 4),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                onPressed: () {
                                  Navigator.pop(context); // 关闭面板
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          VariablesScreen(service: _vars),
                                    ),
                                  );
                                },
                                icon: const Icon(
                                  Icons.settings_outlined,
                                  size: 14,
                                ),
                                label: const Text('管理全部变量'),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('保存配置'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

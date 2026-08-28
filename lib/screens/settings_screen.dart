import 'package:flutter/material.dart';

import '../services/global_log_service.dart';
import '../services/tcp_service.dart';
import '../services/theme_service.dart';
import '../services/variables_service.dart';
import 'history_screen.dart';
import 'log_viewer_screen.dart';
import 'protocol_docs_screen.dart';
import 'quick_commands_screen.dart';
import 'theme_screen.dart';
import 'variables_screen.dart';

/// 设置页（一级）：按工具分类的简洁入口列表，具体设置项在二级页面中。
class SettingsScreen extends StatefulWidget {
  final TcpService service;
  final VariablesService variables;
  final ThemeService theme;
  final GlobalLogService globalLog;

  const SettingsScreen({
    super.key,
    required this.service,
    required this.variables,
    required this.theme,
    required this.globalLog,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  /// OTA 协议接入文档（随仓库发布的公开资源）
  static const _otaProtocolAsset = 'assets/docs/OTA_PROTOCOL.md';

  TcpService get _service => widget.service;
  VariablesService get _vars => widget.variables;
  ThemeService get _theme => widget.theme;
  GlobalLogService get _globalLog => widget.globalLog;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('应用设置'),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([_service, _vars, _theme]),
        builder: (context, _) {
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final sections = _buildSections();
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                    children: constraints.maxWidth >= 820
                        ? [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    children: [sections[0], sections[2]],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(child: sections[1]),
                              ],
                            ),
                          ]
                        : sections,
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }

  List<Widget> _buildSections() {
    return [
      _sectionBlock('TCP 工具', [
        _entryTile(
          icon: Icons.bookmarks_outlined,
          title: '快捷指令',
          subtitle: '${_service.quickCommands.length} 条可用指令',
          onTap: () =>
              _open(QuickCommandsScreen(service: _service, variables: _vars)),
        ),
        _entryTile(
          icon: Icons.history,
          title: '历史记录',
          subtitle:
              '指令 ${_service.history.length} 条 · 连接 ${_service.connections.length} 条',
          onTap: () => _open(HistoryScreen(service: _service)),
        ),
        ListTile(
          leading: const Icon(Icons.system_update_alt),
          title: const Text('OTA 固件升级扩展'),
          subtitle: const Text(
            '针对特定设备（如支持 JSON OTA 的设备）的固件升级协议。'
            '开启后 TCP 工具页显示升级入口；设备需支持对应协议',
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 二级页入口：OTA 协议接入文档
              IconButton(
                tooltip: 'OTA 协议接入文档',
                visualDensity: VisualDensity.compact,
                iconSize: 20,
                icon: const Icon(Icons.menu_book_outlined),
                onPressed: () => _open(const ProtocolDocsScreen(
                  assetPath: _otaProtocolAsset,
                  title: 'OTA 协议接入文档',
                )),
              ),
              Switch(
                value: _service.otaEnabled,
                onChanged: (v) => _service.setOtaEnabled(v),
              ),
            ],
          ),
        ),
      ]),
      _sectionBlock('通用', [
        _entryTile(
          icon: Icons.data_object,
          title: '模板变量',
          subtitle: '${_vars.items.length} 个变量，可在 TCP/MQTT 中展开',
          onTap: () => _open(VariablesScreen(service: _vars)),
        ),
        _entryTile(
          icon: Icons.palette_outlined,
          title: '主题外观',
          subtitle: '亮暗模式、主色与日志字号',
          onTap: () => _open(ThemeScreen(theme: _theme)),
        ),
      ]),
      _sectionBlock('帮助', [
        _entryTile(
          icon: Icons.menu_book_outlined,
          title: '指令协议文档',
          subtitle: '查看内置协议文档',
          onTap: () => _open(const ProtocolDocsScreen()),
        ),
        _entryTile(
          icon: Icons.list_alt,
          title: '系统日志',
          subtitle: '${_globalLog.logs.length} 条日志，统一查看各模块运行记录',
          onTap: () => _open(LogViewerScreen(service: _globalLog)),
        ),
        const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('TCP / MQTT 调试工具'),
        ),
      ]),
    ];
  }

  Widget _sectionBlock(
    String title,
    List<Widget> children,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [_sectionTitle(title), _sectionCard(children)],
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 22, 4, 8),
      child: Text(text, style: Theme.of(context).textTheme.titleMedium),
    );
  }

  Widget _sectionCard(List<Widget> children) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            children[i],
            if (i != children.length - 1)
              Divider(
                height: 1,
                indent: 56,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
          ],
        ],
      ),
    );
  }

  Widget _entryTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
      title: Text(title),
      subtitle: Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }

  void _open(Widget page) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }
}

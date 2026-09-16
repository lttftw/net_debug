import 'package:flutter/material.dart';

import '../services/app_settings_service.dart';
import '../services/global_log_service.dart';
import '../services/modbus_service.dart';
import '../services/mqtt_broker_service.dart';
import '../services/mqtt_service.dart';
import '../services/command_preset_service.dart';
import '../services/serial_service.dart';
import '../services/tcp_service.dart';
import '../services/theme_service.dart';
import '../services/topic_template_service.dart';
import '../services/variables_service.dart';
import 'home_screen.dart';
import 'modbus_screen.dart';
import 'mqtt_screen.dart';
import 'serial_screen.dart';
import 'settings_screen.dart';

/// 主框架：底栏三页（TCP 工具 / MQTT 工具 / 设置）。
/// TCP 工具与 MQTT 工具彼此独立（各自持有独立的 service）；
/// 模板变量（VariablesService）全局共享，供主题模板、client id、
/// 快捷指令等展开使用。
/// 使用 IndexedStack 保持各页状态（连接、日志、表单等不因切换而丢失）。
class MainShell extends StatefulWidget {
  final ThemeService theme;

  const MainShell({super.key, required this.theme});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  final GlobalLogService _globalLog = GlobalLogService();
  final TcpService _tcpService = TcpService();
  final MqttService _mqttService = MqttService();
  final MqttBrokerService _brokerService = MqttBrokerService();
  final TopicTemplateService _topicTemplates = TopicTemplateService();
  final CommandPresetService _quickCommands = CommandPresetService();
  final CommandPresetService _mqttQuickCommands = CommandPresetService.mqtt();
  final CommandPresetService _modbusQuickCommands = CommandPresetService.modbus();
  final ModbusTcpService _modbusService = ModbusTcpService();
  final CommandPresetService _serialQuickCommands = CommandPresetService.serial();
  final SerialService _serialService = SerialService();
  final VariablesService _vars = VariablesService();
  int _index = 0;

  ThemeService get _theme => widget.theme;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tcpService.init(globalLog: _globalLog);
    _mqttService.init(globalLog: _globalLog);
    _brokerService.init(globalLog: _globalLog);
    _modbusService.init(globalLog: _globalLog);
    _modbusService.loadConnections();
    _serialService.init(globalLog: _globalLog);
    _serialService.loadHistory();
    _globalLog.load();
    AppSettingsService.instance.load();
    _tcpService.loadHistory();
    _tcpService.loadSettings();
    _mqttService.loadConfig();
    _topicTemplates.load();
    _quickCommands.load();
    _mqttQuickCommands.load();
    _modbusQuickCommands.load();
    _serialQuickCommands.load();
    _vars.load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _globalLog.dispose();
    _tcpService.dispose();
    _mqttService.dispose();
    _brokerService.dispose();
    _modbusService.dispose();
    _serialService.dispose();
    _topicTemplates.dispose();
    _quickCommands.dispose();
    _mqttQuickCommands.dispose();
    _modbusQuickCommands.dispose();
    _serialQuickCommands.dispose();
    _vars.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      HomeScreen(
        service: _tcpService,
        variables: _vars,
        theme: _theme,
        quickCommands: _quickCommands,
      ),
      MqttScreen(
        service: _mqttService,
        broker: _brokerService,
        variables: _vars,
        topics: _topicTemplates,
        theme: _theme,
        quickCommands: _mqttQuickCommands,
      ),
      ModbusScreen(
        service: _modbusService,
        quickCommands: _modbusQuickCommands,
        theme: _theme,
        variables: _vars,
      ),
      SerialScreen(
        service: _serialService,
        quickCommands: _serialQuickCommands,
        theme: _theme,
        variables: _vars,
      ),
      SettingsScreen(
        service: _tcpService,
        mqtt: _mqttService,
        variables: _vars,
        theme: _theme,
        globalLog: _globalLog,
        topics: _topicTemplates,
        quickCommands: _quickCommands,
        mqttQuickCommands: _mqttQuickCommands,
        modbusQuickCommands: _modbusQuickCommands,
        serialQuickCommands: _serialQuickCommands,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final useRail = constraints.maxWidth >= 840;
        final body = IndexedStack(index: _index, children: pages);
        if (!useRail) {
          return Scaffold(
            body: body,
            bottomNavigationBar: NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: _selectPage,
              destinations: _destinations,
            ),
          );
        }
        return Scaffold(
          body: Row(
            children: [
              SafeArea(
                child: NavigationRail(
                  selectedIndex: _index,
                  onDestinationSelected: _selectPage,
                  leading: Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 20),
                    child: Tooltip(
                      message: 'TCP / MQTT 调试工具',
                      child: CircleAvatar(
                        backgroundColor: Theme.of(context)
                            .colorScheme
                            .primaryContainer,
                        child: Icon(
                          Icons.memory,
                          color: Theme.of(context)
                              .colorScheme
                              .onPrimaryContainer,
                        ),
                      ),
                    ),
                  ),
                  destinations: const [
                    NavigationRailDestination(
                      icon: Icon(Icons.cable_outlined),
                      selectedIcon: Icon(Icons.cable),
                      label: Text('TCP'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.hub_outlined),
                      selectedIcon: Icon(Icons.hub),
                      label: Text('MQTT'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.dns_outlined),
                      selectedIcon: Icon(Icons.dns),
                      label: Text('Modbus'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.settings_input_component_outlined),
                      selectedIcon: Icon(Icons.settings_input_component),
                      label: Text('串口'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.tune_outlined),
                      selectedIcon: Icon(Icons.tune),
                      label: Text('设置'),
                    ),
                  ],
                ),
              ),
              VerticalDivider(
                width: 1,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              Expanded(child: body),
            ],
          ),
        );
      },
    );
  }

  void _selectPage(int index) => setState(() => _index = index);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 进入后台/失焦时把缓冲的日志落盘，避免进程被杀丢日志
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _globalLog.flush();
    }
    super.didChangeAppLifecycleState(state);
  }

  static const _destinations = [
    NavigationDestination(
      icon: Icon(Icons.cable_outlined),
      selectedIcon: Icon(Icons.cable),
      label: 'TCP',
    ),
    NavigationDestination(
      icon: Icon(Icons.hub_outlined),
      selectedIcon: Icon(Icons.hub),
      label: 'MQTT',
    ),
    NavigationDestination(
      icon: Icon(Icons.dns_outlined),
      selectedIcon: Icon(Icons.dns),
      label: 'Modbus',
    ),
    NavigationDestination(
      icon: Icon(Icons.settings_input_component_outlined),
      selectedIcon: Icon(Icons.settings_input_component),
      label: '串口',
    ),
    NavigationDestination(
      icon: Icon(Icons.tune_outlined),
      selectedIcon: Icon(Icons.tune),
      label: '设置',
    ),
  ];
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'screens/main_shell.dart';
import 'services/theme_service.dart';

void main() {
  // Windows/Linux 桌面使用 sqflite_common_ffi 提供 sqlite 支持
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  runApp(const TcpDebuggerApp());
}

class TcpDebuggerApp extends StatefulWidget {
  const TcpDebuggerApp({super.key});

  @override
  State<TcpDebuggerApp> createState() => _TcpDebuggerAppState();
}

class _TcpDebuggerAppState extends State<TcpDebuggerApp> {
  final ThemeService _theme = ThemeService();

  @override
  void initState() {
    super.initState();
    _theme.load();
    _theme.addListener(_onThemeChanged);
  }

  @override
  void dispose() {
    _theme.removeListener(_onThemeChanged);
    _theme.dispose();
    super.dispose();
  }

  void _onThemeChanged() {
    setState(() {}); // 主题色变化时重建以应用新主题
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TCP / MQTT 调试工具',
      debugShowCheckedModeBanner: false,
      // 固定中文（LTR）区域 + 全局强制 LTR 文本方向，
      // 避免部分设备 RTL 区域设置导致输入框从右向左
      locale: const Locale('zh', 'CN'),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.ltr, child: child!),
      theme: _theme.buildTheme(),
      home: MainShell(theme: _theme),
    );
  }
}

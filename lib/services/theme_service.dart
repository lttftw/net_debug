import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/message_display_style.dart';
import 'app_state_db.dart';

/// 全局主题配色统一管理。
/// 深色/浅色模式各自维护一套主色与收发记录色，切换亮度自动使用对应配置；
/// 消息显示样式与日志字体大小全局共享。所有颜色均由此服务读取，
/// 不在界面代码中硬编码。
class ThemeService extends ChangeNotifier {
  // 深色模式预设（青蓝 + 亮色 TX/RX，深背景上清晰）
  static const _kDarkSeed = Color(0xFF26C6DA);
  static const _kDarkTx = Color(0xFF00E5FF);
  static const _kDarkRx = Color(0xFF80D8FF);
  // 浅色模式预设（深青蓝，浅背景上可读）
  static const _kLightSeed = Color(0xFF00838F);
  static const _kLightTx = Color(0xFF00838F);
  static const _kLightRx = Color(0xFF0277BD);

  Color _darkSeed = _kDarkSeed;
  Color _darkTx = _kDarkTx;
  Color _darkRx = _kDarkRx;
  Color _lightSeed = _kLightSeed;
  Color _lightTx = _kLightTx;
  Color _lightRx = _kLightRx;
  bool _dark = true;
  double _logFontSize = 12;
  MessageDisplayStyle _messageDisplayStyle = MessageDisplayStyle.formattedJson;

  bool get isDark => _dark;
  double get logFontSize => _logFontSize;
  MessageDisplayStyle get messageDisplayStyle => _messageDisplayStyle;

  /// 当前亮度模式下生效的颜色
  Color get seedColor => _dark ? _darkSeed : _lightSeed;
  Color get txColor => _dark ? _darkTx : _lightTx;
  Color get rxColor => _dark ? _darkRx : _lightRx;

  /// 界面使用的 TX/RX 色：亮色模式下自动加深以保证对比度
  Color get effectiveTxColor =>
      _dark ? txColor : Color.lerp(txColor, Colors.black, 0.45)!;
  Color get effectiveRxColor =>
      _dark ? rxColor : Color.lerp(rxColor, Colors.black, 0.35)!;

  /// 生成基于当前主色与亮暗模式的 Material 主题
  ThemeData buildTheme() {
    final scheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: _dark ? Brightness.dark : Brightness.light,
      surface: _dark ? const Color(0xFF0F1518) : const Color(0xFFF6F8F8),
    );
    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.standard,
      // 统一使用内置思源黑体，保证各平台中文渲染一致
      fontFamily: 'NotoSansSC',
      appBarTheme: AppBarTheme(
        toolbarHeight: 56,
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: scheme.surface,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .7)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLowest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 13,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
        ),
      ),
      navigationRailTheme: const NavigationRailThemeData(
        groupAlignment: -0.8,
        labelType: NavigationRailLabelType.all,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 46),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 46),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
    );
    return base.copyWith(
      textTheme: base.textTheme.copyWith(
        headlineSmall: base.textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Future<void> load() async {
    try {
      // 迁移旧版 JSON 后从统一 sqlite 读取运行时外观配置
      await AppStateDb.instance.migrateFileToKey(
        AppStateDb.themeKey,
        'theme_config.json',
      );
      final raw = await AppStateDb.instance.read(AppStateDb.themeKey);
      if (raw != null) {
        final json = jsonDecode(raw);
        final map = (json as Map).cast<String, dynamic>();
        // 兼容旧格式（seed/tx/rx 作为深色配置）
        final legacySeed = map['seed'] as int?;
        final legacyTx = map['tx'] as int?;
        final legacyRx = map['rx'] as int?;
        final darkSeed = map['darkSeed'] as int?;
        final darkTx = map['darkTx'] as int?;
        final darkRx = map['darkRx'] as int?;
        final lightSeed = map['lightSeed'] as int?;
        final lightTx = map['lightTx'] as int?;
        final lightRx = map['lightRx'] as int?;
        final dark = map['dark'] as bool?;
        final logFontSize = map['logFontSize'] as num?;
        final messageDisplayStyle = map['messageDisplayStyle'] as String?;
        if (darkSeed != null) {
          _darkSeed = Color(darkSeed);
        } else if (legacySeed != null) {
          _darkSeed = Color(legacySeed);
        }
        if (darkTx != null) {
          _darkTx = Color(darkTx);
        } else if (legacyTx != null) {
          _darkTx = Color(legacyTx);
        }
        if (darkRx != null) {
          _darkRx = Color(darkRx);
        } else if (legacyRx != null) {
          _darkRx = Color(legacyRx);
        }
        if (lightSeed != null) _lightSeed = Color(lightSeed);
        if (lightTx != null) _lightTx = Color(lightTx);
        if (lightRx != null) _lightRx = Color(lightRx);
        if (dark != null) _dark = dark;
        if (logFontSize != null) _logFontSize = logFontSize.toDouble();
        if (messageDisplayStyle != null) {
          _messageDisplayStyle = MessageDisplayStyle.values.firstWhere(
            (style) => style.name == messageDisplayStyle,
            orElse: () => MessageDisplayStyle.formattedJson,
          );
        }
      }
    } catch (_) {}
    notifyListeners();
  }

  /// 切换亮/暗模式（各自独立记忆配色）
  Future<void> setDark(bool dark) async {
    _dark = dark;
    await _save();
    notifyListeners();
  }

  Future<void> setSeed(Color c) async {
    if (_dark) {
      _darkSeed = c;
    } else {
      _lightSeed = c;
    }
    await _save();
    notifyListeners();
  }

  Future<void> setTx(Color c) async {
    if (_dark) {
      _darkTx = c;
    } else {
      _lightTx = c;
    }
    await _save();
    notifyListeners();
  }

  Future<void> setRx(Color c) async {
    if (_dark) {
      _darkRx = c;
    } else {
      _lightRx = c;
    }
    await _save();
    notifyListeners();
  }

  Future<void> setLogFontSize(double size) async {
    _logFontSize = size;
    await _save();
    notifyListeners();
  }

  Future<void> setMessageDisplayStyle(MessageDisplayStyle style) async {
    _messageDisplayStyle = style;
    await _save();
    notifyListeners();
  }

  Future<void> reset() async {
    _darkSeed = _kDarkSeed;
    _darkTx = _kDarkTx;
    _darkRx = _kDarkRx;
    _lightSeed = _kLightSeed;
    _lightTx = _kLightTx;
    _lightRx = _kLightRx;
    _dark = true;
    _logFontSize = 12;
    _messageDisplayStyle = MessageDisplayStyle.formattedJson;
    await _save();
    notifyListeners();
  }

  Future<void> _save() async {
    await AppStateDb.instance.write(
      AppStateDb.themeKey,
      jsonEncode({
        'darkSeed': _darkSeed.toARGB32(),
        'darkTx': _darkTx.toARGB32(),
        'darkRx': _darkRx.toARGB32(),
        'lightSeed': _lightSeed.toARGB32(),
        'lightTx': _lightTx.toARGB32(),
        'lightRx': _lightRx.toARGB32(),
        'dark': _dark,
        'logFontSize': _logFontSize,
        'messageDisplayStyle': _messageDisplayStyle.name,
      }),
    );
  }
}

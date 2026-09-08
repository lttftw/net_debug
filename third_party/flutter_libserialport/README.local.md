# flutter_libserialport（本地裁剪版）

从 pub.dev 0.6.0 复制而来，原因是原包在 Gradle 9 下无法通过 Android 构建：

- 原包 pubspec 声明支持 Android，但其 `android/build.gradle` 调用了两处
  `jcenter()`（Gradle 9 已移除该方法），每次 `flutter build apk` 都会 evaluate
  到这段脚本并失败。
- 本项目串口功能仅用于 Windows 桌面端，不需要 Android 平台实现。

本地化处理：

1. 复制完整包到 `third_party/flutter_libserialport`；
2. 删除 `android/` 目录；
3. pubspec 的 `flutter.plugin.platforms` 移除 `android` 条目；
4. 根 pubspec 通过 `dependency_overrides` 指向本目录。

主项目 pubspec.yaml 中有对应的 override 与注释。上游更新时按相同步骤
重新同步即可。

依赖：Dart 侧 `libserialport: ^0.3.0`（纯 Dart 绑定，无 Android 原生代码，
不受影响）。

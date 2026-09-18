# debug_tools 项目笔记

## 构建环境
- Flutter 3.47.4 stable（`C:\envs\flutter`），SDK 位于 `C:\envs\Android`，JDK 21（`C:\envs\jdk-21`）。
- Android SDK：platform android-36（compileSdk 用大版本 36）+ android-36.1（QPR2，备用）、build-tools 36.1.0、NDK 30.0.16248370。
- AGP 9.1.0 / Kotlin 2.4.0 / Gradle 9.3.1（与 Flutter 模板一致）。
- 国内网络：Maven 用阿里云镜像；Flutter 引擎工件用 `storage.flutter-io.cn` 镜像（写在 allprojects.repositories 最前面优先命中）。

## 项目约定
- 仅打包 arm64-v8a（app/build.gradle.kts 的 ndk.abiFilters + gradle.properties 的 disable-abi-filtering=true）。
- flutter_libserialport 本地化到 third_party/（原包 jcenter() 破坏 Gradle 9 构建），串口仅 Windows 端使用。
- 插件 SDK 版本统一覆盖写在 android/build.gradle.kts 的 `androidComponents.finalizeDsl` 中（时机坑：plugins.withId 会被插件覆盖回去；afterEvaluate 报 too late to set）。
- compileSdk 用大版本 36（普通 Int 赋值）；如需 36.1（QPR2 minor 平台）须用 `compileSdk { version = release(36) { minorApiLevel = 1 } }` DSL。
- release 签名走 android/key.properties（不入库），缺失时回退 debug 签名。

## 已知告警
- mobile_scanner 仍使用 KGP（旧 Kotlin 插件），Flutter 未来版本会构建失败，需关注其升级。
- flutter_markdown 已 discontinued，官方建议迁到 flutter_markdown_plus。

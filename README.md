# TCP / MQTT 调试工具

基于 Flutter 的多平台（Windows / Android）网络调试客户端，内置独立的
TCP 与 MQTT 调试能力，适用于协议调试、物联网设备联调等场景。

## 功能特性

- **TCP 调试**：连接/断开 TCP 服务器；按行解析响应并自动美化 JSON；
  TX / RX / SYS / ERR 分色日志，带毫秒时间戳、自动滚动、可清空
- **快捷指令**：点击回填到输入框，支持自定义、编辑、删除与恢复默认
- **历史记录**：命令历史与连接历史自动保存（各 100 / 10 条），可回填、可清空
- **MQTT 调试**：独立客户端，可视化配置（服务器/端口/client id/账号/
  多主题模板）；订阅与发布（QoS 0/1/2），收发合并的消息记录，文本可选中复制
- **内置 MQTT Broker**：应用内运行纯 Dart MQTT 3.1.1 broker，本机或局域网
  临时测试无需外部服务，可一键连接
- **模板变量**：统一管理主题、client id、快捷指令中的 `$(变量)`，自动展开
- **主题外观**：亮/暗模式、主色、收发记录色、日志字体大小，均可配置并持久化
- **内嵌文档**：Markdown 渲染的协议文档，含悬浮目录与代码块一键复制
- **本地持久化**：配置与历史自动保存，升级不丢失
- **开源与更新**：应用内可查看源码、许可证、问题反馈入口，并按需检查
  GitHub 最新正式 Release

## 开源信息

- 源码仓库：<https://github.com/lttftw/net_debug>
- 问题反馈：<https://github.com/lttftw/net_debug/issues>
- 开源许可：[MIT License](LICENSE)

应用的「设置 → 关于与更新」页面可查看当前安装版本并手动检查更新。
检查更新只在用户点击时访问 GitHub，不会启动后台轮询。

## 界面结构

底栏三页（宽屏为侧栏导航），各工具独立运行，切换不中断连接：

| 页面 | 说明 |
| --- | --- |
| TCP 工具 | 连接栏、快捷指令、日志区、指令发送 |
| MQTT 工具 | 连接栏、订阅行、消息记录区、发布面板 |
| 设置 | 快捷指令管理、历史清理、模板变量、主题外观、协议文档 |
| 扩展 | OTA 固件升级（默认关闭，可在设置中开启） |

## 运行

```bash
cd debug_tools
flutter pub get

flutter run -d windows   # Windows 桌面
flutter run -d <device>  # Android 等移动设备
```

## 自动构建

仓库内置 GitHub Actions 工作流 `.github/workflows/build.yml`：

- 推送到 `main`、提交 Pull Request、推送 `v*` 标签或手动触发时运行
- 先执行 `flutter analyze` 与全部测试，通过后并行构建 Android 和 Windows
- 在 Actions 运行记录中提供带版本号的 APK 与 Windows x64 ZIP，保留 14 天
- 推送与 `pubspec.yaml` 版本一致的 `v*` 标签时，自动创建正式 GitHub
  Release，并附加 APK、Windows ZIP 与 `SHA256SUMS.txt`

Android 正式发布使用仓库 Actions Secrets 中的
`ANDROID_KEYSTORE_BASE64`、`ANDROID_STORE_PASSWORD`、
`ANDROID_KEY_PASSWORD` 和 `ANDROID_KEY_ALIAS`。普通构建未配置密钥时仍会按
项目现有规则回退到 debug 签名；标签发布则强制要求四项签名 Secret 完整。

## 使用说明

1. **TCP**：输入服务器地址与端口，点击「连接」；在输入框发送指令，
   或点击快捷指令回填后发送
2. **MQTT**：配置 broker 地址并连接，订阅主题后即可收发消息；
   临时自测可先在配置面板启动「内置测试 Broker」并一键连接
3. 日志区可查看并选中复制收发记录

## 内置数据资源

指令模板与协议文档已从代码解耦为独立资源文件，采用「完整版优先、缺失回退示范版」的加载机制：

| 资源 | 公开版（随仓库发布） | 完整版（本地可选，git 忽略） |
| --- | --- | --- |
| 指令模板 | `assets/presets/quick_commands.json`（示范） | `assets/presets/quick_commands.full.json` |
| 模板变量 | `assets/variables/variables.json`（示范） | `assets/variables/variables.full.json` |
| 协议文档 | `assets/docs/TCP_JSON_PROTOCOL.md`（示范） | `assets/docs/TCP_JSON_PROTOCOL.full.md` |

- 应用启动时**先尝试加载完整版资源，不存在则回退公开版示范资源**，因此
  无论是否提供完整版文件，构建与运行都正常
- 公开仓库仅发布公开版示范文件；完整版文件放在同目录下即可自动启用
  （已在 `.gitignore` 中忽略，不会被提交）

## 目录结构

```
lib/
├── main.dart                       # 入口
├── models/
│   └── command_preset.dart         # 快捷指令模型 + JSON 预设加载（完整版优先/回退示范）
├── services/
│   ├── tcp_service.dart            # TCP 连接、按行解析、日志与历史
│   ├── mqtt_service.dart           # MQTT 客户端（连接/订阅/发布/日志/配置）
│   ├── mqtt_broker_service.dart    # 内置 MQTT Broker（本地临时测试）
│   ├── variables_service.dart      # 模板变量统一管理
│   └── theme_service.dart          # 主题配色管理（主色/收发记录色）
└── screens/
    ├── main_shell.dart             # 主框架（底栏三页容器）
    ├── home_screen.dart            # TCP 工具页
    ├── mqtt_screen.dart            # MQTT 工具页
    ├── settings_screen.dart        # 设置页
    ├── quick_commands_screen.dart  # 二级页：快捷指令管理
    ├── history_screen.dart         # 二级页：历史清理
    ├── theme_screen.dart           # 二级页：主题外观
    ├── variables_screen.dart       # 二级页：模板变量管理
    └── protocol_docs_screen.dart   # 二级页：内嵌协议文档

assets/
├── docs/                           # 协议文档（公开版 / 个人完整版）
├── presets/                        # 指令模板（公开版 / 个人完整版）
└── variables/                      # 模板变量定义（公开版 / 个人完整版）
```

## 数据存储

- 使用 SQLite 统一管理命令历史、连接配置与自定义快捷指令
- 数据库与应用配置存放于各平台的应用支持目录，升级不丢失
- MQTT 客户端配置、订阅列表与模板变量以 JSON 文件持久化

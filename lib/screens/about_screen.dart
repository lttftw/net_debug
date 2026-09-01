import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_update_service.dart';

class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  final AppUpdateService _updates = AppUpdateService();
  late final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();
  bool _checking = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('关于与更新')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Icon(
                        Icons.memory,
                        size: 52,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'TCP / MQTT 调试工具',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 6),
                      const Text('开源、跨平台的网络调试客户端'),
                      const SizedBox(height: 12),
                      FutureBuilder<PackageInfo>(
                        future: _packageInfo,
                        builder: (context, snapshot) {
                          final info = snapshot.data;
                          return Text(
                            info == null
                                ? '正在读取版本…'
                                : '版本 ${info.version} (${info.buildNumber})',
                            style: Theme.of(context).textTheme.bodySmall,
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.code),
                      title: const Text('开源仓库'),
                      subtitle: const Text('github.com/lttftw/net_debug'),
                      trailing: const Icon(Icons.open_in_new),
                      onTap: () => _openUri(AppUpdateService.repositoryUri),
                    ),
                    const Divider(height: 1, indent: 56),
                    ListTile(
                      leading: const Icon(Icons.balance_outlined),
                      title: const Text('开源许可证'),
                      subtitle: const Text('MIT License'),
                      trailing: const Icon(Icons.open_in_new),
                      onTap: () => _openUri(AppUpdateService.licenseUri),
                    ),
                    const Divider(height: 1, indent: 56),
                    ListTile(
                      leading: const Icon(Icons.bug_report_outlined),
                      title: const Text('问题反馈'),
                      subtitle: const Text('前往 GitHub Issues'),
                      trailing: const Icon(Icons.open_in_new),
                      onTap: () => _openUri(AppUpdateService.issuesUri),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: ListTile(
                  leading: _checking
                      ? const SizedBox.square(
                          dimension: 24,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        )
                      : const Icon(Icons.system_update_outlined),
                  title: const Text('检查更新'),
                  subtitle: const Text('查询 GitHub 最新正式 Release'),
                  trailing: const Icon(Icons.chevron_right),
                  enabled: !_checking,
                  onTap: _checking ? null : _checkForUpdate,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _checkForUpdate() async {
    setState(() => _checking = true);
    try {
      final packageInfo = await _packageInfo;
      final result = await _updates.checkForUpdate(packageInfo.version);
      if (!mounted) return;
      await _showUpdateResult(result);
    } on UpdateCheckException catch (error) {
      if (!mounted) return;
      _showMessage(error.message);
    } catch (_) {
      if (!mounted) return;
      _showMessage('检查更新失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _showUpdateResult(UpdateCheckResult result) async {
    final release = result.latestRelease;
    final notes = release.notes.trim();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          result.updateAvailable ? '发现新版本 ${release.tagName}' : '已是最新版本',
        ),
        content: SingleChildScrollView(
          child: Text(
            result.updateAvailable
                ? '${release.title}${notes.isEmpty ? '' : '\n\n$notes'}'
                : '当前版本 ${result.currentVersion}，最新版本 ${release.tagName}。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          if (result.updateAvailable)
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(context);
                _openUri(release.pageUri);
              },
              icon: const Icon(Icons.open_in_new),
              label: const Text('查看发布页'),
            ),
        ],
      ),
    );
  }

  Future<void> _openUri(Uri uri) async {
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && mounted) _showMessage('无法打开链接：$uri');
    } catch (_) {
      if (mounted) _showMessage('无法打开链接：$uri');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

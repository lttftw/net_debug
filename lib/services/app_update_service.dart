import 'dart:async';
import 'dart:convert';
import 'dart:io';

class ReleaseInfo {
  final String version;
  final String tagName;
  final String title;
  final String notes;
  final Uri pageUri;
  final DateTime? publishedAt;

  const ReleaseInfo({
    required this.version,
    required this.tagName,
    required this.title,
    required this.notes,
    required this.pageUri,
    required this.publishedAt,
  });
}

class UpdateCheckResult {
  final String currentVersion;
  final ReleaseInfo latestRelease;

  const UpdateCheckResult({
    required this.currentVersion,
    required this.latestRelease,
  });

  bool get updateAvailable =>
      AppUpdateService.compareVersions(latestRelease.version, currentVersion) >
      0;
}

class UpdateCheckException implements Exception {
  final String message;

  const UpdateCheckException(this.message);

  @override
  String toString() => message;
}

/// 按需查询 GitHub 最新正式 Release，不在后台常驻或自动轮询。
class AppUpdateService {
  static final Uri repositoryUri = Uri.parse(
    'https://github.com/lttftw/net_debug',
  );
  static final Uri issuesUri = Uri.parse(
    'https://github.com/lttftw/net_debug/issues',
  );
  static final Uri licenseUri = Uri.parse(
    'https://github.com/lttftw/net_debug/blob/main/LICENSE',
  );
  static final Uri latestReleaseApiUri = Uri.parse(
    'https://api.github.com/repos/lttftw/net_debug/releases/latest',
  );

  static const _maxResponseBytes = 1024 * 1024;
  static const _requestTimeout = Duration(seconds: 12);

  Future<UpdateCheckResult> checkForUpdate(String currentVersion) async {
    final client = HttpClient()..connectionTimeout = _requestTimeout;
    try {
      final request = await client
          .getUrl(latestReleaseApiUri)
          .timeout(_requestTimeout);
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'debug-tools-update-checker')
        ..set('X-GitHub-Api-Version', '2022-11-28');

      final response = await request.close().timeout(_requestTimeout);
      if (response.statusCode == HttpStatus.notFound) {
        throw const UpdateCheckException('开源仓库尚未发布正式版本');
      }
      if (response.statusCode != HttpStatus.ok) {
        throw UpdateCheckException(
          'GitHub 返回异常状态 ${response.statusCode}，请稍后重试',
        );
      }
      if (response.contentLength > _maxResponseBytes) {
        throw const UpdateCheckException('更新信息响应过大，已停止读取');
      }

      final bytes = <int>[];
      await for (final chunk in response.timeout(_requestTimeout)) {
        bytes.addAll(chunk);
        if (bytes.length > _maxResponseBytes) {
          throw const UpdateCheckException('更新信息响应过大，已停止读取');
        }
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('release response is not an object');
      }
      return UpdateCheckResult(
        currentVersion: currentVersion,
        latestRelease: parseRelease(decoded),
      );
    } on UpdateCheckException {
      rethrow;
    } on TimeoutException {
      throw const UpdateCheckException('检查更新超时，请检查网络后重试');
    } on SocketException {
      throw const UpdateCheckException('无法连接 GitHub，请检查网络后重试');
    } on FormatException {
      throw const UpdateCheckException('GitHub 返回的版本信息无法解析');
    } finally {
      client.close(force: true);
    }
  }

  static ReleaseInfo parseRelease(Map<String, dynamic> json) {
    final tagName = json['tag_name'];
    final pageUrl = json['html_url'];
    if (tagName is! String || tagName.trim().isEmpty || pageUrl is! String) {
      throw const FormatException('release fields are missing');
    }
    final pageUri = Uri.tryParse(pageUrl);
    if (pageUri == null || !pageUri.hasScheme) {
      throw const FormatException('release URL is invalid');
    }

    final publishedText = json['published_at'];
    return ReleaseInfo(
      version: normalizeVersion(tagName),
      tagName: tagName,
      title: switch (json['name']) {
        final String name when name.trim().isNotEmpty => name.trim(),
        _ => tagName,
      },
      notes: json['body'] is String ? json['body'] as String : '',
      pageUri: pageUri,
      publishedAt: publishedText is String
          ? DateTime.tryParse(publishedText)?.toLocal()
          : null,
    );
  }

  /// 比较常见的 `v1.2.3` / `1.2.3+4` 版本号；返回值语义同 Comparable。
  static int compareVersions(String left, String right) {
    final leftParts = _versionParts(left);
    final rightParts = _versionParts(right);
    final length = leftParts.length > rightParts.length
        ? leftParts.length
        : rightParts.length;
    for (var i = 0; i < length; i++) {
      final leftValue = i < leftParts.length ? leftParts[i] : 0;
      final rightValue = i < rightParts.length ? rightParts[i] : 0;
      final result = leftValue.compareTo(rightValue);
      if (result != 0) return result;
    }
    return 0;
  }

  static String normalizeVersion(String value) {
    final normalized = value.trim().replaceFirst(RegExp(r'^[vV](?=\d)'), '');
    return normalized.split(RegExp(r'[-+]')).first;
  }

  static List<int> _versionParts(String value) {
    final normalized = normalizeVersion(value);
    if (!RegExp(r'^\d+(\.\d+)*$').hasMatch(normalized)) {
      throw const FormatException('invalid version');
    }
    return normalized.split('.').map(int.parse).toList(growable: false);
  }
}

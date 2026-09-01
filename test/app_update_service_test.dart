import 'package:debug_tools/services/app_update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('open-source links point to the repository', () {
    expect(
      AppUpdateService.issuesUri.toString(),
      'https://github.com/lttftw/net_debug/issues',
    );
    expect(
      AppUpdateService.licenseUri.toString(),
      'https://github.com/lttftw/net_debug/blob/main/LICENSE',
    );
  });

  group('AppUpdateService.compareVersions', () {
    test('compares numeric segments instead of strings', () {
      expect(AppUpdateService.compareVersions('1.10.0', '1.9.9'), isPositive);
      expect(AppUpdateService.compareVersions('v2.0.0', '1.99.99'), isPositive);
      expect(AppUpdateService.compareVersions('1.0', '1.0.0'), 0);
    });

    test('ignores build metadata and prerelease suffix for release checks', () {
      expect(AppUpdateService.compareVersions('v1.2.3+8', '1.2.3+1'), 0);
      expect(
        AppUpdateService.compareVersions('1.2.3-beta.1', '1.2.2'),
        isPositive,
      );
    });

    test('rejects malformed versions', () {
      expect(
        () => AppUpdateService.compareVersions('latest', '1.0.0'),
        throwsFormatException,
      );
    });
  });

  test('parses GitHub release payload', () {
    final release = AppUpdateService.parseRelease({
      'tag_name': 'v1.3.0',
      'name': 'Debug Tools 1.3.0',
      'body': '修复若干问题',
      'html_url': 'https://github.com/lttftw/net_debug/releases/tag/v1.3.0',
      'published_at': '2026-09-01T00:00:00Z',
    });

    expect(release.version, '1.3.0');
    expect(release.title, 'Debug Tools 1.3.0');
    expect(release.notes, '修复若干问题');
    expect(release.publishedAt, isNotNull);
  });
}

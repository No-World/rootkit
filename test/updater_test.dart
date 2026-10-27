import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rootkit/updater.dart';

/// 更新检查的纯逻辑测试（不联网）：版本比较、Release 解析、失败文案。
void main() {
  group('版本比较', () {
    test('按数字分段比较（字符串比较会把 1.0.9 判成比 1.0.17 新）', () {
      expect(compareVersions('1.0.9', '1.0.17'), -1);
      expect(compareVersions('1.0.17', '1.0.9'), 1);
      expect(compareVersions('1.0.17', '1.0.17'), 0);
      expect(compareVersions('v1.0.18', '1.0.17'), 1);
      expect(compareVersions('1.1', '1.0.99'), 1);
      expect(compareVersions('2', '1.9.9'), 1);
    });

    test('缺的段按 0 处理', () {
      expect(compareVersions('1.0', '1.0.0'), 0);
      expect(compareVersions('1.0.0.1', '1.0'), 1);
    });

    test('tag 前缀与后缀（PR 测试包 -prtest / build number +10018）', () {
      expect(normalizeVersion('v1.0.18'), '1.0.18');
      expect(normalizeVersion('v1.0.18-prtest'), '1.0.18');
      expect(normalizeVersion('1.0.18+10018'), '1.0.18');
      expect(compareVersions('1.0.18-prtest', '1.0.18'), 0);
      expect(compareVersions('1.0.18+10018', '1.0.18'), 0);
    });
  });

  group('Release 解析', () {
    Map<String, dynamic> sample({String tag = 'v1.0.18'}) => <String, dynamic>{
          'tag_name': tag,
          'name': 'v1.0.18 —— 更新检查',
          'body': '## 新增\n'
              '- **更新检查**：见 [README](https://example.com)\n'
              '- 修 `x` 与 **y**\n',
          'html_url':
              'https://github.com/No-World/rootkit/releases/tag/v1.0.18',
          'published_at': '2026-10-26T08:00:00Z',
          'prerelease': false,
          'assets': <Map<String, dynamic>>[
            // 旁挂的 md5 不能被当成 APK
            {
              'name': 'RootKit-v1.0.18.apk.md5',
              'browser_download_url': 'https://example.com/apk.md5',
              'size': 32,
            },
            {
              'name': 'RootKit-v1.0.18.apk',
              'browser_download_url': 'https://example.com/apk',
              'size': 19922944,
            },
          ],
        };

    test('解析 tag / 版本 / APK 资产（跳过 .apk.md5）', () {
      final r = GitHubRelease.fromJson(sample());
      expect(r.tag, 'v1.0.18');
      expect(r.version, '1.0.18');
      expect(r.htmlUrl, contains('/releases/tag/v1.0.18'));
      expect(r.apkName, 'RootKit-v1.0.18.apk');
      expect(r.apkUrl, 'https://example.com/apk');
      expect(r.apkSize, 19922944);
      expect(r.prerelease, isFalse);
    });

    test('还没挂 APK（刚发完 Release 等 CI 构建）时 apkUrl 为空', () {
      final j = sample();
      j['assets'] = <Map<String, dynamic>>[];
      final r = GitHubRelease.fromJson(j);
      expect(r.apkUrl, isEmpty);
      expect(r.apkSize, 0);
    });

    test('更新说明摘要去掉 Markdown 符号', () {
      final s = GitHubRelease.fromJson(sample()).summary();
      expect(s, contains('新增'));
      expect(s, contains('更新检查：见 README'));
      expect(s, isNot(contains('**')));
      expect(s, isNot(contains('](')));
      expect(s, isNot(contains('`')));
    });

    test('摘要限行', () {
      final j = sample();
      j['body'] = List.generate(50, (i) => '- 第 $i 行').join('\n');
      final s = GitHubRelease.fromJson(j).summary(maxLines: 5);
      expect(s.split('\n').length, 6); // 5 行 + 省略号那行
      expect(s, endsWith('…'));
    });
  });

  group('UpdateCheck 判定', () {
    GitHubRelease rel(String tag) => GitHubRelease.fromJson(<String, dynamic>{
          'tag_name': tag,
          'assets': <Map<String, dynamic>>[],
        });

    test('线上更新 → hasUpdate / statusLine', () {
      final u = UpdateCheck(
        current: '1.0.17',
        latest: rel('v1.0.18'),
        at: DateTime(2026, 10, 26),
      );
      expect(u.ok, isTrue);
      expect(u.hasUpdate, isTrue);
      expect(u.upToDate, isFalse);
      expect(u.statusLine, contains('v1.0.18'));
    });

    test('线上更旧（本机是 PR 测试包/未发布版本）→ 不该提示更新', () {
      final u = UpdateCheck(
        current: '1.0.19',
        latest: rel('v1.0.16'),
        at: DateTime(2026, 10, 26),
      );
      expect(u.hasUpdate, isFalse);
      expect(u.upToDate, isTrue);
      expect(u.statusLine, contains('比线上新'));
    });

    test('已是最新', () {
      final u = UpdateCheck(
        current: '1.0.17',
        latest: rel('v1.0.17'),
        at: DateTime(2026, 10, 26),
      );
      expect(u.hasUpdate, isFalse);
      expect(u.statusLine, contains('已是最新'));
    });

    test('失败结果只带 error，不出异常', () {
      final u = UpdateCheck(
        current: '1.0.17',
        error: '网络不可用（Connection refused）',
        at: DateTime(2026, 10, 26),
      );
      expect(u.ok, isFalse);
      expect(u.hasUpdate, isFalse);
      expect(u.statusLine, contains('网络不可用'));
    });
  });

  group('展示辅助', () {
    test('formatBytes', () {
      expect(formatBytes(0), '未知大小');
      expect(formatBytes(19922944), '19.0MB');
      expect(formatBytes(1024), '1KB');
    });

    test('底层异常翻译成人话', () {
      expect(
          friendlyNetworkError(const SocketException('x')), contains('网络不可用'));
      expect(friendlyNetworkError(TimeoutException('x')), contains('超时'));
      expect(
          friendlyNetworkError(const FormatException('x')), contains('JSON'));
    });
  });
}

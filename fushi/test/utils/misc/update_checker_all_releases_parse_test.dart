import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';

/// TODO-1310：`fetchAllGitHubReleases` 的纯解析核心 [parseGitHubReleasesResponse]
/// 守卫——「查看更新日志」页依赖它把 GitHub `releases` 列表 API 响应体转成
/// release map 列表，过滤草稿、拒绝非数组。
void main() {
  group('parseGitHubReleasesResponse', () {
    test('保留已发布 release 并按原顺序返回', () {
      final String body = jsonEncode(<Map<String, dynamic>>[
        <String, dynamic>{
          'tag_name': 'v1.2.0',
          'body': '## 新增\n- 更新日志页',
          'prerelease': false,
          'draft': false,
        },
        <String, dynamic>{
          'tag_name': 'v1.1.0',
          'body': '修复若干问题',
          'prerelease': false,
          'draft': false,
        },
      ]);

      final List<Map<String, dynamic>> releases = parseGitHubReleasesResponse(
        body,
      );

      expect(releases, hasLength(2));
      expect(releases[0]['tag_name'], 'v1.2.0');
      expect(releases[1]['tag_name'], 'v1.1.0');
    });

    test('过滤 draft==true 的草稿', () {
      final String body = jsonEncode(<Map<String, dynamic>>[
        <String, dynamic>{'tag_name': 'v2.0.0-wip', 'draft': true},
        <String, dynamic>{'tag_name': 'v1.9.0', 'draft': false},
        <String, dynamic>{'tag_name': 'v1.8.0'},
      ]);

      final List<Map<String, dynamic>> releases = parseGitHubReleasesResponse(
        body,
      );

      expect(releases.map((Map<String, dynamic> r) => r['tag_name']), <String>[
        'v1.9.0',
        'v1.8.0',
      ]);
    });

    test('顶层非数组（如错误对象）返回空列表', () {
      final String body = jsonEncode(<String, dynamic>{
        'message': 'API rate limit exceeded',
      });

      expect(parseGitHubReleasesResponse(body), isEmpty);
    });

    test('数组内非对象元素被剔除', () {
      final String body = jsonEncode(<dynamic>[
        'not-an-object',
        42,
        <String, dynamic>{'tag_name': 'v1.0.0', 'draft': false},
      ]);

      final List<Map<String, dynamic>> releases = parseGitHubReleasesResponse(
        body,
      );

      expect(releases, hasLength(1));
      expect(releases.single['tag_name'], 'v1.0.0');
    });

    test('空数组返回空列表', () {
      expect(parseGitHubReleasesResponse('[]'), isEmpty);
    });

    // 同仓库里只挂资产的 release（预编译二进制 / 引擎补丁 / 模型 / rolling）不是 app
    // 版本：检查更新从不选它们，更新日志也不能列出（更不能把它标成「最新」）。
    test('只留 app 版本 release，过滤只挂资产的非版本 tag', () {
      final String body = jsonEncode(<Map<String, dynamic>>[
        <String, dynamic>{'tag_name': 'vendored-binaries', 'prerelease': true},
        <String, dynamic>{
          'tag_name': 'flutter-engine-3.47.6-hdr-output-4',
          'prerelease': true,
        },
        <String, dynamic>{'tag_name': 'v0.11.1-debug.6650+2dbaf86956'},
        <String, dynamic>{'tag_name': 'manga-ocr-kv-onnx-v1'},
        <String, dynamic>{'tag_name': 'vendor-libmpv'},
        <String, dynamic>{'tag_name': 'fushi-debug-rolling'},
        <String, dynamic>{'tag_name': 'v0.11.0', 'prerelease': false},
        <String, dynamic>{'tag_name': '1.4.2-beta', 'prerelease': true},
        <String, dynamic>{'tag_name': '2.1-preview', 'prerelease': true},
        <String, dynamic>{'name': 'no tag'},
      ]);

      expect(
        parseGitHubReleasesResponse(
          body,
        ).map((Map<String, dynamic> r) => r['tag_name']),
        <String>[
          'v0.11.1-debug.6650+2dbaf86956',
          'v0.11.0',
          '1.4.2-beta',
          '2.1-preview',
        ],
      );
    });
  });

  group('isAppVersionRelease', () {
    test('与检查更新同一判据：任一通道接纳的 release 都是 app 版本', () {
      for (final Map<String, dynamic> release in <Map<String, dynamic>>[
        <String, dynamic>{'tag_name': 'v1.2.0', 'prerelease': false},
        <String, dynamic>{'tag_name': 'v0.11.1-beta.12', 'prerelease': true},
        <String, dynamic>{
          'tag_name': 'v0.11.1-debug.6650+2dbaf86956',
          'prerelease': true,
        },
      ]) {
        final bool anyChannel = UpdateChannel.values.any(
          (UpdateChannel c) => releaseMatchesUpdateChannel(release, c),
        );
        expect(anyChannel, isTrue, reason: '${release['tag_name']}');
        expect(isAppVersionRelease(release), isTrue);
      }
    });

    test('非版本 tag 与草稿不是 app 版本，任何通道都不接纳', () {
      for (final Map<String, dynamic> release in <Map<String, dynamic>>[
        <String, dynamic>{'tag_name': 'vendored-binaries', 'prerelease': true},
        <String, dynamic>{
          'tag_name': 'flutter-engine-3.47.6-hdr-output-4',
          'prerelease': true,
        },
        <String, dynamic>{'tag_name': 'v1.3.0', 'draft': true},
        <String, dynamic>{'tag_name': 42},
      ]) {
        expect(isAppVersionRelease(release), isFalse, reason: '$release');
        for (final UpdateChannel c in UpdateChannel.values) {
          expect(releaseMatchesUpdateChannel(release, c), isFalse);
        }
      }
    });
  });
}

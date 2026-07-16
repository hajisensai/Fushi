import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/update_checker.dart';

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

      final List<Map<String, dynamic>> releases =
          parseGitHubReleasesResponse(body);

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

      final List<Map<String, dynamic>> releases =
          parseGitHubReleasesResponse(body);

      expect(releases.map((Map<String, dynamic> r) => r['tag_name']),
          <String>['v1.9.0', 'v1.8.0']);
    });

    test('顶层非数组（如错误对象）返回空列表', () {
      final String body =
          jsonEncode(<String, dynamic>{'message': 'API rate limit exceeded'});

      expect(parseGitHubReleasesResponse(body), isEmpty);
    });

    test('数组内非对象元素被剔除', () {
      final String body = jsonEncode(<dynamic>[
        'not-an-object',
        42,
        <String, dynamic>{'tag_name': 'v1.0.0', 'draft': false},
      ]);

      final List<Map<String, dynamic>> releases =
          parseGitHubReleasesResponse(body);

      expect(releases, hasLength(1));
      expect(releases.single['tag_name'], 'v1.0.0');
    });

    test('空数组返回空列表', () {
      expect(parseGitHubReleasesResponse('[]'), isEmpty);
    });
  });
}

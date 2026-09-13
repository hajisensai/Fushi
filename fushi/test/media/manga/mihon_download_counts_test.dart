import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/manga/mihon/mihon_download_counts.dart';

void main() {
  group('gitHubReleasesApiForApkUrl', () {
    test('derives the releases API from a real keiyoushi asset URL', () {
      expect(
        gitHubReleasesApiForApkUrl(
          'https://github.com/keiyoushi/extensions/releases/download/'
          '6ca40f6-0/tachiyomi-ja.rawxz-v1.4.5.apk',
        ).toString(),
        'https://api.github.com/repos/keiyoushi/extensions/releases'
        '?per_page=100',
      );
    });

    test('self-hosted repositories have no public download count', () {
      // 自建仓库把 APK 挂在自己的服务器上：没有等价 API，必须返回 null 而不是
      // 编一个 api.github.com 地址去撞 404。
      expect(
        gitHubReleasesApiForApkUrl('https://repo.example/apk/fixture.apk'),
        isNull,
      );
      // 形状像但不是 release 资产（仓库首页 / raw 文件）同样不算。
      expect(
        gitHubReleasesApiForApkUrl('https://github.com/owner/repo'),
        isNull,
      );
      expect(
        gitHubReleasesApiForApkUrl(
          'https://github.com/owner/repo/raw/repo/index.pb',
        ),
        isNull,
      );
      expect(gitHubReleasesApiForApkUrl('not a url at all ::::'), isNull);
    });
  });

  group('parseGitHubReleaseAssetCounts', () {
    test('keys by browser_download_url across releases', () {
      final String body = jsonEncode(<Object?>[
        <String, Object?>{
          'tag_name': 'b658a2c',
          'assets': <Object?>[
            <String, Object?>{
              'name': 'tachiyomi-ja.rawxz-v1.4.5.apk',
              'browser_download_url': 'https://example/rawxz.apk',
              'download_count': 1172,
            },
            <String, Object?>{
              'name': 'tachiyomi-ja.rawxz-v1.4.5.jar',
              'browser_download_url': 'https://example/rawxz.jar',
              'download_count': 96,
            },
          ],
        },
        <String, Object?>{
          'tag_name': '736ee06',
          'assets': <Object?>[
            <String, Object?>{
              'name': 'tachiyomi-ja.raw18-v1.4.1.apk',
              'browser_download_url': 'https://example/raw18.apk',
              // GitHub 返回裸数字，但别的实现（以及 protobuf-JSON 那类编码）会给
              // 字符串——两种都收，否则整份计数会因为一条而全丢。
              'download_count': '670',
            },
          ],
        },
      ]);

      expect(parseGitHubReleaseAssetCounts(body), <String, int>{
        'https://example/rawxz.apk': 1172,
        'https://example/rawxz.jar': 96,
        'https://example/raw18.apk': 670,
      });
    });

    test('a malformed entry drops only itself', () {
      final String body = jsonEncode(<Object?>[
        <String, Object?>{
          'assets': <Object?>[
            'not an object',
            <String, Object?>{'browser_download_url': 'https://example/a.apk'},
            <String, Object?>{'download_count': 5},
            <String, Object?>{
              'browser_download_url': 'https://example/good.apk',
              'download_count': 7,
            },
          ],
        },
        <String, Object?>{'assets': 'not a list'},
        'not an object either',
      ]);

      expect(parseGitHubReleaseAssetCounts(body), <String, int>{
        'https://example/good.apk': 7,
      });
    });

    test('a non-array document yields no counts', () {
      expect(
        parseGitHubReleaseAssetCounts(jsonEncode(<String, Object?>{})),
        isEmpty,
      );
    });
  });

  group('formatMihonDownloadCount', () {
    test('keeps sub-1000 counts exact', () {
      // ja 这类小语种的源普遍两三位数，压成 0.6k 会把唯一的区分度抹掉。
      expect(formatMihonDownloadCount(0), '0');
      expect(formatMihonDownloadCount(599), '599');
      expect(formatMihonDownloadCount(999), '999');
    });

    test('abbreviates thousands and millions', () {
      expect(formatMihonDownloadCount(1172), '1.2k');
      expect(formatMihonDownloadCount(12000), '12k');
      expect(formatMihonDownloadCount(1500000), '1.5M');
    });
  });

  group('MihonDownloadCountsClient', () {
    test('fetches once per repository and keys by asset URL', () async {
      final List<String> requested = <String>[];
      final MihonDownloadCountsClient client = MihonDownloadCountsClient(
        client: MockClient((http.Request request) async {
          requested.add(request.url.toString());
          return http.Response(
            jsonEncode(<Object?>[
              <String, Object?>{
                'assets': <Object?>[
                  <String, Object?>{
                    'browser_download_url':
                        'https://github.com/keiyoushi/extensions/releases/'
                            'download/tag/a.apk',
                    'download_count': 42,
                  },
                ],
              },
            ]),
            HttpStatus.ok,
          );
        }),
      );

      final MihonDownloadCounts counts = await client.fetch(<String>[
        'https://github.com/keiyoushi/extensions/releases/download/tag/a.apk',
        'https://github.com/keiyoushi/extensions/releases/download/tag/b.apk',
        // 自建仓库不产生请求。
        'https://repo.example/apk/c.apk',
      ]);

      expect(requested, <String>[
        'https://api.github.com/repos/keiyoushi/extensions/releases'
            '?per_page=100',
      ]);
      expect(
        counts.lookup(
          'https://github.com/keiyoushi/extensions/releases/download/tag/a.apk',
        ),
        42,
      );
      expect(counts.lookup('https://repo.example/apk/c.apk'), isNull);
    });

    test('a failing API degrades to no counts instead of throwing', () async {
      // 目录刷新是主链路，热度只是展示字段：GFW 机器上 api.github.com 必然超时
      // （公共 gh 镜像不代理 API），让它抛等于整个扩展列表刷不出来。
      final MihonDownloadCountsClient client = MihonDownloadCountsClient(
        client: MockClient(
          (http.Request request) async =>
              http.Response('rate limited', HttpStatus.forbidden),
        ),
      );

      final MihonDownloadCounts counts = await client.fetch(<String>[
        'https://github.com/keiyoushi/extensions/releases/download/tag/a.apk',
      ]);

      expect(counts.isEmpty, isTrue);
    });

    test('caps how many repositories one refresh may query', () async {
      // 未认证 API 是 60 次/小时/IP：用户加了十几个 GitHub 仓库时挨个查会把配额
      // 烧光，之后连默认仓库的计数都拿不到。
      final List<String> requested = <String>[];
      final MihonDownloadCountsClient client = MihonDownloadCountsClient(
        maxRepositories: 2,
        client: MockClient((http.Request request) async {
          requested.add(request.url.toString());
          return http.Response(jsonEncode(<Object?>[]), HttpStatus.ok);
        }),
      );

      await client.fetch(<String>[
        for (int index = 0; index < 5; index++)
          'https://github.com/owner$index/repo/releases/download/tag/a.apk',
      ]);

      expect(requested, hasLength(2));
    });
  });
}

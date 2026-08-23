import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/onboarding/recommended_pack.dart';
import 'package:fushi/src/utils/misc/download_plan.dart';

void main() {
  group('parseRecommendedPackManifest', () {
    test('valid manifest parses and lowercases sha256', () {
      final String sha = 'A' * 64;
      final RecommendedPackManifest? m = parseRecommendedPackManifest(
        '{"version":"2026-09-01",'
        '"url":"https://dl.wrds.xyz/fushi-recommended-2026-09-01.fushi.zip",'
        '"sha256":"$sha","size_bytes":10200000000}',
      );
      expect(m, isNotNull);
      expect(
          m!.url, 'https://dl.wrds.xyz/fushi-recommended-2026-09-01.fushi.zip');
      expect(m.version, '2026-09-01');
      expect(m.sha256, 'a' * 64);
      expect(m.sizeBytes, 10200000000);
    });

    test('url is required and must be https', () {
      expect(parseRecommendedPackManifest('{"version":"x"}'), isNull);
      expect(
        parseRecommendedPackManifest('{"url":"http://dl.wrds.xyz/a.zip"}'),
        isNull,
      );
    });

    test('bad sha256 shape rejects the whole manifest', () {
      // 长度不对 / 非 hex：与其带着一个坏校验值下 9.5 GB，不如整体回退内置直链。
      expect(
        parseRecommendedPackManifest(
            '{"url":"https://dl.wrds.xyz/a.zip","sha256":"zz"}'),
        isNull,
      );
    });

    test('optional fields tolerate absence and wrong types', () {
      final RecommendedPackManifest? m = parseRecommendedPackManifest(
          '{"url":"https://dl.wrds.xyz/a.zip","size_bytes":"big","version":3}');
      expect(m, isNotNull);
      expect(m!.sha256, isNull);
      expect(m.sizeBytes, isNull);
      expect(m.version, isNull);
    });

    test('malformed json / non-object returns null', () {
      expect(parseRecommendedPackManifest('not json'), isNull);
      expect(parseRecommendedPackManifest('[1,2,3]'), isNull);
    });

    test('mirrors / part_base_urls 只收 https，杂项被丢掉', () {
      final RecommendedPackManifest? m = parseRecommendedPackManifest(
        '{"url":"https://dl.wrds.xyz/a.zip",'
        '"mirrors":["https://m1/a.zip","http://insecure/a.zip",7],'
        '"part_base_urls":["https://gh/dl/"]}',
      );
      expect(m, isNotNull);
      expect(m!.mirrors, <String>['https://m1/a.zip']);
      expect(m.partBaseUrls, <String>['https://gh/dl/']);
      expect(m.wholeFileUrls,
          <String>['https://dl.wrds.xyz/a.zip', 'https://m1/a.zip']);
    });

    test('parts 里有一条坏记录就整表作废（半张切片表比没有更危险）', () {
      final RecommendedPackManifest? m = parseRecommendedPackManifest(
        '{"url":"https://dl.wrds.xyz/a.zip",'
        '"part_base_urls":["https://gh/dl/"],'
        '"parts":[{"name":"a.000","offset":0,"length":100},'
        '{"name":"a.001","offset":100,"length":-5}]}',
      );
      expect(m, isNotNull);
      expect(m!.parts, isEmpty);
    });

    test('切片名不得带路径分隔符（防止拼出目录穿越 URL）', () {
      final RecommendedPackManifest? m = parseRecommendedPackManifest(
        '{"url":"https://dl.wrds.xyz/a.zip",'
        '"part_base_urls":["https://gh/dl/"],'
        '"parts":[{"name":"../../evil","offset":0,"length":100}]}',
      );
      expect(m!.parts, isEmpty);
    });
  });

  group('toDownloadPlan', () {
    test('只有 size_bytes 时按 Range 模式切段，整包镜像一起挂上', () {
      final RecommendedPackManifest m = RecommendedPackManifest(
        url: 'https://dl.wrds.xyz/a.zip',
        mirrors: const <String>['https://m1/a.zip'],
        sizeBytes: 250,
        partSizeBytes: 100,
        version: 'v1',
      );
      final DownloadPlan? plan = m.toDownloadPlan();
      expect(plan, isNotNull);
      expect(plan!.parts.length, 3);
      expect(plan.version, 'v1');
      expect(plan.parts.first.sources.length, 2);
      expect(plan.parts[1].sources.first.remoteOffset, 100);
    });

    test('没有总长时返回 null（调用方去探测或走单流）', () {
      const RecommendedPackManifest m =
          RecommendedPackManifest(url: 'https://dl.wrds.xyz/a.zip');
      expect(m.toDownloadPlan(), isNull);
    });

    test('切片模式：切片 URL remoteOffset=0，整包镜像作为额外来源', () {
      final RecommendedPackManifest m = RecommendedPackManifest(
        url: 'https://dl.wrds.xyz/a.zip',
        sizeBytes: 200,
        partBaseUrls: const <String>['https://gh/dl/'],
        parts: const <RecommendedPackPart>[
          RecommendedPackPart(name: 'a.000', offset: 0, length: 100),
          RecommendedPackPart(name: 'a.001', offset: 100, length: 100),
        ],
      );
      final DownloadPlan? plan = m.toDownloadPlan();
      expect(plan, isNotNull);
      expect(plan!.parts.length, 2);
      // 切片来源在前（首选），整包来源垫底当镜像。
      expect(plan.parts[1].sources.first,
          const DownloadSource(url: 'https://gh/dl/a.001'));
      expect(
          plan.parts[1].sources.last,
          const DownloadSource(
              url: 'https://dl.wrds.xyz/a.zip', remoteOffset: 100));
    });

    test('切片总长与声明总长打架时退回 Range 模式，不拿矛盾清单下包', () {
      final RecommendedPackManifest m = RecommendedPackManifest(
        url: 'https://dl.wrds.xyz/a.zip',
        sizeBytes: 999,
        partSizeBytes: 500,
        partBaseUrls: const <String>['https://gh/dl/'],
        parts: const <RecommendedPackPart>[
          RecommendedPackPart(name: 'a.000', offset: 0, length: 100),
        ],
      );
      final DownloadPlan? plan = m.toDownloadPlan();
      expect(plan, isNotNull);
      expect(plan!.totalBytes, 999, reason: '应按声明总长走 Range，而不是按切片表');
      expect(plan.parts.first.sources.first.url, 'https://dl.wrds.xyz/a.zip');
    });

    test('tool/make_download_manifest.dart 的真实产物能被解析成计划（slice）', () {
      // 这份 JSON 逐字来自 `dart run tool/make_download_manifest.dart --mode slice`
      // 的实际输出。生成器与消费端的字段名一旦分叉，只会在生产上体现为「清单拉到了
      // 却还是单流下载」，这条往返测试把契约钉住。
      const String emitted = '''
{
  "version": "demo-1",
  "url": "https://dl.wrds.xyz/demo.fushi.zip",
  "sha256": "0c5a99b4b3ff2f25f5eeba1f85d2584bd6b314ff7eca44cc35e7492d010fa533",
  "size_bytes": 307200,
  "part_size_bytes": 102400,
  "part_base_urls": ["https://gh/dl/pack-demo"],
  "parts": [
    {"name":"demo.fushi.zip.000","offset":0,"length":102400,
     "sha256":"10a1048cb17d595dacb38c932b92afb52eb04a4eb904aa711274bce721176de7"},
    {"name":"demo.fushi.zip.001","offset":102400,"length":102400,
     "sha256":"b67a6c8e49dfd07213dd5a74f0100b63fe8db5a145219fb26de728a156f7b95f"},
    {"name":"demo.fushi.zip.002","offset":204800,"length":102400,
     "sha256":"35e379de3fdbf4ab685d42bdf671d866da5a530fa201cf0d0d7bd25316f80baf"}
  ]
}
''';
      final RecommendedPackManifest? m = parseRecommendedPackManifest(emitted);
      expect(m, isNotNull);
      final DownloadPlan? plan = m!.toDownloadPlan();
      expect(plan, isNotNull);
      expect(plan!.totalBytes, 307200);
      expect(plan.parts.length, 3);
      expect(plan.hasPerPartDigests, isTrue, reason: '切片清单带逐片摘要，才能省掉整包重读');
      expect(plan.parts.first.sources.first.url,
          'https://gh/dl/pack-demo/demo.fushi.zip.000');
    });

    test('tool/make_download_manifest.dart 的真实产物能被解析成计划（range）', () {
      const String emitted = '''
{
  "version": "demo-1",
  "url": "https://dl.wrds.xyz/demo.fushi.zip",
  "sha256": "0c5a99b4b3ff2f25f5eeba1f85d2584bd6b314ff7eca44cc35e7492d010fa533",
  "size_bytes": 307200,
  "mirrors": ["https://m1/demo.fushi.zip"],
  "part_size_bytes": 67108864
}
''';
      final RecommendedPackManifest? m = parseRecommendedPackManifest(emitted);
      final DownloadPlan? plan = m!.toDownloadPlan();
      expect(plan, isNotNull);
      // 段大小 64 MiB > 总长 → 退化成一片，但仍带上镜像。
      expect(plan!.parts.length, 1);
      expect(plan.parts.single.sources.length, 2);
      expect(plan.hasPerPartDigests, isFalse);
      expect(plan.sha256, isNotNull, reason: 'range 模式靠整包摘要兜底');
    });

    test('切片表有缝时退回 Range 模式而不是抛异常', () {
      final RecommendedPackManifest m = RecommendedPackManifest(
        url: 'https://dl.wrds.xyz/a.zip',
        sizeBytes: 200,
        partSizeBytes: 200,
        partBaseUrls: const <String>['https://gh/dl/'],
        parts: const <RecommendedPackPart>[
          RecommendedPackPart(name: 'a.000', offset: 0, length: 50),
          // 50..100 是个洞
          RecommendedPackPart(name: 'a.001', offset: 100, length: 150),
        ],
      );
      final DownloadPlan? plan = m.toDownloadPlan();
      expect(plan, isNotNull);
      expect(plan!.parts.length, 1, reason: '退回整包 Range 单段');
    });
  });
}

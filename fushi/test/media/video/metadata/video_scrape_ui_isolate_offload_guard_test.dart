import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2577 源码守卫：「按作品归类 + 刮削」导入在手机上整机冻结 / 被系统杀掉，
/// 根因是几段十万级数据的解析、建索引与打分全跑在 UI isolate 上。修复后这些
/// 不变式必须钉住，否则回归者会把同样的冻结再带回来：
///
/// 1. AniDB 标题包只能在后台 isolate 里**流式**解析（`Isolate.run` + 逐块喂给原生
///    构建器 `AniDbCatalogBuilderNative`），不得再对几十 MB 明文 `XmlDocument.parse`。
/// 2. Fribb 身份映射（十几 MB JSON）同样必须在后台 isolate 解码。
/// 3. 标题归一化 / 打分在 Rust 计算内核里：`TitleNormalizer` 只是 FFI 外壳（不得在
///    Dart 里重新长出逐字符算法或正则）；AniDB 搜索在原生索引里对已归一化的条目打分，
///    Dart 侧不再逐候选调相似度。
/// 4. 视频库页对 `videoBooks` uid 流的整页刷新必须经节流，而不是每落一条就
///    `_refresh()` + 重算待确认队列。
void main() {
  // Tests run with CWD = `fushi/`.
  const String engine = '../packages/fushi_engine/lib/media/video';
  final File catalog = File('$engine/metadata/anidb_title_catalog.dart');
  final File mapping = File('$engine/metadata/anime_identity_mapping.dart');
  final File normalizer = File('$engine/scraper/title_normalizer.dart');
  final File page = File('lib/src/pages/implementations/home_video_page.dart');

  test('guarded sources exist', () {
    for (final File file in <File>[catalog, mapping, normalizer, page]) {
      expect(file.existsSync(), isTrue, reason: file.path);
    }
  });

  group('AniDB title catalog', () {
    late String src;
    setUpAll(() => src = catalog.readAsStringSync());

    test('parses in a background isolate', () {
      expect(
        src.contains('Isolate.run('),
        isTrue,
        reason: 'BUG-2577：标题包解压/解析/建索引必须离开 UI isolate',
      );
    });

    test(
      'streams chunks into the native builder instead of a whole document',
      () {
        expect(src.contains('AniDbCatalogBuilderNative('), isTrue);
        expect(src.contains('builder.add(chunk)'), isTrue);
        expect(
          src.contains('XmlDocument.parse('),
          isFalse,
          reason: 'BUG-2577：几十 MB 标题包建整棵 DOM 是低内存机被杀的堆峰值来源',
        );
      },
    );

    test('ranks candidates inside the native index', () {
      expect(
        _compact(
          src,
        ).contains(_compact('catalog.search(normalizedQuery, limit)')),
        isTrue,
      );
      expect(
        src.contains('TitleNormalizer.similarity('),
        isFalse,
        reason: '索引条目与查询词都已归一化，不得每候选再归一化两遍',
      );
    });
  });

  test('anime identity mapping decodes JSON in a background isolate', () {
    final String src = mapping.readAsStringSync();
    expect(src.contains('Isolate.run('), isTrue);
    expect(
      src.contains('response.decodeJson('),
      isFalse,
      reason: 'BUG-2577：十几 MB JSON 不得在 UI isolate 上 jsonDecode',
    );
  });

  group('TitleNormalizer is a native shell', () {
    late String src;
    setUpAll(() => src = normalizer.readAsStringSync());

    test('delegates every entry point to fushi_compute', () {
      for (final String call in <String>[
        'TitleScoreNative.normalize(title)',
        'TitleScoreNative.tokens(normalized)',
        'TitleScoreNative.similarity(a, b)',
        'TitleScoreNative.similarityNormalized(na, nb)',
        'TitleScoreNative.similarityNormalizedBatch(query, candidates)',
      ]) {
        expect(src.contains(call), isTrue, reason: call);
      }
    });

    test('no Dart-side character algorithm or RegExp grows back', () {
      expect(src.contains('RegExp('), isFalse);
      expect(src.contains('.runes'), isFalse);
      expect(src.contains('_levenshtein'), isFalse);
    });

    test('similarityNormalized keeps its signature', () {
      expect(
        src.contains(
          'static double similarityNormalized(String na, String nb)',
        ),
        isTrue,
      );
    });
  });

  group('HomeVideoPage uid stream refresh', () {
    late String src;
    setUpAll(() => src = page.readAsStringSync());

    String bodyOf(String signature) {
      final int start = src.indexOf(signature);
      expect(start, greaterThanOrEqualTo(0), reason: '找不到 $signature');
      final int next = src.indexOf('\n  void ', start + signature.length);
      return src.substring(start, next < 0 ? src.length : next);
    }

    test('_onVideoUidsChanged is throttled instead of refreshing per row', () {
      final String body = bodyOf('void _onVideoUidsChanged(List<String> uids)');
      expect(body.contains('_videoUidsRefreshInterval'), isTrue);
      expect(
        body.contains('_refresh()'),
        isFalse,
        reason: 'BUG-2577：文件夹扫描逐条落库，每条都整页刷新会让导入期间持续卡顿',
      );
      expect(body.contains('_refreshAfterVideoUidsChanged()'), isTrue);
    });

    test('the trailing refresh timer is cancelled in dispose', () {
      expect(src.contains('_videoUidsRefreshTimer?.cancel()'), isTrue);
    });
  });
}

/// 去掉全部空白并抹掉 `dart format` 补的尾逗号（`,)` → `)`），让守卫钉语义
/// 而非排版。
String _compact(String s) =>
    s.replaceAll(RegExp(r'\s+'), '').replaceAll(',)', ')');

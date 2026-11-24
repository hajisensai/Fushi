import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// `FushiDicts.matchedLength` 只把查询串的扫描窗口交给原生：引擎结果只依赖前
/// scanLength 个码点（候选前缀 + BUG-3212 关西方言保护结构），外加窗口后的第一个码点
/// （`scan_candidates` 判断是否切在拉丁单词中间）。窗口少截一个码点就会改变匹配长度，
/// 所以这里钉住「前 scanLength + 1 个码点」。
///
/// 取代原 `japanese_match_length_cache_key_test.dart`：那份测的是已删除的 Dart 侧
/// 匹配长度缓存键（`JapaneseLanguage.matchLengthCacheKey`，只取 16 个码点、漏掉了
/// 第 17 个码点的拉丁边界判定）；缓存现在在原生句柄里，键就是原生自己截的窗口
/// （native/fushidicts/tests/tokenize_batch_test.cpp 守）。
///
/// 扫描窗口可设置（反馈 ezCjUoU2QM）：窗口、夹取、两层缓存键都随设置走，接线守卫钉住
/// 「查词请求与结果缓存键用同一个值」。真原生库上的端到端（长词头只在窗口够长时命中，
/// 查词 / 匹配长度 / 分词同口径）在 packages/fushi_dictionary/test/background_tokenize_native_test.dart。
void main() {
  const int window = FushiDicts.defaultScanLength + 1;

  test('窗口是前 defaultScanLength + 1 个码点', () {
    const String text = 'もらうためには何をすればいいのかしらと思った';
    final String w = FushiDicts.scanWindowOf(text);
    expect(w.runes.length, window);
    expect(text.startsWith(w), isTrue);
  });

  test('短于窗口的查询串原样返回', () {
    expect(FushiDicts.scanWindowOf('もらうた'), 'もらうた');
    expect(FushiDicts.scanWindowOf(''), '');
  });

  test('增补平面字按一个码点计，不在代理对中间截断', () {
    final String text = '𠮷' * 40;
    final String w = FushiDicts.scanWindowOf(text);
    expect(w.runes.length, window);
    expect(w, '𠮷' * window);
  });

  test('第 17 个码点进窗口（拉丁单词边界判定要看它）', () {
    const String head = 'もらうためには何をすればいいの';
    expect(head.runes.length, 15);
    expect(
      FushiDicts.scanWindowOf('$headかbz'),
      isNot(FushiDicts.scanWindowOf('$headかcz')),
    );
    // 第 18 个码点起引擎看不到。
    expect(
      FushiDicts.scanWindowOf('$headかaxyz'),
      FushiDicts.scanWindowOf('$headかa123'),
    );
  });

  group('扫描窗口可设置（反馈 ezCjUoU2QM）', () {
    late int Function() saved;
    setUp(() => saved = FushiDicts.scanLengthReader);
    tearDown(() => FushiDicts.scanLengthReader = saved);

    test('窗口随 scanLength 走：前 scanLength + 1 个码点', () {
      final String text = 'あ' * 40;
      expect(FushiDicts.scanWindowOf(text, scanLength: 24).runes.length, 25);
      expect(FushiDicts.scanWindowOf(text, scanLength: 8).runes.length, 9);
    });

    test('没装配的宿主读出厂值；装配后读偏好并夹到合法区间', () {
      expect(FushiDicts.defaultScanLength, 16);
      expect(
        FushiDicts.defaultScanLength,
        inInclusiveRange(FushiDicts.minScanLength, FushiDicts.maxScanLength),
      );
      FushiDicts.scanLengthReader = () => 24;
      expect(FushiDicts.scanLength, 24);
      FushiDicts.scanLengthReader = () => 1000;
      expect(FushiDicts.scanLength, FushiDicts.maxScanLength);
      FushiDicts.scanLengthReader = () => -3;
      expect(FushiDicts.scanLength, FushiDicts.minScanLength);
    });

    test('原始结果缓存键：出厂值逐字不变，其余带 /s<n>', () {
      expect(
        buildFfiLookupCacheKey(term: '図書館', maxResults: 10, scanLength: 16),
        '3:図書館/10',
      );
      expect(
        buildFfiLookupCacheKey(
          term: '図書館',
          maxResults: 10,
          scanLength: 24,
          chineseSimpToTrad: true,
        ),
        '3:図書館/10/s24/zh',
      );
    });

    test('窗口长度相同而设置不同也不撞键（S+1 个码点的串在 S 与 S+1 下窗口一样）', () {
      final String text = 'あ' * 17;
      expect(
        FushiDicts.scanWindowOf(text, scanLength: 16),
        FushiDicts.scanWindowOf(text, scanLength: 17),
      );
      expect(
        buildFfiLookupCacheKey(term: text, maxResults: 10, scanLength: 16),
        isNot(
          buildFfiLookupCacheKey(term: text, maxResults: 10, scanLength: 17),
        ),
      );
    });

    test('窗口外的余文按当前设置截：24 码点窗口内的差异进键', () {
      final String head = 'あ' * 20;
      expect(
        buildFfiLookupCacheKey(term: '$headいう', maxResults: 5, scanLength: 24),
        isNot(
          buildFfiLookupCacheKey(
            term: '$headいえ',
            maxResults: 5,
            scanLength: 24,
          ),
        ),
      );
      expect(
        buildFfiLookupCacheKey(term: '$headいう', maxResults: 5),
        buildFfiLookupCacheKey(term: '$headいえ', maxResults: 5),
        reason: '出厂窗口只到第 17 个码点',
      );
    });
  });

  group('接线守卫：查词请求与结果缓存键用同一个扫描窗口', () {
    test('app_model 两条引擎入口都把同一个 scanLength 交给请求与缓存键', () {
      final String source = File(
        'lib/src/models/app_model.dart',
      ).readAsStringSync();
      final int requests = RegExp(
        r'FushiLookupRequest\(',
      ).allMatches(source).length;
      expect(requests, 2, reason: '入口数变了就重新核对这条守卫');
      expect(
        RegExp(
          r'FushiLookupRequest\(\s*text:\s*searchTerm,\s*maxResults:\s*\w+,\s*scanLength:\s*scanLength,',
        ).allMatches(source).length,
        requests,
      );
      expect(
        RegExp(
          r'buildSearchCacheKey\([^)]*scanLength:\s*scanLength,',
        ).allMatches(source).length,
        2,
      );
      expect(
        RegExp(
          r'final int scanLength = FushiDicts\.scanLength;',
        ).allMatches(source).length,
        2,
      );
    });

    test('后台 worker 的缓存键与引擎调用都用 request.scanLength', () {
      final String worker = File(
        '../packages/fushi_dictionary/lib/src/engine/background_lookup.dart',
      ).readAsStringSync();
      expect(
        RegExp(
          r'buildFfiLookupCacheKey\(\s*term:\s*request\.text,\s*maxResults:\s*request\.maxResults,\s*scanLength:\s*request\.scanLength,',
        ).hasMatch(worker),
        isTrue,
      );
      expect(
        RegExp(
          r'_lookupWith\(\s*bindings,\s*handle,\s*request\.text,\s*maxResults:\s*request\.maxResults,\s*scanLength:\s*request\.scanLength,',
        ).hasMatch(worker),
        isTrue,
      );
    });

    test('引擎包里不再有直接把出厂常量交给原生的调用', () {
      final String engine = File(
        '../packages/fushi_dictionary/lib/src/engine/fushidicts.dart',
      ).readAsStringSync();
      // 出厂常量只允许出现在声明、默认值与 reader 里；交给原生的一律是变量。
      expect(
        RegExp(r',\s*defaultScanLength,').hasMatch(engine),
        isFalse,
        reason: '原生调用的 scan_length 实参必须读设置，不能写死出厂值',
      );
    });
  });
}

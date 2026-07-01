import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

/// BUG-270 (TODO-296 B) 守卫：锁定跨章 sanitize-HTML LRU 缓存 + 下一章预取的接线。
///
/// reader_hibiki_page.dart 太重（WebView + DB + profile providers）不便整页 mount，
/// 故缓存/预取/失效的接线用源码扫描守住；LRU 的淘汰/命中语义用一份与实现等价的
/// 纯算法行为测试覆盖（证明算法正确，源码守卫证明它被正确接到三个点）。
void main() {
  group('cross-chapter HTML cache wiring (BUG-270)', () {
    late String src;

    setUpAll(() {
      // TODO-589 batch8: _interceptRequest / _chapterHtmlBytes /
      // _putChapterHtml / _buildSanitizedChapterHtmlBytes /
      // _prefetchAdjacentChapter / _onChapterLoadComplete 已搬到
      // reader_hibiki/webview.part.dart，故改读「主壳 + 全部 part」合并语料。
      src = readReaderPageSource();
    });

    test('HTML 缓存是有界 LRU（LinkedHashMap + 容量上限）', () {
      expect(
          src.contains('LinkedHashMap<String, Uint8List> _sanitizedHtmlCache'),
          isTrue,
          reason: '跨章 HTML 缓存必须用 LinkedHashMap 维护 LRU 顺序');
      expect(src.contains('static const int _kChapterHtmlCacheLimit'), isTrue,
          reason: '缓存必须有界，防无限增长');
    });

    test('HTML 资源分支经缓存提供，而非每次原地重建', () {
      final int payloadIdx = src
          .indexOf('Future<_ReaderResourceResponse> _readerResourcePayload(');
      final int interceptIdx =
          src.indexOf('Future<WebResourceResponse?> _interceptRequest(');
      expect(payloadIdx, greaterThan(0));
      expect(interceptIdx, greaterThan(payloadIdx));
      final String payloadBody = src.substring(payloadIdx, interceptIdx);
      expect(payloadBody.contains('_chapterHtmlBytes(filePath, data)'), isTrue,
          reason: 'HTML 分支必须走 _chapterHtmlBytes（命中缓存/失效重建），'
              '不能在资源分支里内联 sanitize+inject');

      final int chapterIdx = src.indexOf('Uint8List _chapterHtmlBytes(');
      expect(chapterIdx, greaterThan(interceptIdx));
      final String interceptBody = src.substring(interceptIdx, chapterIdx);
      expect(interceptBody.contains('_readerResourcePayload(url)'), isTrue,
          reason: '_interceptRequest 必须复用共享资源分支，避免 https/custom-scheme '
              '两套路径绕过 HTML 缓存');
    });

    test('_chapterHtmlBytes 命中即把条目顶到 MRU', () {
      final int idx = src.indexOf('Uint8List _chapterHtmlBytes(');
      expect(idx, greaterThan(0));
      final int end = src.indexOf('void _putChapterHtml(');
      final String body = src.substring(idx, end);
      expect(body.contains('_sanitizedHtmlCache.remove(filePath)'), isTrue);
      expect(body.contains('_sanitizedHtmlCache[filePath] = cached'), isTrue,
          reason: '命中时移除再插入 = 顶到最近使用');
    });

    test('_putChapterHtml 超限淘汰最旧条目', () {
      final int idx = src.indexOf('void _putChapterHtml(');
      expect(idx, greaterThan(0));
      final int end = src.indexOf('Uint8List _buildSanitizedChapterHtmlBytes(');
      final String body = src.substring(idx, end);
      expect(body.contains('_kChapterHtmlCacheLimit'), isTrue);
      expect(
          body.contains(
              '_sanitizedHtmlCache.remove(_sanitizedHtmlCache.keys.first)'),
          isTrue,
          reason: '超限时淘汰 keys.first（最旧/最久未用）');
    });

    test('样式失效必须清空 HTML 缓存（styleTag 烘进缓存条目）', () {
      final int idx = src.indexOf('void _invalidateStyleCache()');
      expect(idx, greaterThan(0));
      final int end = src.indexOf('Future<void> _applyStylesLive()');
      final String body = src.substring(idx, end);
      expect(body.contains('_cachedStyleTag = null'), isTrue);
      expect(body.contains('_sanitizedHtmlCache.clear()'), isTrue,
          reason: '改字号/字体/主题后，缓存里旧 styleTag 的 HTML 必须丢弃');
    });

    test('翻章后预取下一章并去重在途读取', () {
      expect(src.contains('void _prefetchAdjacentChapter('), isTrue);
      // 预取必须挂在章节加载完成之后
      final int loadIdx = src.indexOf('Future<void> _onChapterLoadComplete(');
      expect(loadIdx, greaterThan(0));
      // _onChapterLoadComplete 是 webview part 的最后一个方法（合并语料末尾），
      // _invalidateFavoriteSentenceCache 仍在主壳（更早），故切到语料尾部。
      final String loadBody = src.substring(loadIdx);
      expect(loadBody.contains('_prefetchAdjacentChapter(chapterSnapshot + 1)'),
          isTrue,
          reason: '加载完一章后预取下一章（前进翻章方向）');

      final int prefIdx = src.indexOf('void _prefetchAdjacentChapter(');
      // _prefetchAdjacentChapter 之后在 part 内紧跟 static _isValidFontData。
      final int prefEnd = src.indexOf('static bool _isValidFontData(', prefIdx);
      expect(prefEnd, greaterThan(prefIdx));
      final String prefBody = src.substring(prefIdx, prefEnd);
      expect(prefBody.contains('_prefetchingHtmlPath'), isTrue,
          reason: '在途预取要去重，避免与落地导航重复读盘');
      expect(prefBody.contains('_sanitizedHtmlCache.containsKey(filePath)'),
          isTrue,
          reason: '已缓存就跳过预取');
      expect(prefBody.contains('scheduleMicrotask'), isTrue,
          reason: '预取走后台，不阻塞当前帧');
    });
  });

  // ── LRU 算法行为测试（与 _putChapterHtml/_chapterHtmlBytes 等价的纯实现） ──
  group('LRU eviction/hit semantics (mirror of impl)', () {
    const int limit = 3;
    late LinkedHashMap<String, Uint8List> cache;

    Uint8List bytes(String s) => Uint8List.fromList(s.codeUnits);

    void put(String key, Uint8List value) {
      cache.remove(key);
      cache[key] = value;
      while (cache.length > limit) {
        cache.remove(cache.keys.first);
      }
    }

    Uint8List? getBump(String key) {
      final Uint8List? hit = cache.remove(key);
      if (hit != null) {
        cache[key] = hit;
      }
      return hit;
    }

    setUp(() {
      cache = LinkedHashMap<String, Uint8List>();
    });

    test('evicts least-recently-used when over limit', () {
      put('a', bytes('a'));
      put('b', bytes('b'));
      put('c', bytes('c'));
      put('d', bytes('d')); // over limit -> evicts 'a'
      expect(cache.keys.toList(), <String>['b', 'c', 'd']);
      expect(cache.containsKey('a'), isFalse);
    });

    test('a hit bumps the key so it survives the next eviction', () {
      put('a', bytes('a'));
      put('b', bytes('b'));
      put('c', bytes('c'));
      // touch 'a' -> now MRU; 'b' becomes LRU.
      expect(getBump('a'), isNotNull);
      put('d', bytes('d')); // evicts 'b', not 'a'
      expect(cache.containsKey('a'), isTrue);
      expect(cache.containsKey('b'), isFalse);
      expect(cache.keys.toList(), <String>['c', 'a', 'd']);
    });

    test('re-put of existing key refreshes value and order', () {
      put('a', bytes('a1'));
      put('b', bytes('b'));
      put('a', bytes('a2')); // overwrite + move to MRU
      expect(String.fromCharCodes(cache['a']!), 'a2');
      expect(cache.keys.toList(), <String>['b', 'a']);
    });
  });
}

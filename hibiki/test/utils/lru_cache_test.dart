// LruCache 字节封顶扩展的单测（TODO：查词缓存按条数封顶导致长会话几百 MB
// 常驻）。覆盖三块：
// 1. 纯条数模式零行为变化（既有调用点兜底回归）；
// 2. 字节模式：totalBytes 记账、LRU 淘汰顺序、maxBytes 触发、超大单条、
//    条数兜底、clear 归零；
// 3. 运行期调整 maxBytes（低内存模式切换）立即淘汰。
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/lru_cache.dart';

void main() {
  group('LruCache count-only mode (legacy behavior unchanged)', () {
    test('evicts least recently used beyond maxSize', () {
      final LruCache<String, int> cache = LruCache<String, int>(2);
      cache['a'] = 1;
      cache['b'] = 2;
      cache['c'] = 3;
      expect(cache['a'], isNull);
      expect(cache['b'], 2);
      expect(cache['c'], 3);
      expect(cache.length, 2);
    });

    test('get refreshes recency', () {
      final LruCache<String, int> cache = LruCache<String, int>(2);
      cache['a'] = 1;
      cache['b'] = 2;
      expect(cache['a'], 1); // a 变最新。
      cache['c'] = 3; // 淘汰 b。
      expect(cache['a'], 1);
      expect(cache['b'], isNull);
      expect(cache['c'], 3);
    });

    test('overwrite refreshes recency without growing length', () {
      final LruCache<String, int> cache = LruCache<String, int>(2);
      cache['a'] = 1;
      cache['b'] = 2;
      cache['a'] = 10; // 覆盖，a 变最新。
      expect(cache.length, 2);
      cache['c'] = 3; // 淘汰 b。
      expect(cache['a'], 10);
      expect(cache['b'], isNull);
    });

    test('putIfAbsent returns existing without invoking builder', () {
      final LruCache<String, int> cache = LruCache<String, int>(2);
      cache['a'] = 1;
      int builds = 0;
      final int got = cache.putIfAbsent('a', () {
        builds++;
        return 99;
      });
      expect(got, 1);
      expect(builds, 0);
      expect(cache.putIfAbsent('b', () => 2), 2);
      expect(cache['b'], 2);
    });

    test('totalBytes stays 0 and maxBytes is null', () {
      final LruCache<String, String> cache = LruCache<String, String>(4);
      cache['a'] = 'x' * 1000;
      expect(cache.totalBytes, 0);
      expect(cache.maxBytes, isNull);
    });

    test('clear empties the cache', () {
      final LruCache<String, int> cache = LruCache<String, int>(4);
      cache['a'] = 1;
      cache.clear();
      expect(cache.length, 0);
      expect(cache['a'], isNull);
    });
  });

  group('LruCache byte-capped mode', () {
    LruCache<String, String> byteCache(int maxBytes, {int maxSize = 100}) {
      return LruCache<String, String>(
        maxSize,
        maxBytes: maxBytes,
        sizeOf: (String v) => v.length,
      );
    }

    test('constructor asserts maxBytes and sizeOf come as a pair', () {
      expect(
        () => LruCache<String, String>(10, maxBytes: 100),
        throwsAssertionError,
      );
      expect(
        () => LruCache<String, String>(10, sizeOf: (String v) => v.length),
        throwsAssertionError,
      );
    });

    test('accumulates totalBytes on put; overwrite replaces the old size', () {
      final LruCache<String, String> cache = byteCache(100);
      cache['a'] = 'xxxx'; // 4
      cache['b'] = 'yyy'; // 3
      expect(cache.totalBytes, 7);
      cache['a'] = 'z'; // 覆盖：4 → 1。
      expect(cache.totalBytes, 4);
      expect(cache.length, 2);
    });

    test('evicts LRU-first when totalBytes exceeds maxBytes', () {
      final LruCache<String, String> cache = byteCache(10);
      cache['a'] = 'aaaa'; // 4
      cache['b'] = 'bbbb'; // 8
      cache['c'] = 'cccc'; // 12 > 10 → 淘汰 a。
      expect(cache['a'], isNull);
      expect(cache['b'], 'bbbb');
      expect(cache['c'], 'cccc');
      expect(cache.totalBytes, 8);
    });

    test('get refreshes recency for byte eviction order', () {
      final LruCache<String, String> cache = byteCache(10);
      cache['a'] = 'aaaa';
      cache['b'] = 'bbbb';
      expect(cache['a'], 'aaaa'); // a 变最新。
      cache['c'] = 'cccc'; // 超预算 → 淘汰 b（最旧）。
      expect(cache['a'], 'aaaa');
      expect(cache['b'], isNull);
      expect(cache.totalBytes, 8);
    });

    test('a single entry larger than maxBytes never stays resident', () {
      final LruCache<String, String> cache = byteCache(10);
      cache['a'] = 'aaaa';
      cache['big'] = 'x' * 11; // 单条 11 > 10：全部淘汰（含自身）。
      expect(cache['a'], isNull);
      expect(cache['big'], isNull);
      expect(cache.length, 0);
      expect(cache.totalBytes, 0);
    });

    test('count cap still applies as a fallback', () {
      final LruCache<String, String> cache = byteCache(1000, maxSize: 2);
      cache['a'] = 'a';
      cache['b'] = 'b';
      cache['c'] = 'c'; // 字节远未满，条数 2 兜底 → 淘汰 a。
      expect(cache['a'], isNull);
      expect(cache.length, 2);
      expect(cache.totalBytes, 2);
    });

    test('clear resets totalBytes', () {
      final LruCache<String, String> cache = byteCache(100);
      cache['a'] = 'aaaa';
      cache.clear();
      expect(cache.length, 0);
      expect(cache.totalBytes, 0);
      // clear 后继续可用且记账正确。
      cache['b'] = 'bb';
      expect(cache.totalBytes, 2);
    });

    test('shrinking maxBytes at runtime evicts immediately', () {
      final LruCache<String, String> cache = byteCache(100);
      cache['a'] = 'a' * 40;
      cache['b'] = 'b' * 40;
      expect(cache.totalBytes, 80);
      cache.maxBytes = 50; // 低内存模式收紧 → 淘汰最旧的 a。
      expect(cache.maxBytes, 50);
      expect(cache['a'], isNull);
      expect(cache['b'], isNotNull);
      expect(cache.totalBytes, 40);
    });

    test('setting maxBytes to null disables the byte cap', () {
      final LruCache<String, String> cache = byteCache(10);
      cache.maxBytes = null;
      cache['a'] = 'x' * 50;
      cache['b'] = 'y' * 50;
      expect(cache.length, 2);
      expect(cache.totalBytes, 100); // 记账仍在，仅不再淘汰。
    });

    test('putIfAbsent tracks bytes for the inserted value', () {
      final LruCache<String, String> cache = byteCache(100);
      cache.putIfAbsent('a', () => 'aaaa');
      expect(cache.totalBytes, 4);
      cache.putIfAbsent('a', () => 'zzzzzzzz'); // 已存在，不重插。
      expect(cache.totalBytes, 4);
    });
  });
}

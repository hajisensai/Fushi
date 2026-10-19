import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// `FushiDicts.matchedLength` 只把查询串的扫描窗口交给原生：引擎结果只依赖前
/// [FushiDicts.defaultScanLength] 个码点（候选前缀 + BUG-3212 关西方言保护结构），
/// 外加窗口后的第一个码点（`scan_candidates` 判断是否切在拉丁单词中间）。窗口少截
/// 一个码点就会改变匹配长度，所以这里钉住「前 defaultScanLength + 1 个码点」。
///
/// 取代原 `japanese_match_length_cache_key_test.dart`：那份测的是已删除的 Dart 侧
/// 匹配长度缓存键（`JapaneseLanguage.matchLengthCacheKey`，只取 16 个码点、漏掉了
/// 第 17 个码点的拉丁边界判定）；缓存现在在原生句柄里，键就是原生自己截的窗口
/// （native/fushidicts/tests/tokenize_batch_test.cpp 守）。
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
}

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// BUG-3212：`JapaneseLanguage` 的匹配长度缓存键必须盖住引擎结果依赖的全部文本。
///
/// 引擎只看查询串前 [FushiDicts.defaultScanLength] 个码点（候选前缀 + 关西方言
/// 保护结构判定都在这个扫描窗口内），所以键取的就是这段码点；旧键是前 20 个
/// UTF-16 单元，窗口里每多一个增补平面字就少盖一个码点。
void main() {
  test('键恰好是扫描窗口：前 defaultScanLength 个码点', () {
    const String text = 'もらうためには何をすればいいのかしらと思った';
    final String key = JapaneseLanguage.matchLengthCacheKey(text);
    expect(key.runes.length, FushiDicts.defaultScanLength);
    expect(text.startsWith(key), isTrue);
  });

  test('短于窗口的查询串原样作键', () {
    expect(JapaneseLanguage.matchLengthCacheKey('もらうた'), 'もらうた');
    expect(JapaneseLanguage.matchLengthCacheKey(''), '');
  });

  test('增补平面字按一个码点计，键仍盖满整个窗口', () {
    // 每个 𠮷 占两个 UTF-16 单元。旧键（前 20 个单元）只盖住 10 个码点。
    final String text = '𠮷' * 20;
    final String key = JapaneseLanguage.matchLengthCacheKey(text);
    expect(key.runes.length, FushiDicts.defaultScanLength);
    expect(key, '𠮷' * FushiDicts.defaultScanLength);
  });

  test('只在窗口外不同的两段文本共享键，窗口内不同则不共享', () {
    const String head = 'もらうためには何をすればいいの';
    expect(head.runes.length, 15);
    // 第 16 个码点（窗口最后一个）不同 → 键不同。
    expect(
      JapaneseLanguage.matchLengthCacheKey('$headか。'),
      isNot(JapaneseLanguage.matchLengthCacheKey('$headだ。')),
    );
    // 第 17 个码点起不同 → 引擎看不到，键相同。
    expect(
      JapaneseLanguage.matchLengthCacheKey('$headかしら'),
      JapaneseLanguage.matchLengthCacheKey('$headかもね'),
    );
  });
}

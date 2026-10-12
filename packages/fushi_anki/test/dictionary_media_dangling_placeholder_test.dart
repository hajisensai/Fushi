import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// BUG-3270 守卫：制卡时某条词典媒体（明鏡的外字 SVG 等）没存进 Anki，卡片里不得
/// 残留指向它的 `fushi_dict_<序号>.<ext>` 占位符。
///
/// 用户截图：AnkiDroid 复习界面每次弹「卡片内容错误：加载「fushi_dict_4.svg」失败」。
/// 根因：[AnkiNoteComposer.buildDictionaryMediaTags] 对存储失败的条目不登记映射，
/// `buildMinedFields` 于是不替换它，`<img src="fushi_dict_4.svg">` 原样写进字段；
/// BUG-1265 宣称的「降级成 alt 文本」从未实现，测试还把残留占位符锁成了预期。
void main() {
  /// popup.js 真实导出的外字形状（Yomitan 同形：`<a href>` 包 `<img src alt>`）。
  String exported(String filename, {String alt = '3分の2'}) =>
      '<span data-sc-img="" data-sc-class="gaiji">'
      '<a target="_blank" rel="noreferrer noopener" href="$filename" '
      'style="display:inline-block;">'
      '<span style="display:inline-block;font-size:1em;">'
      '<img alt="$alt" src="$filename" style="display:inline-block;">'
      '</span></a></span>';

  String degrade(String html) =>
      AnkiNoteComposer.degradeUnresolvedDictionaryMedia(html);

  test('残留占位符：<img> 换成 alt 文本，<a> 的 href 被摘掉', () {
    final String out = degrade('前${exported('fushi_dict_4.svg')}後');

    expect(
      out,
      isNot(contains('fushi_dict_4.svg')),
      reason: '任何指向未存入媒体的引用都会让 AnkiDroid 报加载失败',
    );
    expect(out, isNot(contains('<img')));
    expect(out, contains('3分の2'), reason: '降级必须保留 alt 文本，读者仍能看懂');
    expect(
      out,
      contains(
        '<a target="_blank" rel="noreferrer noopener" '
        'style="display:inline-block;">',
      ),
    );
    expect(out, startsWith('前'));
    expect(out, endsWith('後'));
  });

  test('已替换成 sha1 缓存名的媒体原样保留（与占位符序号形态不相交）', () {
    final String stored = ankiDictionaryMediaCacheFilename(
      '明鏡国語辞典 第三版',
      'gaiji/a.svg',
    );
    final String html = exported(stored);
    expect(degrade(html), html);
  });

  test('混排：只降级残留的那条，邻居不受影响', () {
    final String stored = ankiDictionaryMediaCacheFilename('d', 'x.svg');
    final String out = degrade(
      exported(stored) + exported('fushi_dict_1.svg', alt: '参照'),
    );
    expect(out, contains('src="$stored"'));
    expect(out, contains('href="$stored"'));
    expect(out, isNot(contains('fushi_dict_1.svg')));
    expect(out, contains('参照'));
  });

  test('alt 里的尖括号挪进文本节点前被转义，不会被当成标签', () {
    final String out = degrade(exported('fushi_dict_0.svg', alt: '<b>x</b>'));
    expect(out, contains('&lt;b&gt;x&lt;/b&gt;'));
    expect(out, isNot(contains('<b>')));
  });

  test('无 alt 的占位图降级为空，不留悬空引用', () {
    const String html = '<img class="gloss-image" src="fushi_dict_0.svg">意味';
    expect(degrade(html), '意味');
  });

  test('不含占位符的字段原样返回', () {
    const String html = '<div class="yomitan-glossary">定义</div>';
    expect(degrade(html), html);
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/epub/epub_book.dart';
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart';
import 'package:fushi/src/reader/ttu_toc_flatten.dart';

/// BUG-2383：目录条目的 `#fragment`（章内锚）此前在压平时被丢掉，于是「一个 xhtml
/// 装整卷、目录靠锚点分节」的书里，同一章下的每一条目录项都只跳到章首。
void main() {
  group('tocHrefFragment', () {
    test('extracts the anchor, decoded like resolveInternalLink does', () {
      expect(tocHrefFragment('ch1.xhtml#sec3'), 'sec3');
      // resolveInternalLink 走 Uri.fragment（percent 已解码）；两条路径最终都喂
      // getElementById，口径必须一致。
      expect(tocHrefFragment('ch1.xhtml#%E7%AC%AC%E4%B8%80%E7%AB%A0'), '第一章');
    });

    test('returns null when there is no usable anchor', () {
      expect(tocHrefFragment(null), isNull);
      expect(tocHrefFragment('ch1.xhtml'), isNull);
      expect(tocHrefFragment('ch1.xhtml#'), isNull);
    });

    test('degrades to the raw value on malformed percent escapes', () {
      // href 是不可信输入：坏转义不得让整条目录项消失。
      expect(tocHrefFragment('ch1.xhtml#bad%zz'), 'bad%zz');
    });
  });

  test('flatten keeps a distinct anchor for each entry of the same chapter',
      () {
    // 同一 spine 章的三条目录项：index 全相同，只有 fragment 能区分。
    final List<EpubTocItem> toc = <EpubTocItem>[
      EpubTocItem(label: '巻頭', href: 'vol1.xhtml'),
      EpubTocItem(label: '第一節', href: 'vol1.xhtml#sec1'),
      EpubTocItem(label: '第二節', href: 'vol1.xhtml#sec2'),
    ];
    final List<TtuTocEntry> flat = flattenTtuTocEntries(toc, (String? _) => 0);
    expect(flat.map((TtuTocEntry e) => e.index), <int>[0, 0, 0]);
    expect(
      flat.map((TtuTocEntry e) => e.fragment),
      <String?>[null, 'sec1', 'sec2'],
      reason: '丢掉 fragment 就等于三条目录项全跳章首',
    );
  });

  test('toc taps and internal links land through the same anchor entry point',
      () {
    final String nav =
        File('lib/src/pages/implementations/reader_fushi/navigation.part.dart')
            .readAsStringSync();
    final String chrome =
        File('lib/src/pages/implementations/reader_fushi/chrome.part.dart')
            .readAsStringSync();
    final String sheet =
        File('lib/src/media/audiobook/reader_quick_settings_sheet.dart')
            .readAsStringSync();

    expect(nav, contains('Future<void> _jumpToChapterAnchor('));
    // 内链处理器复用同一个落地口——两条路径不得再各写一份同章/跨章判断。
    expect(
        nav,
        contains(
            'await _jumpToChapterAnchor(link.chapterIndex, link.fragment);'));
    expect(chrome, contains('await _jumpToChapterAnchor(index, fragment);'));
    expect(sheet, contains('toc[i].fragment,'),
        reason: '目录行必须把自己的锚点交给跳转，否则修复只是半条');
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/display_title.dart';
import 'package:fushi/src/media/display_title_hash_suffix.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/sources/manga_fushi_source.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';

/// BUG-4898：书 / 漫画显示名去掉文件名标题末尾的 `[8 位十六进制]` 哈希后缀。
///
/// 纯函数 [stripTitleHashSuffix] 的边界 + 书族显示出口（`ReaderMediaSource
/// .getDisplayTitleFromMediaItem` / [displayTitleForBook]）真的调用了它，且
/// override（用户改过的名）不被清洗、身份原名（`item.title`）不被改写。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('stripTitleHashSuffix', () {
    test('去掉末尾的 [8 位小写十六进制] 及其前面的空白', () {
      expect(
        stripTitleHashSuffix('十歳の最強魔導師 第16話 前編 [679fb7c9]'),
        '十歳の最強魔導師 第16話 前編',
      );
      expect(
        stripTitleHashSuffix('魔性のメロ女に堕とされる百合アンソロジー [d2dcc001]'),
        '魔性のメロ女に堕とされる百合アンソロジー',
      );
      expect(stripTitleHashSuffix('Title[0123abcd]'), 'Title');
      expect(stripTitleHashSuffix('Title [0123abcd]  '), 'Title');
    });

    test('没有哈希后缀原样返回', () {
      expect(stripTitleHashSuffix('超かぐやメシ！'), '超かぐやメシ！');
      expect(stripTitleHashSuffix(''), '');
    });

    test('不是恰好 8 位十六进制、或不在末尾的标签都不动', () {
      // 7 位 / 9 位。
      expect(stripTitleHashSuffix('Title [679fb7c]'), 'Title [679fb7c]');
      expect(stripTitleHashSuffix('Title [679fb7c90]'), 'Title [679fb7c90]');
      // 非十六进制字符。
      expect(stripTitleHashSuffix('Title [679fb7cz]'), 'Title [679fb7cz]');
      // 年份 / 卷号。
      expect(stripTitleHashSuffix('Title [2024]'), 'Title [2024]');
      expect(stripTitleHashSuffix('Title [上]'), 'Title [上]');
      // 哈希在中段：不是后缀。
      expect(
        stripTitleHashSuffix('Title [679fb7c9] 第2巻'),
        'Title [679fb7c9] 第2巻',
      );
      // 出版社标签不是 CRC。
      expect(stripTitleHashSuffix('Title (電撃文庫)'), 'Title (電撃文庫)');
    });

    test('全媒体共用判据：大写、圆括号、连续多段、残留扩展名都去掉', () {
      expect(stripTitleHashSuffix('Title [679FB7C9]'), 'Title');
      expect(stripTitleHashSuffix('Title (679fb7c9)'), 'Title');
      expect(stripTitleHashSuffix('A [11111111] [22222222]'), 'A');
      expect(stripTitleHashSuffix('A [69c3d7b2].epub'), 'A');
    });

    test('整个标题只有哈希时原样返回（不显示空标题）', () {
      expect(stripTitleHashSuffix('[679fb7c9]'), '[679fb7c9]');
      expect(stripTitleHashSuffix('  [679fb7c9]'), '  [679fb7c9]');
    });
  });

  group('书族显示出口', () {
    final ReaderFushiSource source = ReaderFushiSource.instance;

    MediaItem itemFor(String mediaIdentifier, String title) => MediaItem(
      mediaIdentifier: mediaIdentifier,
      title: title,
      mediaTypeIdentifier: source.mediaType.uniqueKey,
      mediaSourceIdentifier: source.uniqueKey,
      position: 0,
      duration: 1,
      canDelete: false,
      canEdit: true,
    );

    Future<void> setOverride(String mediaIdentifier, String? title) =>
        source.setOverrideTitleFromMediaItem(
          item: itemFor(mediaIdentifier, ''),
          title: title,
        );

    test('getDisplayTitleFromMediaItem：无 override 去哈希，item.title 不变', () {
      const String bookKey = 'hash_suffix_book_a';
      final MediaItem item = itemFor(
        ReaderFushiSource.mediaIdentifierFor(bookKey),
        '十歳の最強魔導師 第16話 前編 [679fb7c9]',
      );
      expect(source.getDisplayTitleFromMediaItem(item), '十歳の最強魔導師 第16話 前編');
      // 漫画源与 EPUB 源同一个书族出口。
      expect(
        MangaFushiSource.instance.getDisplayTitleFromMediaItem(item),
        '十歳の最強魔導師 第16話 前編',
      );
      // 只改显示：身份原名原样保留。
      expect(item.title, '十歳の最強魔導師 第16話 前編 [679fb7c9]');
    });

    test('用户改过的显示名原样显示，不清洗', () async {
      const String bookKey = 'hash_suffix_book_b';
      final String id = ReaderFushiSource.mediaIdentifierFor(bookKey);
      addTearDown(() => setOverride(id, null));
      await setOverride(id, '我起的名 [0123abcd]');

      expect(
        source.getDisplayTitleFromMediaItem(itemFor(id, 'raw [679fb7c9]')),
        '我起的名 [0123abcd]',
      );
      expect(
        displayTitleForBook(bookKey: bookKey, rawTitle: 'raw [679fb7c9]'),
        '我起的名 [0123abcd]',
      );
    });

    test('displayTitleForBook 三条通道的原名回退都去哈希', () {
      expect(
        displayTitleForBook(
          bookKey: 'hash_suffix_book_c',
          rawTitle: '魔法少女 [d2dcc001]',
        ),
        '魔法少女',
      );
      expect(
        displayTitleForBook(
          srtUid: 'hash_suffix_srt_c',
          rawTitle: '字幕书 [d2dcc001]',
        ),
        '字幕书',
      );
      expect(displayTitleForBook(rawTitle: '无身份 [d2dcc001]'), '无身份');
      expect(
        displayTitleForBook(
          item: itemFor(
            ReaderFushiSource.mediaIdentifierFor('hash_suffix_book_d'),
            '整件 [d2dcc001]',
          ),
          rawTitle: 'unused',
        ),
        '整件',
      );
    });
  });
}

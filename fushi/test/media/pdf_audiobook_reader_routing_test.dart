import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/sources/manga_fushi_source.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/media/sources/reader_pdf_source.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/source_guard.dart';

/// BUG-4333 / 反馈 Ndnxy3mNdG：PDF 书挂上有声书后，书架只剩一张写死 EPUB 阅读器的
/// SRT 卡，打开是有声书工具栏 + 白屏正文。
///
/// 三处一起钉：
/// 1. SRT 卡的阅读器由配对书的 format 经唯一派生点现算（不写死 EPUB 源）；
/// 2. 「导入有声书」入口与 ctl 挂音频拒绝分支共用 [BookFormat.supportsAudiobook]；
/// 3. 「有声书配对行顶替原书卡」只对能挂有声书的格式成立，存量 PDF 卡不再被藏。
void main() {
  MediaItem bookCard(BookFormat format) => MediaItem(
    mediaIdentifier: ReaderFushiSource.mediaIdentifierFor('k_${format.name}'),
    title: format.name,
    mediaTypeIdentifier: 'reader_media_type',
    mediaSourceIdentifier: ReaderFushiSource.mediaSourceKeyFor(format),
    position: 0,
    duration: 1,
    canDelete: false,
    canEdit: true,
  );

  SrtBook srt(String bookKey) => SrtBook()
    ..uid = 'srtbook_epub_$bookKey'
    ..title = 'Audiobook'
    ..srtPath = 'C:/a.srt'
    ..audioPaths = <String>['C:/a.m4b']
    ..importedAt = 1
    ..bookKey = bookKey;

  group('能否挂有声书：唯一判据 BookFormat.supportsAudiobook', () {
    test('只有 EPUB 能挂有声书，PDF / 漫画不能', () {
      expect(BookFormat.epub.supportsAudiobook, isTrue);
      expect(BookFormat.pdf.supportsAudiobook, isFalse);
      expect(BookFormat.manga.supportsAudiobook, isFalse);
    });

    test('formatForMediaSourceKey 是 mediaSourceKeyFor 的逆，非书类源为 null', () {
      for (final BookFormat format in BookFormat.values) {
        expect(
          ReaderFushiSource.formatForMediaSourceKey(
            ReaderFushiSource.mediaSourceKeyFor(format),
          ),
          format,
        );
      }
      expect(ReaderFushiSource.formatForMediaSourceKey('video_source'), isNull);
    });

    test('书卡菜单判据：EPUB 卡出「导入有声书」，PDF / 漫画卡不出', () {
      expect(
        ReaderFushiSource.mediaItemSupportsAudiobook(bookCard(BookFormat.epub)),
        isTrue,
      );
      expect(
        ReaderFushiSource.mediaItemSupportsAudiobook(bookCard(BookFormat.pdf)),
        isFalse,
        reason: 'PDF 阅读器不播有声书，PDF 卡不得露出「导入有声书」',
      );
      expect(
        ReaderFushiSource.mediaItemSupportsAudiobook(
          bookCard(BookFormat.manga),
        ),
        isFalse,
      );
    });
  });

  group('SRT 卡按配对书 format 派生阅读器', () {
    final Map<String, BookFormat> formats = <String, BookFormat>{
      'k_pdf': BookFormat.pdf,
      'k_epub': BookFormat.epub,
      'k_manga': BookFormat.manga,
    };
    BookFormat? formatOf(String key) => formats[key];

    test('PDF 配对行打开 PDF 阅读器，不再落进 EPUB 阅读器', () {
      expect(
        srtBookMediaSourceKey(srt('k_pdf'), formatOf: formatOf),
        ReaderPdfSource.kUniqueKey,
      );
      expect(
        srtBookMediaSourceKey(srt('k_pdf'), formatOf: formatOf),
        isNot(ReaderFushiSource.instance.uniqueKey),
      );
    });

    test('漫画配对行打开漫画阅读器', () {
      expect(
        srtBookMediaSourceKey(srt('k_manga'), formatOf: formatOf),
        MangaFushiSource.kUniqueKey,
      );
    });

    test('EPUB 配对行 / 书架无配对行 / standalone 字幕书仍走 EPUB 阅读器', () {
      expect(
        srtBookMediaSourceKey(srt('k_epub'), formatOf: formatOf),
        ReaderFushiSource.instance.uniqueKey,
      );
      expect(
        srtBookMediaSourceKey(srt('k_missing'), formatOf: formatOf),
        ReaderFushiSource.instance.uniqueKey,
      );
      expect(
        srtBookMediaSourceKey(srt(''), formatOf: (String _) => BookFormat.pdf),
        ReaderFushiSource.instance.uniqueKey,
        reason: 'standalone 字幕书（bookKey 空串）的正文是生成的 EPUB',
      );
    });
  });

  test('BUG-728 顶替规则只对能挂有声书的格式成立：存量 PDF / 漫画原卡不再被藏', () {
    final Map<String, BookFormat> formats = <String, BookFormat>{
      'k_pdf': BookFormat.pdf,
      'k_epub': BookFormat.epub,
      'k_manga': BookFormat.manga,
    };
    final Set<String> shadowed = ReaderFushiSource.audiobookShadowedBookKeys(
      <SrtBook>[
        srt('k_pdf'),
        srt('k_epub'),
        srt('k_manga'),
        srt('k_missing'),
        srt(''),
      ],
      formatOf: (String key) => formats[key],
    );
    expect(shadowed, <String>{'k_epub', 'k_missing'});
  });

  test('源码守卫：入口与派生都走共享函数，不再写死 EPUB 源 / 各写一份判据', () {
    String code(String path) =>
        compactCode(maskComments(File(path).readAsStringSync()));
    final String books = code(
      'lib/src/pages/implementations/reader_history/books.part.dart',
    );
    final String shelf = code(
      'lib/src/pages/implementations/reader_fushi_history_page.dart',
    );
    final String ctl = code('lib/src/ops/ctl_audiobook_routes.dart');
    final String companion = code(
      'lib/src/second_screen/companion/companion_library_app_data.dart',
    );

    expect(
      books.contains(
        compactCode(
          'mediaSourceIdentifier: ReaderFushiSource.instance.uniqueKey',
        ),
      ),
      isFalse,
      reason: 'SRT 卡不得写死 EPUB 阅读器（反馈 Ndnxy3mNdG）',
    );
    expect(
      books.contains(compactCode('mediaSource: ReaderFushiSource.instance,')),
      isFalse,
      reason: '_openSrtBook 按卡上派生的源打开，不写死 ReaderFushiSource',
    );
    expect(
      shelf.contains(
        compactCode('ReaderFushiSource.mediaItemSupportsAudiobook(item)'),
      ),
      isTrue,
      reason: '书卡「导入有声书」入口按共享判据门控',
    );
    expect(
      shelf.contains(
        compactCode('ReaderFushiSource.audiobookShadowedBookKeys('),
      ),
      isTrue,
      reason: '书架隐藏规则走共享函数',
    );
    expect(
      ctl.contains(compactCode('!= BookFormat.epub')),
      isFalse,
      reason: 'ctl 挂音频拒绝分支不得另写一份 format 判据',
    );
    expect(
      'supportsAudiobook'.allMatches(ctl).length,
      greaterThanOrEqualTo(2),
      reason: 'ctl 两处挂音频拒绝分支都用 BookFormat.supportsAudiobook',
    );
    expect(
      companion.contains(
        compactCode('mediaSource: audiobook ? ReaderFushiSource.instance'),
      ),
      isFalse,
      reason: '副屏打开有声书同样按书卡派生的源，不写死 EPUB 源',
    );
  });
}

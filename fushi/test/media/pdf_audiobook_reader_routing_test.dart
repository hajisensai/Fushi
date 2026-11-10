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

/// BUG-4345 / 反馈 Ndnxy3mNdG：PDF 书挂上有声书后，书架只剩一张写死 EPUB 阅读器的
/// SRT 卡，打开是有声书工具栏 + 白屏正文。
///
/// 拍板项 pdf-audiobook-support（PR #3162 取舍 a）之后 PDF 阅读器正式接有声书
/// （播放 + 文本层字幕高亮），PDF 重新能挂有声书。一起钉：
/// 1. SRT 卡的阅读器由配对书的 format 经唯一派生点现算（PDF 配对行开 PDF 阅读器）；
/// 2. 「导入有声书」入口与 ctl 挂音频拒绝分支共用 [BookFormat.supportsAudiobook]
///    （EPUB / PDF）；「有声书工作室」只认 EPUB（[BookFormat.supportsAudiobookStudio]）；
/// 3. 「有声书配对行顶替原书卡」只对能挂有声书的格式成立（漫画原卡不被藏）。
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
    test('EPUB / PDF 能挂有声书，漫画不能；工作室只认 EPUB', () {
      expect(BookFormat.epub.supportsAudiobook, isTrue);
      expect(BookFormat.pdf.supportsAudiobook, isTrue);
      expect(BookFormat.manga.supportsAudiobook, isFalse);
      expect(BookFormat.epub.supportsAudiobookStudio, isTrue);
      expect(BookFormat.pdf.supportsAudiobookStudio, isFalse);
      expect(BookFormat.manga.supportsAudiobookStudio, isFalse);
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

    test('书卡菜单判据：EPUB / PDF 卡出「导入有声书」，漫画卡不出；工作室只给 EPUB', () {
      expect(
        ReaderFushiSource.mediaItemSupportsAudiobook(bookCard(BookFormat.epub)),
        isTrue,
      );
      expect(
        ReaderFushiSource.mediaItemSupportsAudiobook(bookCard(BookFormat.pdf)),
        isTrue,
        reason: 'PDF 阅读器播有声书、按文本层高亮，PDF 卡露出「导入有声书」',
      );
      expect(
        ReaderFushiSource.mediaItemSupportsAudiobook(
          bookCard(BookFormat.manga),
        ),
        isFalse,
      );
      expect(
        ReaderFushiSource.mediaItemSupportsAudiobookStudio(
          bookCard(BookFormat.epub),
        ),
        isTrue,
      );
      expect(
        ReaderFushiSource.mediaItemSupportsAudiobookStudio(
          bookCard(BookFormat.pdf),
        ),
        isFalse,
        reason: '工作室按 EPUB 章 / 句合成，PDF 卡不露出「有声书工作室」',
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

  test('BUG-728 顶替规则只对能挂有声书的格式成立：PDF 原卡被 SRT 卡顶替，漫画原卡不藏', () {
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
    expect(shadowed, <String>{'k_pdf', 'k_epub', 'k_missing'});
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
        compactCode('ReaderFushiSource.mediaItemSupportsAudiobookStudio(item)'),
      ),
      isTrue,
      reason: '书卡「有声书工作室」入口按工作室判据门控（PDF 不出）',
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

  test('源码守卫：PDF 阅读器接有声书会话、跨页跟随并在页上画字幕句高亮', () {
    final String pdf = compactCode(
      maskComments(
        File(
          'lib/src/pages/implementations/reader_pdf_page.dart',
        ).readAsStringSync(),
      ),
    );
    for (final String needle in <String>[
      'implements ReaderAudiobookView',
      'newAudiobookSessionLauncher()',
      'session.attachReader(this)',
      'appModel.audiobookSession.detachReader(this)',
      'notifySectionRestoreCompleted(',
      'abortChapterTransition()',
      'pagePaintCallbacks: _pagePaintCallbacks',
      'pdfRawRangeForNormRange(',
      'AudiobookPlayBar(',
      'FushiChromeReveal(',
    ]) {
      expect(
        pdf.contains(compactCode(needle)),
        isTrue,
        reason: 'PDF 阅读器有声书接线缺 `$needle`',
      );
    }
    expect(
      pdf.contains(compactCode('ModuleId.listening')),
      isTrue,
      reason: '听书模块关闭时不起有声书会话',
    );
  });

  test('源码守卫：对齐正文按 format 分派，app 侧不再把 extractDir 当 EPUB 解析', () {
    for (final String path in <String>[
      'lib/src/media/audiobook/audiobook_import_dialog.dart',
      'lib/src/media/audiobook/subtitle_rematch.dart',
    ]) {
      final String src = maskComments(File(path).readAsStringSync());
      expect(
        src.contains('loadEpubSectionsInBackground('),
        isFalse,
        reason: '$path：PDF 书目录按 EPUB 解析恒为 0 章，必须走 loadBookTextSections',
      );
      expect(src.contains('loadBookTextSections('), isTrue, reason: path);
    }
    final String bindings = maskComments(
      File('lib/src/engine_bindings.dart').readAsStringSync(),
    );
    expect(
      bindings.contains('pdfTextSectionsLoader = loadPdfTextSections;'),
      isTrue,
      reason: 'app 宿主必须注入 PDF 文本层读取器，否则 PDF 有声书全部未匹配',
    );
  });
}

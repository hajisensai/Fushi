import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/audiobook/book_text_sections.dart';
import 'package:test/test.dart';

/// PDF 有声书（拍板项 pdf-audiobook-support）：对齐字幕用的正文按书的 format 分派。
///
/// 以前所有对齐入口都把 `extractDir` 当 EPUB 解压目录解析；PDF 行的书目录里只有
/// `document.pdf`，解析恒为 0 章，字幕全部落成「未匹配」，PDF 阅读器无从高亮。
/// 现在唯一分派点 [loadBookTextSectionsForRow]：PDF 走宿主注入的文本层读取器，
/// 漫画恒空，EPUB 照旧解压目录。
void main() {
  late FushiDatabase db;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    pdfTextSectionsLoader = null;
    await db.close();
  });

  Future<EpubBookRow> insertBook(String bookKey, BookFormat format) async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: bookKey,
        epubPath: format == BookFormat.pdf ? 'document.pdf' : '$bookKey.epub',
        extractDir: '${Directory.systemTemp.path}/fushi_missing_$bookKey',
        chapterCount: 3,
        chaptersJson: '[]',
        importedAt: 0,
        format: Value(format.dbValue),
      ),
    );
    return (await db.getEpubBook(bookKey))!;
  }

  test('PDF 行交给宿主注入的文本层读取器，原样返回逐页 section', () async {
    final EpubBookRow pdf = await insertBook('pdf_book', BookFormat.pdf);
    final List<String> seen = <String>[];
    pdfTextSectionsLoader = (EpubBookRow row) async {
      seen.add(row.bookKey);
      return const <EpubSection>[
        EpubSection(index: 0, href: 'pdf-page-1', text: '一頁目。'),
        EpubSection(index: 1, href: 'pdf-page-2', text: '二頁目。'),
      ];
    };

    final List<EpubSection> sections = await loadBookTextSectionsForRow(pdf);
    expect(seen, <String>['pdf_book']);
    expect(sections.map((EpubSection s) => s.index), <int>[0, 1]);
    expect(sections.map((EpubSection s) => s.text), <String>['一頁目。', '二頁目。']);

    // 按 bookKey 的入口走同一个分派点。
    expect(await loadBookTextSections(db, 'pdf_book'), hasLength(2));
    expect(seen, <String>['pdf_book', 'pdf_book']);
  });

  test('没有注入 PDF 读取器的宿主（服务端）拿到空正文，不去按 EPUB 解析', () async {
    final EpubBookRow pdf = await insertBook('pdf_book', BookFormat.pdf);
    expect(await loadBookTextSectionsForRow(pdf), isEmpty);
  });

  test('漫画没有可对齐的正文，绝不调 PDF 读取器', () async {
    final EpubBookRow manga = await insertBook('manga_book', BookFormat.manga);
    bool called = false;
    pdfTextSectionsLoader = (EpubBookRow row) async {
      called = true;
      return const <EpubSection>[];
    };
    expect(await loadBookTextSectionsForRow(manga), isEmpty);
    expect(called, isFalse);
  });

  test('EPUB 行不走 PDF 读取器（照旧解析解压目录）', () async {
    final EpubBookRow epub = await insertBook('epub_book', BookFormat.epub);
    bool called = false;
    pdfTextSectionsLoader = (EpubBookRow row) async {
      called = true;
      return const <EpubSection>[];
    };
    // 解压目录不存在：EPUB 解析抛错由调用方记日志——这里只钉「没被分到 PDF」。
    await loadBookTextSectionsForRow(
      epub,
    ).then((List<EpubSection> _) {}, onError: (Object _) {});
    expect(called, isFalse);
  });

  test('书架上没有这本书 = 无正文', () async {
    expect(await loadBookTextSections(db, 'nope'), isEmpty);
  });
}

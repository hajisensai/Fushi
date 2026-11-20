// BUG-3341（反馈 3C7L0E7blH / Hen1JFOb-P）：漫画卡长按菜单的快捷格是「导入有声书 /
// 有声书工作室」（漫画阅读器根本不播有声书），没有 OCR；多选底栏也没有批量 OCR。
// 修复：卡菜单与多选都走共享的 `manga_book_ocr.dart`——按书挑出还没识别的目标（在线
// 作品 = 已下载未识别的章，本地卷 = 未识别的卷）再排进 OCR 注册表，与作品页
// 「识别全部已下载」同一条路径。
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/library/manga_book_ocr.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

String _mangaJson({required bool recognized}) => jsonEncode(<String, Object?>{
  'pages': <Object?>[
    <String, Object?>{
      'url': 'images/page-000001.jpg',
      'width': 100,
      'height': 100,
      'blocks': recognized
          ? <Object?>[
              <String, Object?>{
                'box': <int>[0, 0, 10, 10],
                'vertical': true,
                'font_size': 12,
                'lines': <String>['テスト'],
              },
            ]
          : <Object?>[],
    },
  ],
});

void main() {
  late Directory tmp;
  late FushiDatabase db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('manga_book_ocr_test');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  Future<EpubBookRow> localVolume(
    String key, {
    required bool recognized,
  }) async {
    final Directory dir = Directory(p.join(tmp.path, key))..createSync();
    File(
      p.join(dir.path, 'manga.json'),
    ).writeAsStringSync(_mangaJson(recognized: recognized));
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: key,
        title: key,
        epubPath: 'manga.json',
        extractDir: dir.path,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 0,
        format: Value<String>(BookFormat.manga.dbValue),
      ),
    );
    return (await db.getEpubBook(key))!;
  }

  test('readMangaOcrResultState：空 blocks / 有结果 / 读不出 三态', () async {
    final File empty = File(p.join(tmp.path, 'empty.json'))
      ..writeAsStringSync(_mangaJson(recognized: false));
    final File done = File(p.join(tmp.path, 'done.json'))
      ..writeAsStringSync(_mangaJson(recognized: true));
    final File broken = File(p.join(tmp.path, 'broken.json'))
      ..writeAsStringSync('{not json');
    expect(await readMangaOcrResultState(empty), MangaOcrResultState.empty);
    expect(await readMangaOcrResultState(done), MangaOcrResultState.hasResult);
    expect(
      await readMangaOcrResultState(broken),
      MangaOcrResultState.unreadable,
    );
    expect(
      await readMangaOcrResultState(File(p.join(tmp.path, 'missing.json'))),
      MangaOcrResultState.unreadable,
    );
  });

  test('本地卷：未识别的卷是一个整卷目标（目录 = extractDir、结果写回 manga.json）', () async {
    final EpubBookRow row = await localVolume('vol1', recognized: false);
    final List<MangaOcrTarget> targets = await pendingMangaOcrTargets(row);
    expect(targets, hasLength(1));
    expect(targets.single.bookKey, 'vol1');
    expect(targets.single.directory, row.extractDir);
    expect(targets.single.mangaJsonPath, p.join(row.extractDir, 'manga.json'));
    expect(targets.single.onlyMissing, isTrue);
  });

  test('本地卷：已识别过的卷不再排（重识别走阅读器的「重新识别本卷」）', () async {
    final EpubBookRow row = await localVolume('vol2', recognized: true);
    expect(await pendingMangaOcrTargets(row), isEmpty);
  });

  test('漫画卡菜单的有声流程收进有声漫画工作台，工作台与多选底栏接到同一条 OCR 路径（源码守卫）', () {
    final String shelf = File(
      'lib/src/pages/implementations/reader_fushi_history_page.dart',
    ).readAsStringSync();
    final String books = File(
      'lib/src/pages/implementations/reader_history/books.part.dart',
    ).readAsStringSync();
    final String workbench = File(
      'lib/src/media/manga/audio/manga_audio_workbench_page.dart',
    ).readAsStringSync();
    // 2026-11-20 #4：菜单顶部 5 个无文字图标里的 OCR / 演出稿 / 导入成品 / 生成
    // 4 个是同一条有声流程，收成一个「有声漫画工作台」入口。
    expect(
      RegExp(
        r'if \(isManga &&\s*modules\.isEnabled\(ModuleId\.manga\) &&\s*'
        r'MangaAudioWorkbenchEntry\.isAvailable\)\s*'
        r'DialogWorkbenchAction\(\s*label: t\.manga_audio_workbench_title,',
      ).hasMatch(shelf),
      isTrue,
      reason: '漫画卡要有有声漫画工作台入口',
    );
    // 工作台页在 import 大环里，菜单只经环外入口打开；入口由 main() 注册。
    expect(
      shelf.contains('manga_audio_workbench_page.dart'),
      isFalse,
      reason: '菜单直接 import 工作台页会把它拉进 import 大环',
    );
    expect(
      File('lib/main.dart').readAsStringSync(),
      contains('registerMangaAudioWorkbenchEntry();'),
    );
    expect(
      RegExp(
        r'if \(canAttachAudiobook\)\s*'
        r'DialogListAction\(\s*label: t\.audiobook_import,',
      ).hasMatch(shelf),
      isTrue,
      reason:
          '通用「导入有声书」（按 EPUB 正文匹配字幕）只按共享判据 '
          'mediaItemSupportsAudiobook 出现（漫画卡不出现）',
    );
    // 工作台里 OCR 与多选底栏同一入口函数，导入漫画有声成品也在工作台里。
    expect(workbench.contains('enqueuePendingMangaOcrForBooks('), isTrue);
    expect(workbench.contains('pickAndImportMangaAudio('), isTrue);
    expect(books.contains("key: 'reader_shelf_batch_ocr'"), isTrue);
    expect(books.contains('enqueuePendingMangaOcrForBooks('), isTrue);
  });
}

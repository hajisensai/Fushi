import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/media_item.dart';
import 'package:hibiki/src/pages/implementations/manga_hibiki_page.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

import '../helpers/test_platform_services.dart';

/// 暴露内存库的测试 [AppModel]：漫画页 post-frame 的 `_loadBook` 无需真实后端即可
/// 查询。弹窗布局 getter 照 base_source_page 系测试惯例覆写（热槽 seed 会读）。
class _MangaTestAppModel extends AppModel {
  _MangaTestAppModel(this._db) : super(testPlatformServices());

  final HibikiDatabase _db;

  @override
  HibikiDatabase get database => _db;

  @override
  bool get lowMemoryMode => false;

  @override
  double get popupMaxWidth => 360;

  @override
  double get popupMaxHeight => 360;

  @override
  bool get popupBottomDocked => false;

  @override
  double get appUiScale => 1.0;
}

Widget _harness(AppModel appModel, MediaItem item, String bookKey) {
  return ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((ref) => appModel),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        builder: (BuildContext context, Widget? child) =>
            child ?? const SizedBox.shrink(),
        home: MangaHibikiPage(item: item, bookKey: bookKey),
      ),
    ),
  );
}

MediaItem _item(String bookKey) {
  return MediaItem(
    mediaIdentifier: 'hoshi://book/$bookKey',
    mediaSourceIdentifier: 'reader_manga',
    title: 'Test Manga',
    mediaTypeIdentifier: 'reader',
    position: 0,
    duration: 1,
    canDelete: false,
    canEdit: true,
  );
}

/// 两页最小 manga.json（页图 100x150，无 OCR 框——渲染链路无需框）。
String _mangaJson() {
  return jsonEncode(<String, Object?>{
    'pages': <Map<String, Object?>>[
      <String, Object?>{
        'url': 'p001.jpg',
        'width': 100,
        'height': 150,
        'blocks': <Object?>[],
      },
      <String, Object?>{
        'url': 'p002.jpg',
        'width': 100,
        'height': 150,
        'blocks': <Object?>[],
      },
    ],
  });
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets('无 DB 行时页面安全降级（挂载 + 词典宿主在树里）', (WidgetTester tester) async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final _MangaTestAppModel appModel = _MangaTestAppModel(db);

    await tester
        .pumpWidget(_harness(appModel, _item('missing_book'), 'missing_book'));
    await tester.pump();
    await tester.pump();

    // 页面挂载（build 无异常）。
    expect(find.byType(MangaHibikiPage), findsOneWidget);
    // 词典弹窗层已接进树（buildDictionary 在空栈时收缩，但宿主 key 必须在）。
    expect(find.byKey(const ValueKey<String>('manga_dictionary_host')),
        findsOneWidget);
  });

  testWidgets('有书行时加载 manga.json 并恢复已存页码（真实进度读穿）', (WidgetTester tester) async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final _MangaTestAppModel appModel = _MangaTestAppModel(db);

    final Directory bookDir =
        Directory.systemTemp.createTempSync('manga_page_widget_');
    addTearDown(() {
      if (bookDir.existsSync()) bookDir.deleteSync(recursive: true);
    });
    File(p.join(bookDir.path, 'manga.json')).writeAsStringSync(_mangaJson());
    Directory(p.join(bookDir.path, 'images')).createSync();
    File(p.join(bookDir.path, 'images', 'p001.jpg')).writeAsBytesSync(<int>[1]);
    File(p.join(bookDir.path, 'images', 'p002.jpg')).writeAsBytesSync(<int>[2]);

    const String bookKey = 'テスト漫画';
    // runAsync：_loadBook 走真实文件 IO + Isolate.run（FakeAsync 下 isolate 的
    // future 永不完成）。
    await tester.runAsync(() async {
      await db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: 'テスト漫画',
        epubPath: 'manga.json',
        extractDir: bookDir.path,
        chapterCount: 2,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: const Value<String>('manga'),
      ));
      // 预存进度：第 2 页（0-based sectionIndex=1，charOffset 显式 0）。
      await ReaderPositionRepository(db).save(
        bookKey: bookKey,
        sectionIndex: 1,
        normCharOffset: 0,
        charOffset: 0,
      );

      await tester.pumpWidget(_harness(appModel, _item(bookKey), bookKey));
      // post-frame 触发 _loadBook；轮询等待加载链（IO + isolate + DB）完成。
      for (int i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        if (find
            .byKey(const ValueKey<String>('manga_webview'))
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
    });
    await tester.pump();

    // WebView 已构建（fake 平台渲染空盒）——书行 + manga.json 全链路加载成功。
    expect(find.byKey(const ValueKey<String>('manga_webview')), findsOneWidget);
    // 页码指示恢复到已存页：2 / 2（sectionIndex=1 → 1-based 第 2 页）。
    expect(find.text('2 / 2'), findsOneWidget,
        reason: 'ReaderPositions.sectionIndex 必须恢复为当前页（0-based → 1-based 显示）');
  });

  test('webtoon 进度经 ReaderPositions 写穿：charOffset 千分比往返', () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    const String bookKey = 'webtoon_book';
    final ReaderPositionRepository repo = ReaderPositionRepository(db);

    // 页面的落库口径：sectionIndex=页码、normCharOffset=0、charOffset=千分比。
    await repo.save(
      bookKey: bookKey,
      sectionIndex: 3,
      normCharOffset: 0,
      charOffset: MangaHibikiPage.webtoonFractionToCharOffset(0.75),
    );
    final ReaderPosition? restored = await repo.findByBookKey(bookKey);
    expect(restored, isNotNull);
    expect(restored!.sectionIndex, 3);
    expect(
        MangaHibikiPage.charOffsetToWebtoonFraction(restored.charOffset), 0.75,
        reason: 'webtoon 页内滚动位置必须经 charOffset 千分比写穿并无损恢复');
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/manga/manga_ocr_provider.dart';
import 'package:hibiki/src/media/manga/manga_reading_mode.dart';
import 'package:hibiki/src/media/media_item.dart';
import 'package:hibiki/src/ocr/manga_ocr_service.dart';
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

  @override
  String get mangaSpreadPreference => 'auto';

  @override
  String get mangaReadingDirection => 'rtl';

  @override
  int get mangaZoomPercent => 100;
}

/// 整卷 OCR 入口测试用 fake 服务（只有 modelStatus 有意义）。
class _FakeMangaOcrService implements MangaOcrService {
  _FakeMangaOcrService({required this.ready});

  final bool ready;

  @override
  bool get isSupportedPlatform => false;

  @override
  Future<MangaOcrModelStatus> modelStatus() async => MangaOcrModelStatus(
        detectorReady: false,
        recognizerReady: ready,
        downloadedBytes: 0,
        totalBytes: 1,
      );

  @override
  Stream<MangaOcrDownloadEvent> downloadModels() =>
      const Stream<MangaOcrDownloadEvent>.empty();

  @override
  Future<void> deleteModels() async {}

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
  }) =>
      const Stream<MangaOcrVolumeEvent>.empty();
}

Widget _harness(AppModel appModel, MediaItem item, String bookKey,
    {List<Override> extraOverrides = const <Override>[]}) {
  return ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((ref) => appModel),
      ...extraOverrides,
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
    final Iterable<Focus> keyboardAncestors = tester.widgetList<Focus>(
      find.ancestor(
        of: find.byKey(const ValueKey<String>('manga_dictionary_host')),
        matching: find.byType(Focus),
      ),
    );
    expect(
      keyboardAncestors.any((Focus focus) => focus.onKeyEvent != null),
      isTrue,
      reason: '词典 WebView 必须位于漫画翻页键处理器的 Focus 子树内',
    );
  });

  testWidgets('有书行时加载 manga.json 并恢复已存页码（真实进度读穿）', (WidgetTester tester) async {
    // 钉竖屏视口：本测试断言的是单页布局下的恢复语义；默认测试面 800x600 是
    // 横屏，会命中自动双页布局（横屏双页），页码指示会变成区间显示。
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
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
            .byKey(const ValueKey<String>('manga_content_ready'))
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
    });
    await tester.pump();

    // 内容区已构建（manga_content_ready 平台无关标记：非 Linux 是原生 WebView，
    // Linux 是无后端占位）——书行 + manga.json 全链路加载成功。
    expect(find.byKey(const ValueKey<String>('manga_content_ready')),
        findsOneWidget);
    // 页码指示恢复到已存页：2 / 2（sectionIndex=1 → 1-based 第 2 页）。
    expect(find.text('2 / 2'), findsOneWidget,
        reason: 'ReaderPositions.sectionIndex 必须恢复为当前页（0-based → 1-based 显示）');
  });

  testWidgets('整卷 OCR 入口：书加载成功后 chrome 出现按钮', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final _MangaTestAppModel appModel = _MangaTestAppModel(db);

    final Directory bookDir =
        Directory.systemTemp.createTempSync('manga_full_ocr_entry_');
    addTearDown(() {
      if (bookDir.existsSync()) bookDir.deleteSync(recursive: true);
    });
    File(p.join(bookDir.path, 'manga.json')).writeAsStringSync(_mangaJson());
    Directory(p.join(bookDir.path, 'images')).createSync();
    File(p.join(bookDir.path, 'images', 'p001.jpg')).writeAsBytesSync(<int>[1]);
    File(p.join(bookDir.path, 'images', 'p002.jpg')).writeAsBytesSync(<int>[2]);

    const String bookKey = '整卷 OCR テスト';
    await tester.runAsync(() async {
      await db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: '整卷 OCR テスト',
        epubPath: 'manga.json',
        extractDir: bookDir.path,
        chapterCount: 2,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: const Value<String>('manga'),
      ));
      await tester.pumpWidget(_harness(
        appModel,
        _item(bookKey),
        bookKey,
        extraOverrides: <Override>[
          mangaOcrServiceProvider
              .overrideWithValue(_FakeMangaOcrService(ready: true)),
        ],
      ));
      for (int i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        if (find
            .byKey(const ValueKey<String>('manga_content_ready'))
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
    });
    await tester.pump();

    // 书加载成功 → chrome 在树 → 整卷 OCR 入口在场。
    expect(find.byKey(const ValueKey<String>('manga_full_ocr_button')),
        findsOneWidget,
        reason: '整卷 OCR 入口必须出现在 chrome');
  });

  testWidgets('整卷 OCR 入口：加载失败（无书行）时 chrome 不构建 → 无按钮',
      (WidgetTester tester) async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final _MangaTestAppModel appModel = _MangaTestAppModel(db);

    await tester.pumpWidget(_harness(
      appModel,
      _item('missing_book'),
      'missing_book',
      extraOverrides: <Override>[
        mangaOcrServiceProvider
            .overrideWithValue(_FakeMangaOcrService(ready: true)),
      ],
    ));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('manga_full_ocr_button')),
        findsNothing);
  });

  testWidgets('页码弹窗关闭动画期间不使用已 dispose 的输入控制器', (WidgetTester tester) async {
    int? selected;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => FilledButton(
              onPressed: () async {
                selected = await showMangaPageJumpDialog(
                  context,
                  currentPage: 16,
                  total: 100,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '1');
    await tester.tap(find.text(t.dialog_ok));
    await tester.pumpAndSettle();

    expect(selected, 1);
    expect(tester.takeException(), isNull);
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

  test('查词弹窗显示后仍解析左右翻页、Escape 只关闭弹窗', () {
    expect(
      MangaHibikiPage.keyInputAction(
        key: LogicalKeyboardKey.arrowRight,
        dictionaryShown: true,
        mode: MangaReadingMode.spread,
        direction: 'ltr',
      ),
      MangaReaderInputAction.next,
    );
    expect(
      MangaHibikiPage.keyInputAction(
        key: LogicalKeyboardKey.arrowLeft,
        dictionaryShown: true,
        mode: MangaReadingMode.spread,
        direction: 'rtl',
      ),
      MangaReaderInputAction.next,
    );
    expect(
      MangaHibikiPage.keyInputAction(
        key: LogicalKeyboardKey.escape,
        dictionaryShown: true,
        mode: MangaReadingMode.spread,
        direction: 'ltr',
      ),
      MangaReaderInputAction.dismissDictionary,
    );
    expect(
      MangaHibikiPage.keyInputAction(
        key: LogicalKeyboardKey.space,
        dictionaryShown: true,
        mode: MangaReadingMode.spread,
        direction: 'ltr',
      ),
      isNull,
      reason: '词典内容仍保留自己的空格键语义',
    );
  });

  test('查词弹窗外的滚轮按主轴解析前后翻页', () {
    expect(
      MangaHibikiPage.wheelInputAction(const Offset(0, 120)),
      MangaReaderInputAction.next,
    );
    expect(
      MangaHibikiPage.wheelInputAction(const Offset(-120, 1)),
      MangaReaderInputAction.previous,
    );
    expect(
      MangaHibikiPage.wheelInputAction(const Offset(0, 1)),
      isNull,
      reason: '过滤触控板噪声',
    );
  });

  test('漫画正文按键桥接只捕获导航键并保持幂等', () {
    const String script = MangaHibikiPage.navigationKeyBridgeScript;
    expect(script, contains('__hibikiMangaNavigationKeysInstalled'));
    expect(script, contains("'ArrowLeft'"));
    expect(script, contains("'ArrowRight'"));
    expect(script, contains("'Escape'"));
    expect(script, contains('preventDefault()'));
    expect(script, contains('stopImmediatePropagation()'));
    expect(script, contains("callHandler('onMangaNavigationKey', key)"));
  });
}

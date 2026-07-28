import 'dart:async';
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
import 'package:hibiki/src/media/manga/manga_overlay_html.dart';
import 'package:hibiki/src/media/manga/manga_reading_mode.dart';
import 'package:hibiki/src/media/manga/mokuro_payload.dart';
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

  // BUG-1153：原守卫只验「HTML 里写了 generation」，不验丢弃。这一组验的是
  // 真正的丢弃判据——迟到的旧文档回调必须被拒，收尾步骤一步都不能跑。
  group('窗口 generation 闸门丢弃旧文档回调', () {
    test('只有与当前 generation 严格相等的回报才放行', () {
      expect(MangaWindowGeneration.isCurrent(7, 7), isTrue);
      expect(MangaWindowGeneration.isCurrent(7.0, 7), isTrue,
          reason: 'WebView 桥可能把整数回成 double');
      expect(MangaWindowGeneration.isCurrent('7', 7), isTrue,
          reason: '部分平台的 evaluateJavascript 回字符串');
    });

    test('迟到的旧 generation 被丢弃', () {
      // 场景：第 7 代文档的 onLoadStop 在第 8 代已经发起后才到。
      expect(MangaWindowGeneration.isCurrent(7, 8), isFalse);
      expect(MangaWindowGeneration.isCurrent('7', 8), isFalse);
      expect(MangaWindowGeneration.isCurrent(0, 3), isFalse,
          reason: '首个文档的迟到回调同样不能解锁第 3 代');
    });

    test('对不上号或解析不出的回报一律 fail-closed', () {
      expect(MangaWindowGeneration.isCurrent(9, 8), isFalse,
          reason: '比当前更大同样是对不上号，不能放行');
      expect(MangaWindowGeneration.isCurrent(null, 8), isFalse);
      expect(MangaWindowGeneration.isCurrent('undefined', 8), isFalse);
      expect(MangaWindowGeneration.isCurrent(<String>['8'], 8), isFalse);
      expect(MangaWindowGeneration.parse('not a number'), isNull);
      expect(MangaWindowGeneration.isCurrent(null, 0), isFalse,
          reason: '解析失败绝不能因为默认值 0 而误判成第 0 代');
    });

    test('相邻两代文档带的 generation 标记必须不同，闸门才有可区分的依据', () {
      String documentFor(int generation) => mangaWindowDocument(
            <MokuroImage>[
              const MokuroImage(
                url: 'p.jpg',
                size: Size(100, 200),
                blocks: <MokuroBlock>[],
              ),
            ],
            <String>['p.jpg'],
            mode: MangaReadingMode.spread,
            spreadDirection: 'rtl',
            inlineSelectionJs: '',
            currentSpread: 0,
            documentGeneration: generation,
          );

      expect(documentFor(7).contains('window.__mangaDocumentGeneration=7;'),
          isTrue);
      expect(documentFor(8).contains('window.__mangaDocumentGeneration=8;'),
          isTrue);
      expect(documentFor(7).contains('window.__mangaDocumentGeneration=8;'),
          isFalse,
          reason: '旧文档不能携带新 generation，否则闸门永远放行');
    });
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
    // 桥已改走共享生成器 webViewKeyBridgeScript（手写版少了「放行修饰键组合 /
    // IME 组字 / 输入框」三条判据，会吞 Ctrl+方向键和词典搜索框里的方向键）。
    // JS 本身的通用不变式由 test/focus/webview_key_bridge_test.dart 守，这里只钉
    // 本页特有的接线：键表、幂等、独占、不转发长按。
    final String script = MangaHibikiPage.navigationKeyBridgeScript;
    expect(script, contains('__hoshiKeyBridgeInstalled_onMangaNavigationKey'),
        reason: '每次换加载窗口都会重新注入，必须幂等，否则 listener 叠加导致一次按键翻两页');
    expect(script, contains("'ArrowLeft'"));
    expect(script, contains("'ArrowRight'"));
    expect(script, contains("'Escape'"));
    expect(script, contains('preventDefault()'));
    expect(script, contains('stopImmediatePropagation()'),
        reason: '导航键必须独占给 Dart');
    expect(script, contains('if (e.repeat) return;'),
        reason: '按住方向键不得堆翻页风暴（本页既有语义）');
    expect(script, contains("callHandler('onMangaNavigationKey', e.key)"));
  });

  test('高频翻页在异步窗口加载期间累积并按净位移排空', () async {
    final MangaTurnQueue queue = MangaTurnQueue();
    final Completer<void> firstWindowLoad = Completer<void>();
    final List<int> applied = <int>[];
    bool blockFirstStep = true;

    Future<void> applyStep(int step) async {
      applied.add(step);
      if (blockFirstStep) {
        blockFirstStep = false;
        await firstWindowLoad.future;
      }
    }

    final Future<void> firstDrain = queue.enqueue(
      1,
      maxMagnitude: 100,
      canApply: () => true,
      applyStep: applyStep,
    );
    await Future<void>.delayed(Duration.zero);
    expect(applied, <int>[1], reason: '第一步模拟跨预载窗口，正在等待 WebView loadData');

    // 完整压力序列：→→→→←←→→→→。第一步在飞期间剩余输入净值为 +5。
    for (final int step in <int>[1, 1, 1, -1, -1, 1, 1, 1, 1]) {
      unawaited(queue.enqueue(
        step,
        maxMagnitude: 100,
        canApply: () => true,
        applyStep: applyStep,
      ));
    }
    expect(queue.pendingDelta, 5);

    firstWindowLoad.complete();
    await firstDrain;
    expect(applied, <int>[1, 1, 1, 1, 1, 1],
        reason: '不得因窗口加载在飞而丢后半批输入，最终净前进 6 个 spread');
    expect(queue.pendingDelta, 0);
    expect(queue.isDraining, isFalse);
  });
}

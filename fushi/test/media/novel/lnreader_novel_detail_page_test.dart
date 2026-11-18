import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/manga/cookie/manga_cookie_jar.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/media/novel/online/lnreader_cloudflare.dart';
import 'package:fushi/src/media/novel/online/lnreader_manager.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/src/media/novel/online/lnreader_novel_detail_page.dart';
import 'package:fushi/src/media/novel/online/lnreader_online_book.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi_audio/fushi_audio.dart' show Bookmark;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:path/path.dart' as p;

import '../../helpers/test_platform_services.dart';
import 'fake_lnreader_runtime.dart';

/// 小说作品页的主操作区（2026-09-27「浏览」阶段 2）：「加入书架」只建在线书、
/// 不开阅读器，建好后同一位置变成「移出书架」；「下载」与加入书架分开，弹章节
/// 范围对话框。
void main() {
  late Directory root;
  late FushiDatabase db;
  late FakeLnReaderRuntime runtime;
  late LnReaderManager manager;

  const String builtin = 'https://builtin.example/plugins.min.json';
  const LnReaderNovelItem item = LnReaderNovelItem(name: 'Novel A', path: '/a');
  const List<LnReaderChapter> chapters = <LnReaderChapter>[
    LnReaderChapter(name: 'Chapter one', path: '/a/1'),
    LnReaderChapter(name: 'Chapter two', path: '/a/2'),
    LnReaderChapter(name: 'Chapter three', path: '/a/3'),
  ];

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    root = await Directory.systemTemp.createTemp('lnreader_detail_test');
    EpubStorage.debugBaseDirectoryOverride = p.join(root.path, 'books');
    // deleteBook 的尾活会经 path_provider 找有声书持久目录。
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async => p.join(root.path, call.method),
        );
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    MediaSource.setDatabase(db);
    runtime = FakeLnReaderRuntime(
      novelResult: const LnReaderNovel(
        name: 'Novel A',
        path: '/a',
        chapters: chapters,
        totalPages: 1,
      ),
    );
    final Directory pluginRoot = Directory(p.join(root.path, 'lnreader'));
    await pluginRoot.create(recursive: true);
    await File(p.join(pluginRoot.path, 'state.json')).writeAsString(
      '{"stores":[],"installed":[{"id":"syosetu","name":"Syosetu",'
      '"site":"https://syosetu.example/","lang":"日本語","version":"1.0.0",'
      '"url":"","iconUrl":"","storeUrl":"$builtin","enabled":true,'
      '"pinned":false,"sortOrder":0,"installedAt":0}]}',
    );
    manager = LnReaderManager(
      rootDirectory: pluginRoot,
      runtime: runtime,
      httpClientFactory: HttpClient.new,
      legacyBuiltinStoreUrl: builtin,
    );
    await manager.initialise();
    await manager.pluginFile('syosetu').create(recursive: true);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    EpubStorage.debugBaseDirectoryOverride = null;
    manager.dispose();
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// 建书走真实 EPUB 导入（`Isolate.run` 解析 + 落盘），并发跑测试时可能要好几秒：
  /// 兜底给 30 秒，条件一达成立即返回。
  Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
    for (int i = 0; i < 600; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      if (finder.evaluate().isNotEmpty) return;
    }
    fail('never found $finder');
  }

  Future<_TestAppModel> pumpDetail(
    WidgetTester tester, {
    LnReaderManager? withManager,
  }) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final _TestAppModel appModel = _TestAppModel(db, root);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          platformServicesProvider.overrideWithValue(testPlatformServices()),
          appProvider.overrideWith((Ref ref) => appModel),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: LnReaderNovelDetailPage(
              manager: withManager ?? manager,
              plugin: (withManager ?? manager).installed.single,
              item: item,
              imageHeaders: const <String, String>{},
            ),
          ),
        ),
      ),
    );
    return appModel;
  }

  // 审查（PR #2986）：作品页的登录入口（菜单常驻 + 加载失败时错误区）原先没有测试。
  group('作品页登录入口', () {
    const ValueKey<String> menuLogin = ValueKey<String>('novel_detail_login');
    const ValueKey<String> errorLogin = ValueKey<String>(
      'novel_source_login_syosetu',
    );

    testWidgets('能登录的源（有 jar）：菜单常驻「登录」，取不到作品时错误旁也给，且不被挤偏', (
      WidgetTester tester,
    ) async {
      runtime.novelError = Exception('HTTP 401');
      late LnReaderManager loginManager;
      await tester.runAsync(() async {
        loginManager = LnReaderManager(
          rootDirectory: Directory(p.join(root.path, 'lnreader')),
          runtime: runtime,
          httpClientFactory: HttpClient.new,
          legacyBuiltinStoreUrl: builtin,
          cloudflare: LnReaderCloudflare(
            MangaCookieJar(File(p.join(root.path, 'novel-cookies.json'))),
          ),
        );
        await loginManager.initialise();
        await pumpDetail(tester, withManager: loginManager);
        await pumpUntil(tester, find.byKey(errorLogin));
      });
      addTearDown(loginManager.dispose);
      expect(find.byKey(menuLogin), findsOneWidget);
      final Finder wrap = find
          .ancestor(of: find.byKey(errorLogin), matching: find.byType(Wrap))
          .first;
      expect(
        tester.getSize(wrap).width,
        tester.getSize(find.byKey(errorLogin)).width,
        reason: '没显示的 Cloudflare 按钮不该留下 spacing 空隙',
      );
    });

    testWidgets('没有 jar 的 manager：两处都不给登录', (WidgetTester tester) async {
      runtime.novelError = Exception('HTTP 401');
      await tester.runAsync(() async {
        await pumpDetail(tester);
        await pumpUntil(tester, find.text(t.retry));
      });
      expect(find.byKey(menuLogin), findsNothing);
      expect(find.byKey(errorLogin), findsNothing);
    });
  });

  const ValueKey<String> addKey = ValueKey<String>('novel_detail_library_add');
  const ValueKey<String> removeKey = ValueKey<String>(
    'novel_detail_library_remove',
  );
  const ValueKey<String> readKey = ValueKey<String>('novel_detail_read_online');

  String buttonLabel(WidgetTester tester, ValueKey<String> key) => tester
      .widget<Text>(
        find.descendant(of: find.byKey(key), matching: find.byType(Text)),
      )
      .data!;

  /// 主按钮与右下角悬浮按钮同一份文案（[MediaDetailResumeFab.labelFor]）：没有
  /// 阅读位置 →「开始阅读 · 首章」。
  String startReading() => '${t.media_detail_start_reading} · Chapter one';

  testWidgets('加入书架只建在线书、不开阅读器；之后按钮变成「移出书架」，确认后退回', (
    WidgetTester tester,
  ) async {
    late _TestAppModel appModel;
    await tester.runAsync(() async {
      appModel = await pumpDetail(tester);
      await pumpUntil(tester, find.text('Chapter one'));
    });
    expect(find.byKey(addKey), findsOneWidget);
    expect(find.byKey(removeKey), findsNothing);
    expect(buttonLabel(tester, readKey), startReading());

    await tester.runAsync(() async {
      await tester.tap(find.byKey(addKey));
      await pumpUntil(tester, find.byKey(removeKey));
    });
    expect(find.byKey(addKey), findsNothing);
    expect(appModel.opened, isEmpty, reason: '「加入书架」不再顺手开阅读器，也不再是整本下载。');
    expect(
      find.byType(LnReaderChapterRangeDialog),
      findsNothing,
      reason: '加入书架与下载已分开，不弹章节范围。',
    );
    expect(
      buttonLabel(tester, readKey),
      startReading(),
      reason: '主按钮文案只看阅读位置、不看在不在书架：没打开过就是「开始阅读 · 首章」。',
    );

    final List<EpubBookRow> rows =
        await tester.runAsync(() => db.select(db.epubBooks).get())
            as List<EpubBookRow>;
    expect(rows, hasLength(1));
    final LnReaderOnlineBookDescriptor descriptor =
        LnReaderOnlineBookDescriptor.tryParse(rows.single.sourceMetadata)!;
    expect(descriptor.isNovel('syosetu', '/a'), isTrue);
    expect(
      descriptor.chapters.map((LnReaderChapter c) => c.path),
      chapters.map((LnReaderChapter c) => c.path),
    );
    expect(
      runtime.calls.where((String c) => c.startsWith('chapter:')),
      isEmpty,
      reason: '占位书不取任何章节正文。',
    );

    // 移出书架：与书架长按删除同一个确认框，确认后书行消失、按钮退回「加入」。
    await tester.runAsync(() async {
      await tester.tap(find.byKey(removeKey));
      await pumpUntil(tester, find.text(t.dialog_delete));
      await tester.tap(find.text(t.dialog_delete));
      await pumpUntil(tester, find.byKey(addKey));
    });
    expect(find.byKey(removeKey), findsNothing);
    expect(
      await tester.runAsync(() => db.getEpubBook(rows.single.bookKey)),
      isNull,
    );
    expect(buttonLabel(tester, readKey), startReading());
  });

  testWidgets('进页时已在书架：直接显示「移出书架」，没读过仍是「开始阅读」', (WidgetTester tester) async {
    await tester.runAsync(() async {
      // 走和页面同一条建书路径，免得手搓描述符与生产格式漂移。
      await pumpDetail(tester);
      // 「加入书架」在详情取回之前就在屏上（禁用）：等章节出来再点，否则点的是
      // 禁用态。
      await pumpUntil(tester, find.text('Chapter one'));
      await tester.tap(find.byKey(addKey));
      await pumpUntil(tester, find.byKey(removeKey));
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpDetail(tester);
      await pumpUntil(tester, find.text('Chapter one'));
    });
    expect(find.byKey(removeKey), findsOneWidget);
    expect(find.byKey(addKey), findsNothing);
    expect(buttonLabel(tester, readKey), startReading());
  });

  group('已上架的作品先出旧目录（novel-d4）', () {
    const ValueKey<String> downloadKey = ValueKey<String>(
      'novel_detail_download',
    );
    const ValueKey<String> rowDownloadKey = ValueKey<String>(
      'novel_chapter_download_/a/1',
    );

    bool enabled(WidgetTester tester, ValueKey<String> key) =>
        tester.widget<FushiIconButtonControl>(find.byKey(key)).onPressed !=
        null;

    bool readEnabled(WidgetTester tester) =>
        tester
            .widget<MediaDetailPrimaryButton>(
              find.ancestor(
                of: find.byKey(readKey),
                matching: find.byType(MediaDetailPrimaryButton),
              ),
            )
            .onPressed !=
        null;

    bool secondaryEnabled(WidgetTester tester, ValueKey<String> key) =>
        tester
            .widget<MediaDetailSecondaryButton>(
              find.ancestor(
                of: find.byKey(key),
                matching: find.byType(MediaDetailSecondaryButton),
              ),
            )
            .onPressed !=
        null;

    /// 先走页面自己的「加入书架」建好在线书，再换成源站卡住的运行时重进页面。
    Future<_GatedRuntime> reenterWithGatedSource(
      WidgetTester tester, {
      bool newChapter = true,
    }) async {
      await pumpDetail(tester);
      // 「加入书架」在详情取回之前就在屏上（禁用）：等章节出来再点，否则点的是
      // 禁用态。
      await pumpUntil(tester, find.text('Chapter one'));
      await tester.tap(find.byKey(addKey));
      await pumpUntil(tester, find.byKey(removeKey));
      await tester.pumpWidget(const SizedBox.shrink());

      final _GatedRuntime gated = _GatedRuntime(
        novelResult: LnReaderNovel(
          name: 'Novel A',
          path: '/a',
          author: 'Author A',
          chapters: <LnReaderChapter>[
            ...chapters,
            if (newChapter)
              const LnReaderChapter(name: 'Chapter four', path: '/a/4'),
          ],
          totalPages: 1,
        ),
      );
      final LnReaderManager gatedManager = LnReaderManager(
        rootDirectory: Directory(p.join(root.path, 'lnreader')),
        runtime: gated,
        httpClientFactory: HttpClient.new,
        legacyBuiltinStoreUrl: builtin,
      );
      addTearDown(gatedManager.dispose);
      await gatedManager.initialise();
      await pumpDetail(tester, withManager: gatedManager);
      return gated;
    }

    testWidgets('源站还没回来：章节已经能看能读，下载等详情；回来后换成新目录', (WidgetTester tester) async {
      late _GatedRuntime gated;
      await tester.runAsync(() async {
        gated = await reenterWithGatedSource(tester);
        await pumpUntil(tester, find.text('Chapter one'));
      });
      expect(gated.calls, isNot(contains('novel:/a')), reason: '源站的详情确实还没取回。');
      expect(find.text('Chapter three'), findsOneWidget);
      expect(find.text('Chapter four'), findsNothing);
      expect(find.byKey(removeKey), findsOneWidget);
      expect(buttonLabel(tester, readKey), startReading());
      expect(
        readEnabled(tester),
        isTrue,
        reason: '旧目录的序号就是那本书现在的 spine，可以直接读。',
      );
      expect(
        secondaryEnabled(tester, downloadKey),
        isFalse,
        reason: '作者 / 简介 / 封面还没取回，不拿残缺详情去打 EPUB。',
      );
      expect(enabled(tester, rowDownloadKey), isFalse);

      await tester.runAsync(() async {
        gated.gate.complete();
        await pumpUntil(tester, find.text('Chapter four'));
      });
      expect(find.text('Author A'), findsOneWidget);
      expect(secondaryEnabled(tester, downloadKey), isTrue);
      expect(enabled(tester, rowDownloadKey), isTrue);
    });

    Object? replayKey(WidgetTester tester) => tester
        .widget<FushiEntranceScope>(
          find
              .ancestor(
                of: find.text('Chapter one'),
                matching: find.byType(FushiEntranceScope),
              )
              .first,
        )
        .replayKey;

    for (final bool newChapter in <bool>[false, true]) {
      testWidgets('章节列表的进场动画：源站目录的章节${newChapter ? '变了，重播' : '与旧目录相同，不重播'}', (
        WidgetTester tester,
      ) async {
        late _GatedRuntime gated;
        late Object? before;
        await tester.runAsync(() async {
          gated = await reenterWithGatedSource(tester, newChapter: newChapter);
          await pumpUntil(tester, find.text('Chapter one'));
          before = replayKey(tester);
          gated.gate.complete();
          // 作者只有源站详情里有：它出来说明已经从旧目录换成了源站目录。
          await pumpUntil(tester, find.text('Author A'));
        });
        expect(before, isNotNull);
        expect(identical(replayKey(tester), before), !newChapter);
      });
    }

    testWidgets('源站取不回来：旧目录留着照常可读，头部挂错误，不退成整页报错', (WidgetTester tester) async {
      late _GatedRuntime gated;
      await tester.runAsync(() async {
        gated = await reenterWithGatedSource(tester);
        await pumpUntil(tester, find.text('Chapter one'));
        gated.novelError = Exception('HTTP 503');
        gated.gate.complete();
        await pumpUntil(tester, find.byType(FushiInlineNotice));
      });
      expect(find.text('Chapter three'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('novel_detail_error')),
        findsNothing,
      );
      expect(readEnabled(tester), isTrue);
    });

    testWidgets('旧目录阶段移出书架：目录跟着撤，不留一份假详情给「加入书架」', (WidgetTester tester) async {
      late _GatedRuntime gated;
      await tester.runAsync(() async {
        gated = await reenterWithGatedSource(tester);
        await pumpUntil(tester, find.text('Chapter one'));
        await tester.tap(find.byKey(removeKey));
        await pumpUntil(tester, find.text(t.dialog_delete));
        await tester.tap(find.text(t.dialog_delete));
        await pumpUntil(tester, find.byKey(addKey));
      });
      expect(find.text('Chapter one'), findsNothing);
      expect(
        secondaryEnabled(tester, addKey),
        isFalse,
        reason: '详情没回来之前没有可加入的东西。',
      );

      await tester.runAsync(() async {
        gated.gate.complete();
        await pumpUntil(tester, find.text('Chapter four'));
      });
      expect(find.byKey(addKey), findsOneWidget);
      expect(secondaryEnabled(tester, addKey), isTrue);
    });

    testWidgets('不在书架：没有旧目录可垫，照旧等源站', (WidgetTester tester) async {
      final _GatedRuntime gated = _GatedRuntime(
        novelResult: runtime.novelResult,
      );
      late LnReaderManager gatedManager;
      await tester.runAsync(() async {
        gatedManager = LnReaderManager(
          rootDirectory: Directory(p.join(root.path, 'lnreader')),
          runtime: gated,
          httpClientFactory: HttpClient.new,
          legacyBuiltinStoreUrl: builtin,
        );
        await gatedManager.initialise();
        await pumpDetail(tester, withManager: gatedManager);
        await pumpUntil(tester, find.byKey(addKey));
      });
      addTearDown(gatedManager.dispose);
      expect(find.text('Chapter one'), findsNothing);
      await tester.runAsync(() async {
        gated.gate.complete();
        await pumpUntil(tester, find.text('Chapter one'));
      });
    });
  });

  testWidgets('「下载」弹章节范围对话框，取消后什么都不入库', (WidgetTester tester) async {
    await tester.runAsync(() async {
      await pumpDetail(tester);
      await pumpUntil(tester, find.text('Chapter one'));
    });
    await tester.tap(
      find.byKey(const ValueKey<String>('novel_detail_download')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(LnReaderChapterRangeDialog), findsOneWidget);
    expect(
      find.text(t.novel_download_range_hint(from: 1, to: 3, count: 3)),
      findsOneWidget,
      reason: '主操作区的下载默认全部章节。',
    );
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();
    expect(find.byType(LnReaderChapterRangeDialog), findsNothing);
    expect(await tester.runAsync(() => db.select(db.epubBooks).get()), isEmpty);
    expect(find.byKey(addKey), findsOneWidget);
  });
}

/// 源站的详情卡在 [gate] 上：放行前 `novel()` 不返回。
class _GatedRuntime extends FakeLnReaderRuntime {
  _GatedRuntime({super.novelResult});

  final Completer<void> gate = Completer<void>();

  @override
  Future<LnReaderNovel> novel(String pluginId, String path) async {
    await gate.future;
    return super.novel(pluginId, path);
  }
}

class _TestAppModel extends AppModel {
  _TestAppModel(this._db, Directory root) : super(testPlatformServices()) {
    wireLocalAudioForTesting(
      prefsRepo: PreferencesRepository(_db),
      databaseDirectory: root,
    );
  }

  final FushiDatabase _db;
  final List<MediaItem?> opened = <MediaItem?>[];

  @override
  FushiDatabase get database => _db;

  @override
  Future<void> openMedia({
    required WidgetRef ref,
    required MediaSource mediaSource,
    bool killOnPop = false,
    bool pushReplacement = false,
    MediaItem? item,
    Bookmark? initialBookmarkJump,
    bool recordHistory = true,
    bool waitUntilClosed = true,
    Widget Function()? launchPageBuilder,
  }) async {
    opened.add(item);
  }
}

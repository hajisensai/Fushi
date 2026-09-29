import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/media/novel/online/lnreader_manager.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/src/media/novel/online/lnreader_novel_detail_page.dart';
import 'package:fushi/src/media/novel/online/lnreader_online_book.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
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
      builtinStoreUrl: builtin,
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

  Future<_TestAppModel> pumpDetail(WidgetTester tester) async {
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
              manager: manager,
              plugin: manager.installed.single,
              item: item,
              imageHeaders: const <String, String>{},
            ),
          ),
        ),
      ),
    );
    return appModel;
  }

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
    expect(buttonLabel(tester, readKey), t.novel_detail_read_online);

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
      t.book_continue_reading,
      reason: '在书架里时主操作是「继续阅读」。',
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
    expect(buttonLabel(tester, readKey), t.novel_detail_read_online);
  });

  testWidgets('进页时已在书架：直接显示「移出书架」与「继续阅读」', (WidgetTester tester) async {
    await tester.runAsync(() async {
      // 走和页面同一条建书路径，免得手搓描述符与生产格式漂移。
      await pumpDetail(tester);
      await pumpUntil(tester, find.byKey(addKey));
      await tester.tap(find.byKey(addKey));
      await pumpUntil(tester, find.byKey(removeKey));
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpDetail(tester);
      await pumpUntil(tester, find.text('Chapter one'));
    });
    expect(find.byKey(removeKey), findsOneWidget);
    expect(find.byKey(addKey), findsNothing);
    expect(buttonLabel(tester, readKey), t.book_continue_reading);
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

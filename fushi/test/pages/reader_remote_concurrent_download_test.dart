// BUG-3337（反馈 FvgH1f3vZ_）：从互联对端下载书的四个问题——
// ① 同时点多本：临时落点按书名派生、日文书名撞成同一个文件 → 几条下载互相写坏；
// ② 合集详情页里的远端卡进度不实时（订阅挂在书架页上，详情页是独立路由）；
// ③ 多选只勾合集时批量「下载」恒灰（只认散卡远端键）；
// ④ 下载完成书集合变化 → 书架整块换成转圈再换回，滚动位置归零跳回顶部。
import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/media_collection_grid_detail_page.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi/src/sync/remote_book_client.dart';
import 'package:fushi/src/sync/remote_download_progress_badge.dart';
import 'package:fushi/src/sync/remote_download_temp_file.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:path/path.dart' as p;

import '../helpers/test_platform_services.dart';

void main() {
  group('① 并发下载的临时落点', () {
    String legacySafeKey(String title) =>
        sanitizeTtuFilename(title).replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');

    test('两本日文书名旧口径撞成同一文件名，新落点按任务身份分开', () {
      const String a = 'かがみの孤城';
      const String b = '魔女の旅々';
      // 前提：旧落点只看书名派生键，这两本撞成同一个 `_.epub`。
      expect(legacySafeKey(a), legacySafeKey(b));
      final Directory root = Directory(p.join('tmp', 'hibiki_remote_books'));
      final File fa = remoteDownloadTempFile(
        root: root,
        identity: InterconnectDownloadManager.bookTaskId(a),
        fileName: '${legacySafeKey(a)}.epub',
      );
      final File fb = remoteDownloadTempFile(
        root: root,
        identity: InterconnectDownloadManager.bookTaskId(b),
        fileName: '${legacySafeKey(b)}.epub',
      );
      expect(fa.path, isNot(fb.path), reason: '并发的两个任务绝不能共用一个文件');
      expect(
        p.basename(fa.path),
        '${legacySafeKey(a)}.epub',
        reason: 'basename 不变：导入器拿它当无标题 EPUB 的回落书名',
      );
      expect(p.isWithin(root.path, fa.path), isTrue);
    });

    test('同一任务身份重试落在同一路径（.part 续传接得上）', () {
      final Directory root = Directory('r');
      File make() => remoteDownloadTempFile(
        root: root,
        identity: InterconnectDownloadManager.bookTaskId('x'),
        fileName: 'x.epub',
      );
      expect(make().path, make().path);
    });

    test('EPUB 解包临时目录名同一毫秒内也不重复', () {
      final Set<String> names = <String>{
        for (int i = 0; i < 50; i++) EpubImporter.nextTempDirName(),
      };
      expect(names, hasLength(50));
    });
  });

  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_remote_concurrent_pp',
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (pathProviderDir.existsSync()) {
      try {
        pathProviderDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  late FushiDatabase db;
  late AppModel appModel;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory storeDir = Directory.systemTemp.createTempSync(
      'fushi_remote_concurrent_store',
    );
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
  });

  tearDown(() async {
    await db.close();
  });

  Widget buildApp(
    RemoteBookClient client, {
    Future<List<MediaItem>> Function(Ref ref)? books,
  }) => ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((ref) => appModel),
      fushiBooksProvider.overrideWith(
        (ref, language) =>
            books?.call(ref) ??
            Future<List<MediaItem>>.value(const <MediaItem>[]),
      ),
      srtBooksProvider.overrideWith(
        (ref) => Future<List<SrtBook>>.value(const <SrtBook>[]),
      ),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        builder: (BuildContext context, Widget? child) =>
            child ?? const SizedBox.shrink(),
        home: Scaffold(
          body: ReaderFushiHistoryPage(
            remoteBookClientLoader: () async => client,
            remoteBookDownloadDestination: (RemoteBookInfo book) async =>
                File('${pathProviderDir.path}/${book.title.hashCode}.epub'),
            remoteBookImporter: (File file) async => null,
          ),
        ),
      ),
    ),
  );

  Finder collectionCard(int cid) =>
      find.byKey(ValueKey<String>('reader_shelf_collection_card_$cid'));

  RemoteBookInfo member(String title, int sortIndex) => RemoteBookInfo(
    title: title,
    hasContent: true,
    collection: RemoteCollectionMembership(
      collectionName: 'MyShow',
      collectionType: 'collection',
      sortIndex: sortIndex,
    ),
  );

  testWidgets('② 合集详情页里的远端卡进度随任务实时推进（与书架同一组件）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final int cid = await db.createMediaCollection(
      'MyShow',
      collectionType: 'collection',
    );
    final _SteppedRemoteBookClient client = _SteppedRemoteBookClient(
      <RemoteBookInfo>[member('Vol1', 0)],
    );
    await tester.pumpWidget(buildApp(client));
    await tester.pumpAndSettle();

    await tester.tap(collectionCard(cid));
    await tester.pumpAndSettle();
    final Finder detail = find.byType(MediaCollectionGridDetailPage);
    expect(detail, findsOneWidget);

    await tester.tap(
      find.descendant(
        of: detail,
        matching: find.byKey(const ValueKey<String>('remote_book_card_Vol1')),
        // 详情页把成员卡自身手势包在 IgnorePointer 里、点击由格子接管
        // （onOpenMember），命中链上没有卡本身是预期的。
      ),
      warnIfMissed: false,
    );
    await tester.pump();
    await tester.pump();

    double? badgeProgress() => tester
        .widget<RemoteDownloadProgressBadge>(
          find.descendant(
            of: detail,
            matching: find.byKey(
              const ValueKey<String>('remote_book_downloading_Vol1'),
            ),
          ),
        )
        .progress;

    expect(badgeProgress(), closeTo(0.1, 0.001), reason: '点下去详情页里的卡就要变成进度态');
    client.step(0.6);
    await tester.pump();
    await tester.pump();
    expect(
      badgeProgress(),
      closeTo(0.6, 0.001),
      reason: '详情页是独立路由，订阅挂在书架上时这里永远停在起跑那一刻',
    );
  });

  testWidgets('③ 多选只勾合集 → 批量「下载」可用，下合集里全部云端成员', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final int cid = await db.createMediaCollection(
      'MyShow',
      collectionType: 'collection',
    );
    final _SteppedRemoteBookClient client = _SteppedRemoteBookClient(
      <RemoteBookInfo>[member('Vol1', 0), member('Vol2', 1)],
      autoFinish: true,
    );
    await tester.pumpWidget(buildApp(client));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(FushiIcons.checklist));
    await tester.pumpAndSettle();
    await tester.tap(collectionCard(cid));
    await tester.pump();
    expect(find.text(t.batch_selected_count(n: 1)), findsOneWidget);
    expect(
      tester
          .widget<FushiIconButton>(
            find.byKey(const ValueKey<String>('reader_shelf_batch_download')),
          )
          .enabled,
      isTrue,
      reason: '勾了含云端成员的合集，「下载」不能是灰的（用户：按钮似乎无效）',
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('reader_shelf_batch_download')),
    );
    for (int i = 0; i < 200 && client.fetched.length < 2; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(client.fetched, <String>[
      'Vol1',
      'Vol2',
    ], reason: '合集一键全部下载：按成员序逐本交给下载链');
  });

  testWidgets('④ 书集合变化导致书架数据重算时不换成转圈、滚动位置不归零', (WidgetTester tester) async {
    final StateProvider<int> booksRevision = StateProvider<int>((ref) => 0);
    final Completer<List<MediaItem>> reload = Completer<List<MediaItem>>();
    final _SteppedRemoteBookClient client =
        _SteppedRemoteBookClient(<RemoteBookInfo>[
          for (int i = 0; i < 60; i++)
            RemoteBookInfo(
              title: 'Cloud ${i.toString().padLeft(2, '0')}',
              hasContent: true,
            ),
        ]);
    await tester.pumpWidget(
      buildApp(
        client,
        books: (Ref ref) {
          return ref.watch(booksRevision) == 0
              ? Future<List<MediaItem>>.value(const <MediaItem>[])
              : reload.future;
        },
      ),
    );
    await tester.pumpAndSettle();

    ScrollController shelfController() => tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pumpAndSettle();
    final double scrolled = shelfController().offset;
    expect(scrolled, greaterThan(100), reason: '前置：书架已经滚下去了');

    // 下载落库 → 书集合变化 → fushiBooksProvider 依赖变化重算（reload 态）。
    ProviderScope.containerOf(
      tester.element(find.byType(ReaderFushiHistoryPage)),
    ).read(booksRevision.notifier).state++;
    await tester.pump();
    await tester.pump();

    expect(
      find.byType(CustomScrollView),
      findsOneWidget,
      reason: '重算期间网格必须留着旧数据，不能整块换成转圈',
    );
    expect(
      shelfController().offset,
      scrolled,
      reason: '网格被卸掉重建 → 滚动位置归零跳回顶部（用户实报）',
    );

    reload.complete(const <MediaItem>[]);
    await tester.pumpAndSettle();
    expect(shelfController().offset, scrolled);
  });
}

/// 下载体按 [step] 推进进度；[autoFinish] 时立即写盘结束。
class _SteppedRemoteBookClient implements RemoteBookClient {
  _SteppedRemoteBookClient(this._books, {this.autoFinish = false});
  final List<RemoteBookInfo> _books;
  final bool autoFinish;
  final List<String> fetched = <String>[];
  void Function(double progress)? _onProgress;
  final Completer<void> _gate = Completer<void>();

  void step(double progress) => _onProgress?.call(progress);

  @override
  RemoteBookSourceKind get remoteSourceKind =>
      RemoteBookSourceKind.interconnect;

  @override
  String get remoteLibrarySourceId => kInterconnectRemoteLibrarySourceId;

  @override
  Future<List<RemoteBookInfo>> listRemoteBooks() async => _books;

  @override
  Future<void> getRemoteBook(
    String title,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    fetched.add(title);
    if (!autoFinish) {
      _onProgress = onProgress;
      onProgress?.call(0.1);
      await _gate.future;
    }
    await destination.writeAsBytes(<int>[1]);
  }

  @override
  Future<RemoteBookProgress> remoteBookProgress(String bookKey) async =>
      RemoteBookProgress.empty;

  @override
  Future<void> putRemoteBookProgress(
    String bookKey,
    RemoteBookProgress progress,
  ) async {}
}

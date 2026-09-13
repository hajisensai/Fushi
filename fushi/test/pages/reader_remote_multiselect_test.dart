// BUG-2458：书架多选态点云书（远端占位卡）必须是勾选，不能直接开下载；勾选后
// 经批量栏「下载」一起下；本地三动作（组合 / 标签 / 删除）对纯远端选中集保持
// 禁用。
import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/src/sync/remote_book_client.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'hibiki_remote_multiselect_pp',
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
      'hibiki_remote_multiselect_store',
    );
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
  });

  tearDown(() async {
    await db.close();
  });

  Widget buildApp({required RemoteBookClient client}) => ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
          fushiBooksProvider.overrideWith(
            (ref, language) =>
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

  String safeKey(String title) =>
      sanitizeTtuFilename(title).replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');

  Finder remoteCard(String title) =>
      find.byKey(ValueKey<String>('remote_book_card_${safeKey(title)}'));

  Future<void> enterSelectionMode(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.checklist_outlined));
    await tester.pumpAndSettle();
  }

  bool batchButtonEnabled(WidgetTester tester, String key) =>
      tester.widget<FushiIconButton>(find.byKey(ValueKey<String>(key))).enabled;

  testWidgets('多选态点远端卡 = 勾选，不触发下载；本地动作对纯远端选中集禁用', (WidgetTester tester) async {
    final _CountingRemoteBookClient client =
        _CountingRemoteBookClient(<RemoteBookInfo>[
      const RemoteBookInfo(title: 'Cloud One', hasContent: true),
      const RemoteBookInfo(title: 'Cloud Two', hasContent: true),
    ]);
    await tester.pumpWidget(buildApp(client: client));
    await tester.pumpAndSettle();
    expect(remoteCard('Cloud One'), findsOneWidget);

    await enterSelectionMode(tester);
    await tester.tap(remoteCard('Cloud One'));
    await tester.pump();

    expect(client.fetched, isEmpty, reason: '多选态点云书必须是勾选，不能像 BUG-2458 那样直接开下载');
    expect(
      find.text(t.batch_selected_count(n: 1)),
      findsOneWidget,
      reason: '云书要真进选中集（底栏计数）',
    );
    expect(
      batchButtonEnabled(tester, 'reader_shelf_batch_download'),
      isTrue,
      reason: '选了远端卡，批量「下载」可用',
    );
    expect(
      batchButtonEnabled(tester, 'reader_shelf_batch_delete'),
      isFalse,
      reason: '删除是本地动作，纯远端选中集不能启用',
    );
    expect(
      batchButtonEnabled(tester, 'reader_shelf_batch_combine'),
      isFalse,
      reason: '组合是本地动作，纯远端选中集不能启用',
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(
              ValueKey<String>('remote_book_download_${safeKey('Cloud Two')}')))
          .onPressed,
      isNull,
      reason: '多选态卡内右上角下载按钮必须禁用，否则点到它仍直接下载',
    );
    expect(
      find.byKey(
          ValueKey<String>('remote_book_download_${safeKey('Cloud Two')}')),
      findsOneWidget,
    );

    // 再点一次 = 取消勾选（与本地卡同语义）。
    await tester.tap(remoteCard('Cloud One'));
    await tester.pump();
    expect(find.text(t.batch_selected_count(n: 0)), findsOneWidget);
    expect(client.fetched, isEmpty);
  });

  testWidgets('勾选两本云书 → 批量「下载」把两本都交给下载链并退出多选', (WidgetTester tester) async {
    final _CountingRemoteBookClient client =
        _CountingRemoteBookClient(<RemoteBookInfo>[
      const RemoteBookInfo(title: 'Cloud One', hasContent: true),
      const RemoteBookInfo(title: 'Cloud Two', hasContent: true),
      const RemoteBookInfo(title: 'Cloud Three', hasContent: true),
    ]);
    await tester.pumpWidget(buildApp(client: client));
    await tester.pumpAndSettle();

    await enterSelectionMode(tester);
    await tester.tap(remoteCard('Cloud One'));
    await tester.pump();
    await tester.tap(remoteCard('Cloud Three'));
    await tester.pump();
    expect(find.text(t.batch_selected_count(n: 2)), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('reader_shelf_batch_download')),
    );
    await tester.pump();
    await tester.pump();

    // 串行：第一本挂在闸门上时第二本还没起（审查 #2：批量不得一帧扇出 N 个）。
    expect(client.fetched, <String>['Cloud One'],
        reason: '批量下载逐本串行，第一本没完第二本不起');
    expect(find.byIcon(Icons.checklist_outlined), findsOneWidget,
        reason: '批量下载一开始就退出多选态（入口图标回到「选择」）');
    // 多选态期间卡内右上角下载按钮必须是禁用态（审查 #1），此时已退出多选，
    // 按钮回到可用——用另一张未勾选的卡核对壳与按钮都活着。
    expect(
      tester
          .widget<IconButton>(find.byKey(
              ValueKey<String>('remote_book_download_${safeKey('Cloud Two')}')))
          .onPressed,
      isNotNull,
    );

    // 放行闸门：第一本收尾后才轮到第三本；未勾的 Cloud Two 始终不动。
    // 收尾有真实文件 IO（写盘 + 导入），fake zone 的 pump 送不到，走 runAsync。
    // 收尾有真实文件 IO（写盘 + 导入）也有 fake zone 的计时器/帧回调，两种都要
    // 驱动：runAsync 放真时间、pump 推帧，交替直到第二本起跑。
    client.release();
    for (int i = 0; i < 200 && client.fetched.length < 2; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(client.fetched, <String>['Cloud One', 'Cloud Three'],
        reason: '只下勾选的两本、按目录序串行，未勾的 Cloud Two 不动');
  });
}

/// 记录被拉取的书名；下载体挂在 [release] 之前不结束，好让断言在任务 running
/// 期间做，避免完成后的入库 / 去重把占位卡顶掉。
class _CountingRemoteBookClient implements RemoteBookClient {
  _CountingRemoteBookClient(this._books);
  final List<RemoteBookInfo> _books;
  final List<String> fetched = <String>[];
  final Completer<void> _gate = Completer<void>();

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

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
    await _gate.future;
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

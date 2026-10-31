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
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/src/pages/implementations/hidden_remote_books_page.dart';
import 'package:fushi/src/sync/hidden_remote_books.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/remote_book_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';

import '../helpers/test_platform_services.dart';

/// 反馈 nvlhtczbro：云端（互联）书从书架移除给两个明确的按钮。
///
/// * 「仅从本机移除」：恒有，只在本机隐藏这张占位卡，对端不收任何删除请求；
/// * 「同时从远端删除」：只在 host 允许 client 删除时出现——判据是远端来源为
///   [InterconnectSyncBackend]（已配对 host 对鉴权通过的 peer 开放
///   `DELETE /api/library/books/<id>`）；云盘来源没有删除接口，按钮不出现。
///   二次确认点名是哪台 host 上的哪本书。
///   反馈 R8duEiqRuy（所有者 2026-10-31）：只在对端此刻在线、可达时可点；探测中 /
///   离线 / 配对被拒时照样显示但禁用，并写明原因。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync('fushi_remote_rm_pp');
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
    try {
      pathProviderDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  late FushiDatabase db;
  late AppModel appModel;
  late PreferencesRepository prefs;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory storeDir = Directory.systemTemp.createTempSync(
      'fushi_remote_rm_store',
    );
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
  });

  tearDown(() async {
    await db.close();
  });

  Widget buildApp(RemoteBookClient client) => ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((ref) => appModel),
      fushiBooksProvider.overrideWith(
        (ref, language) => Future<List<MediaItem>>.value(const <MediaItem>[]),
      ),
      srtBooksProvider.overrideWith(
        (ref) => Future<List<SrtBook>>.value(const <SrtBook>[]),
      ),
    ],
    child: TranslationProvider(
      child: MaterialApp(
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

  final Finder card = find.byKey(
    const ValueKey<String>('remote_book_card_Remote_Book'),
  );

  Future<void> openMenu(WidgetTester tester) async {
    await tester.longPress(card);
    await tester.pumpAndSettle();
  }

  testWidgets('云盘来源：只有「仅从本机移除」，点了卡片消失、对端不动，撤销能找回', (WidgetTester tester) async {
    final _FakeCloudClient client = _FakeCloudClient();
    await tester.pumpWidget(buildApp(client));
    await tester.pumpAndSettle();
    expect(card, findsOneWidget);

    await openMenu(tester);
    expect(find.text(t.remote_book_hide_local), findsOneWidget);
    expect(
      find.text(t.remote_book_delete_everywhere),
      findsNothing,
      reason: '云盘来源没有删除接口，不能给「同时从远端删除」',
    );

    await tester.tap(find.text(t.remote_book_hide_local));
    await tester.pumpAndSettle();
    expect(card, findsNothing);
    expect(prefs.hiddenRemoteBooks.map((HiddenRemoteBook h) => h.key), <String>[
      hiddenRemoteBookKey(
        sourceId: client.remoteLibrarySourceId,
        remoteId: client.book.downloadId,
      ),
    ]);
    expect(prefs.hiddenRemoteBooks.single.title, 'Remote Book');
    expect(find.text(t.remote_book_hidden_message), findsOneWidget);

    await tester.tap(find.text(t.undo));
    await tester.pumpAndSettle();
    expect(card, findsOneWidget);
    expect(prefs.hiddenRemoteBooks, isEmpty);
  });

  testWidgets('互联来源：「仅从本机移除」不发删除请求', (WidgetTester tester) async {
    final _FakeInterconnectClient client = _FakeInterconnectClient();
    await tester.pumpWidget(buildApp(client));
    await tester.pumpAndSettle();

    await openMenu(tester);
    await tester.tap(find.text(t.remote_book_hide_local));
    await tester.pumpAndSettle();
    expect(card, findsNothing);
    expect(client.deleted, isEmpty);

    // 落在偏好里（不是页内状态），重进页面照样隐藏。
    expect(prefs.hiddenRemoteBooks, hasLength(1));
  });

  testWidgets('互联来源、对端在线：「同时从远端删除」二次确认点名 host 与书名，确认才删对端', (
    WidgetTester tester,
  ) async {
    await SyncRepository(db).addFushiClientUrl(
      _FakeInterconnectClient.baseUrl,
      deviceName: 'Study-PC',
    );
    final _FakeInterconnectClient client = _FakeInterconnectClient();
    await tester.pumpWidget(buildApp(client));
    await tester.pumpAndSettle();

    await openMenu(tester);
    expect(find.text(t.remote_book_hide_local), findsOneWidget);
    await tester.tap(find.text(t.remote_book_delete_everywhere));
    await tester.pumpAndSettle();

    final Finder confirm = find.byKey(
      const ValueKey<String>('remote_book_delete_confirm'),
    );
    expect(confirm, findsOneWidget);
    expect(
      find.descendant(
        of: confirm,
        matching: find.text(
          t.remote_book_delete_everywhere_confirm(
            name: 'Remote Book',
            host: 'Study-PC',
          ),
        ),
      ),
      findsOneWidget,
    );

    // 取消：对端不动。
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();
    expect(client.deleted, isEmpty);
    expect(card, findsOneWidget);

    await openMenu(tester);
    await tester.tap(find.text(t.remote_book_delete_everywhere));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: confirm,
        matching: find.text(t.remote_book_delete_everywhere),
      ),
    );
    await tester.pumpAndSettle();
    expect(client.deleted, <String>['Remote Book']);
    expect(card, findsNothing);
    expect(prefs.hiddenRemoteBooks, isEmpty, reason: '从远端删除不走本机隐藏清单');
  });

  // ── 远端删除的可用性（反馈 R8duEiqRuy，所有者 2026-10-31 拍板）────────

  Finder confirmDialog() =>
      find.byKey(const ValueKey<String>('remote_book_delete_confirm'));

  testWidgets('互联来源、对端离线：「同时从远端删除」照样显示但禁用并写明原因，点了不弹确认', (
    WidgetTester tester,
  ) async {
    final _FakeInterconnectClient client = _FakeInterconnectClient()
      ..reachability = () async => RemoteSourceReachability.unreachable;
    await tester.pumpWidget(buildApp(client));
    await tester.pumpAndSettle();

    await openMenu(tester);
    expect(client.probes, 1, reason: '菜单打开即重探对端，不信缓存会话');
    expect(find.text(t.remote_book_delete_everywhere), findsOneWidget);
    expect(find.text(t.remote_delete_host_offline), findsOneWidget);

    await tester.tap(
      find.text(t.remote_book_delete_everywhere),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(confirmDialog(), findsNothing);
    expect(client.deleted, isEmpty);
    expect(card, findsOneWidget);
    // 「仅从本机移除」不依赖对端在线，照常可用。
    expect(find.text(t.remote_book_hide_local), findsOneWidget);
  });

  testWidgets('互联来源、配对被拒：禁用并提示重新配对', (WidgetTester tester) async {
    final _FakeInterconnectClient client = _FakeInterconnectClient()
      ..reachability = () async =>
          RemoteSourceReachability.credentialRejected;
    await tester.pumpWidget(buildApp(client));
    await tester.pumpAndSettle();

    await openMenu(tester);
    expect(find.text(t.remote_delete_host_pairing_rejected), findsOneWidget);
    await tester.tap(
      find.text(t.remote_book_delete_everywhere),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(confirmDialog(), findsNothing);
    expect(client.deleted, isEmpty);
  });

  testWidgets('探测进行中禁用（「正在检查」），确认在线后才可点并进入二次确认', (WidgetTester tester) async {
    final Completer<RemoteSourceReachability> pending =
        Completer<RemoteSourceReachability>();
    final _FakeInterconnectClient client = _FakeInterconnectClient()
      ..reachability = () => pending.future;
    await tester.pumpWidget(buildApp(client));
    await tester.pumpAndSettle();

    await openMenu(tester);
    expect(find.text(t.remote_delete_host_checking), findsOneWidget);
    await tester.tap(
      find.text(t.remote_book_delete_everywhere),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(confirmDialog(), findsNothing, reason: '结论出来前不能放行删除');

    pending.complete(RemoteSourceReachability.reachable);
    await tester.pumpAndSettle();
    expect(find.text(t.remote_delete_host_checking), findsNothing);
    await tester.tap(find.text(t.remote_book_delete_everywhere));
    await tester.pumpAndSettle();
    expect(confirmDialog(), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: confirmDialog(),
        matching: find.text(t.remote_book_delete_everywhere),
      ),
    );
    await tester.pumpAndSettle();
    expect(client.deleted, <String>['Remote Book']);
    expect(card, findsNothing);
  });

  testWidgets('云盘来源不探测对端（没有删除能力，不发网络请求）', (WidgetTester tester) async {
    final _FakeCloudClient client = _FakeCloudClient();
    await tester.pumpWidget(buildApp(client));
    await tester.pumpAndSettle();
    await openMenu(tester);
    expect(find.text(t.remote_delete_host_checking), findsNothing);
    expect(find.text(t.remote_book_delete_everywhere), findsNothing);
  });

  test('「仅从本机移除」清单是设备本地偏好：不随备份 / 同步带到别的设备', () {
    expect(
      SyncRepository.deviceLocalPrefKeys,
      contains('hidden_remote_books'),
      reason: '「仅从本机」漂到另一台设备会让那边的同一份远端书也被隐藏',
    );
  });

  // ── 找回列表（所有者 2026-10-10 拍板）──────────────────────────────

  Future<void> openHiddenList(
    WidgetTester tester,
    RemoteBookClient client,
  ) async {
    Navigator.of(tester.element(find.byType(ReaderFushiHistoryPage))).push(
      MaterialPageRoute<void>(
        builder: (_) => HiddenRemoteBooksPage(
          prefs: prefs,
          remoteClientLoader: () async => client,
          sourceHostResolver: (RemoteBookClient c) =>
              remoteBookSourceHost(db, c),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('找回列表：按来源分组列出，「恢复」后书重新出现在书架上', (WidgetTester tester) async {
    final _FakeInterconnectClient client = _FakeInterconnectClient();
    await tester.pumpWidget(buildApp(client));
    await tester.pumpAndSettle();
    await openMenu(tester);
    await tester.tap(find.text(t.remote_book_hide_local));
    await tester.pumpAndSettle();
    expect(card, findsNothing);

    expect(
      prefs.hiddenRemoteBooks.single.sourceHost,
      _FakeInterconnectClient.baseUrl,
      reason: '互联条目记下是哪台对端（没有 hostId 时用地址）',
    );

    await openHiddenList(tester, client);
    expect(
      find.text(
        t.remote_hidden_books_source_interconnect(name: '192.168.1.20'),
      ),
      findsOneWidget,
      reason: '没有配对设备名时用地址主机名作分组标题',
    );
    expect(find.text('Remote Book'), findsOneWidget);
    final Finder restore = find.byKey(
      const ValueKey<String>(
        'hidden_remote_book_restore_interconnect_Remote_20Book',
      ),
    );
    expect(restore, findsOneWidget);
    await tester.tap(restore);
    await tester.pumpAndSettle();
    expect(prefs.hiddenRemoteBooks, isEmpty);
    expect(
      find.byKey(const ValueKey<String>('hidden_remote_books_empty')),
      findsOneWidget,
    );

    Navigator.of(tester.element(find.byType(HiddenRemoteBooksPage))).pop();
    await tester.pumpAndSettle();
    expect(card, findsOneWidget, reason: '恢复后占位卡回到书架');
    expect(client.deleted, isEmpty);
  });

  // 两个分组时设置壳会画分组跳转条（同名标题出现不止一次），故用 findsWidgets。
  testWidgets('找回列表：远端已不存在的书只给「清除记录」，「全部恢复」清空清单', (WidgetTester tester) async {
    final _FakeInterconnectClient client = _FakeInterconnectClient();
    await prefs.setHiddenRemoteBooks(const <HiddenRemoteBook>[
      HiddenRemoteBook(
        sourceId: 'interconnect',
        remoteId: 'Gone Book',
        title: 'Gone Book',
        sourceHost: _FakeInterconnectClient.baseUrl,
        sourceLabel: 'Study-PC',
      ),
      HiddenRemoteBook(
        sourceId: 'interconnect',
        remoteId: 'Remote Book',
        title: 'Remote Book',
        sourceHost: _FakeInterconnectClient.baseUrl,
        sourceLabel: 'Study-PC',
      ),
      HiddenRemoteBook(
        sourceId: 'cloud:webDav',
        remoteId: 'Cloud Book',
        title: 'Cloud Book',
      ),
    ]);
    await tester.pumpWidget(buildApp(client));
    await tester.pumpAndSettle();
    expect(card, findsNothing);
    await openHiddenList(tester, client);

    expect(
      find.text(t.remote_hidden_books_source_interconnect(name: 'Study-PC')),
      findsWidgets,
    );
    expect(
      find.text(t.remote_hidden_books_source_cloud(name: 'WebDAV')),
      findsWidgets,
    );
    // 远端书目里没有 Gone Book → 标「远端已不存在」，动作是「清除记录」。
    expect(find.text(t.remote_hidden_books_missing), findsOneWidget);
    final Finder forget = find.byKey(
      const ValueKey<String>(
        'hidden_remote_book_forget_interconnect_Gone_20Book',
      ),
    );
    expect(forget, findsOneWidget);
    expect(
      find.byKey(
        const ValueKey<String>(
          'hidden_remote_book_restore_interconnect_Gone_20Book',
        ),
      ),
      findsNothing,
    );
    await tester.tap(forget);
    await tester.pumpAndSettle();
    expect(find.text('Gone Book'), findsNothing);
    expect(prefs.hiddenRemoteBooks, hasLength(2));

    await tester.tap(
      find.byKey(
        const ValueKey<String>('hidden_remote_books_restore_all_button'),
      ),
    );
    await tester.pumpAndSettle();
    expect(prefs.hiddenRemoteBooks, isEmpty);
    Navigator.of(tester.element(find.byType(HiddenRemoteBooksPage))).pop();
    await tester.pumpAndSettle();
    expect(card, findsOneWidget);
  });

  testWidgets('另一台对端上隐藏的书：本机书架照常显示，找回列表不误判「远端已不存在」', (
    WidgetTester tester,
  ) async {
    final _FakeInterconnectClient client = _FakeInterconnectClient();
    await prefs.setHiddenRemoteBooks(const <HiddenRemoteBook>[
      // 同一个 downloadId，但是在另一台 host 上隐藏的。
      HiddenRemoteBook(
        sourceId: 'interconnect',
        remoteId: 'Remote Book',
        title: 'Remote Book',
        sourceHost: 'host-a-id',
        sourceLabel: 'Host-A',
      ),
      HiddenRemoteBook(
        sourceId: 'interconnect',
        remoteId: 'Only On A',
        title: 'Only On A',
        sourceHost: 'host-a-id',
        sourceLabel: 'Host-A',
      ),
    ]);
    await tester.pumpWidget(buildApp(client));
    await tester.pumpAndSettle();
    expect(card, findsOneWidget, reason: 'A 机上的隐藏不该牵连当前对端的同名书');

    await openHiddenList(tester, client);
    expect(
      find.text(t.remote_hidden_books_source_interconnect(name: 'Host-A')),
      findsOneWidget,
    );
    expect(
      find.text(t.remote_hidden_books_missing),
      findsNothing,
      reason: '当前对端的书目不能拿来判 A 机的书已不存在',
    );
  });

  test('旧版只存键串的清单读进来不丢', () {
    final List<HiddenRemoteBook> books = decodeHiddenRemoteBooks(
      '["interconnect/Remote%20Book","cloud:webDav/a%2Fb"]',
    );
    expect(
      books.map((HiddenRemoteBook h) => (h.sourceId, h.remoteId, h.sourceHost)),
      <(String, String, String?)>[
        ('interconnect', 'Remote Book', null),
        ('cloud:webDav', 'a/b', null),
      ],
    );
    expect(
      isRemoteBookHidden(
        books,
        sourceId: 'interconnect',
        sourceHost: 'any-host',
        remoteId: 'Remote Book',
      ),
      isTrue,
      reason: '旧条目不分对端，保持升级前行为',
    );
  });
}

class _FakeCloudClient implements RemoteBookClient {
  final RemoteBookInfo book = const RemoteBookInfo(
    title: 'Remote Book',
    hasContent: true,
  );

  @override
  RemoteBookSourceKind get remoteSourceKind => RemoteBookSourceKind.cloud;

  @override
  String get remoteLibrarySourceId => 'cloud:test';

  @override
  Future<List<RemoteBookInfo>> listRemoteBooks() async => <RemoteBookInfo>[
    book,
  ];

  @override
  Future<void> getRemoteBook(
    String title,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {}

  @override
  Future<RemoteBookProgress> remoteBookProgress(String bookKey) async =>
      RemoteBookProgress.empty;

  @override
  Future<void> putRemoteBookProgress(
    String bookKey,
    RemoteBookProgress progress,
  ) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeInterconnectClient extends InterconnectSyncBackend {
  _FakeInterconnectClient()
    : super.withProbe((String url, String token) async => true);

  static const String baseUrl = 'https://192.168.1.20:8766';

  final List<String> deleted = <String>[];

  /// 菜单打开时的可达性探测结论；默认在线。
  Future<RemoteSourceReachability> Function() reachability = () async =>
      RemoteSourceReachability.reachable;
  int probes = 0;

  @override
  Future<RemoteSourceReachability> probeHostReachability() {
    probes++;
    return reachability();
  }

  @override
  String? get resolvedHostBaseUrl => baseUrl;

  @override
  Future<List<RemoteBookInfo>> listRemoteBooks() async => <RemoteBookInfo>[
    if (!deleted.contains('Remote Book'))
      const RemoteBookInfo(title: 'Remote Book', hasContent: true),
  ];

  @override
  Future<List<RemoteAudiobookInfo>> listRemoteAudiobooks() async =>
      const <RemoteAudiobookInfo>[];

  @override
  Future<void> deleteRemoteBook(String title) async => deleted.add(title);
}

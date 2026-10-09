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
/// * 「彻底删除」：只在 host 允许 client 删除时出现——判据是远端来源为
///   [InterconnectSyncBackend]（已配对 host 对鉴权通过的 peer 开放
///   `DELETE /api/library/books/<id>`）；云盘来源没有删除接口，按钮不出现。
///   二次确认点名是哪台 host 上的哪本书。
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
      reason: '云盘来源没有删除接口，不能给「彻底删除」',
    );

    await tester.tap(find.text(t.remote_book_hide_local));
    await tester.pumpAndSettle();
    expect(card, findsNothing);
    expect(prefs.hiddenRemoteBooks, <String>{
      hiddenRemoteBookKey(
        sourceId: client.remoteLibrarySourceId,
        book: client.book,
      ),
    });
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

  testWidgets('互联来源：「彻底删除」二次确认点名 host 与书名，确认才删对端', (WidgetTester tester) async {
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
    expect(prefs.hiddenRemoteBooks, isEmpty, reason: '彻底删除不走本机隐藏清单');
  });

  test('「仅从本机移除」清单是设备本地偏好：不随备份 / 同步带到别的设备', () {
    expect(
      SyncRepository.deviceLocalPrefKeys,
      contains('hidden_remote_books'),
      reason: '「仅从本机」漂到另一台设备会让那边的同一份远端书也被隐藏',
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

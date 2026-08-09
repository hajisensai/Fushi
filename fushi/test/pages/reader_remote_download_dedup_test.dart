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
import 'package:fushi/src/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/remote_book_client.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi/src/sync/ttu_filename.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_remote_book_dl_pp');
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
    final Directory storeDir =
        Directory.systemTemp.createTempSync('hibiki_remote_book_dl_store');
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

  testWidgets('#6 远端与本地同 bookKey 的书在配对区被去重隐藏', (WidgetTester tester) async {
    // 本地已有「Dup Book」（同 bookKey）。
    final String key = sanitizeTtuFilename('Dup Book');
    final Directory extractDir =
        Directory('${pathProviderDir.path}/dup_extract')..createSync();
    await db.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: key,
      title: 'Dup Book',
      epubPath: '${extractDir.path}/x.epub',
      extractDir: extractDir.path,
      chapterCount: 1,
      chaptersJson: '["a"]',
      importedAt: 0,
    ));

    await tester.pumpWidget(buildApp(
      client: _ListFakeRemoteBookClient(<RemoteBookInfo>[
        const RemoteBookInfo(title: 'Dup Book', hasContent: true),
        const RemoteBookInfo(title: 'Only Remote Book', hasContent: true),
      ]),
    ));
    await tester.pumpAndSettle();

    expect(
      find.byKey(ValueKey<String>('remote_book_card_${safeKey('Dup Book')}')),
      findsNothing,
    );
    expect(
      find.byKey(
          ValueKey<String>('remote_book_card_${safeKey('Only Remote Book')}')),
      findsOneWidget,
    );
  });

  testWidgets('#3 远端书下载中显示进度徽章（进行中反馈），下载按钮被替换', (WidgetTester tester) async {
    final _GatedFakeRemoteBookClient client = _GatedFakeRemoteBookClient();
    await tester.pumpWidget(buildApp(client: client));
    await tester.pumpAndSettle();

    final String key = safeKey('Gated Book');
    await tester.tap(find.byKey(ValueKey<String>('remote_book_download_$key')));
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(ValueKey<String>('remote_book_downloading_$key')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey<String>('remote_book_download_$key')),
      findsNothing,
    );

    client.completer.complete();
    await tester.pump();
  });
}

class _ListFakeRemoteBookClient implements RemoteBookClient {
  _ListFakeRemoteBookClient(this._books);
  final List<RemoteBookInfo> _books;

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

class _GatedFakeRemoteBookClient implements RemoteBookClient {
  final Completer<void> completer = Completer<void>();

  @override
  RemoteBookSourceKind get remoteSourceKind =>
      RemoteBookSourceKind.interconnect;

  @override
  String get remoteLibrarySourceId => kInterconnectRemoteLibrarySourceId;

  @override
  Future<List<RemoteBookInfo>> listRemoteBooks() async => <RemoteBookInfo>[
        const RemoteBookInfo(title: 'Gated Book', hasContent: true),
      ];

  @override
  Future<void> getRemoteBook(
    String title,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    onProgress?.call(0.3);
    await completer.future;
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

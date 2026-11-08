import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/remote_audiobook_revision.dart';
import 'package:fushi/src/sync/remote_book_client.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:path/path.dart' as p;

import '../helpers/test_platform_services.dart';

/// 互联有声书「对端有更新」：本机下载时记下 host 清单的 `contentRevision`，之后清单里
/// 的值变了（host 上换过音频 / 字幕）→ 书卡副行提示「对端有更新」，菜单里「重新下载」
/// 改叫「下载更新」排第一；点它整本重新拉取（`fresh`），落地后记下新版本、提示消失。
const String _uid = 'srt-solo';

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  setUpAll(() {
    temp = Directory.systemTemp.createTempSync('fushi_ab_update_pp');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => temp.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  late FushiDatabase db;
  late FushiDatabase hostDb;
  late AppModel appModel;
  late PreferencesRepository prefs;
  late ProviderContainer container;
  late SrtBook localBook;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    hostDb = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory storeDir = Directory.systemTemp.createTempSync(
      'fushi_ab_update_store',
    );
    appModel = _AppModel(storeDir)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
    appModel.populateMediaTypes();
    appModel.populateMediaSources();

    // 本机：之前从对端下载的纯字幕书（音频在盘上，不是断链态）。
    final Directory local = Directory(p.join(temp.path, 'local'))
      ..createSync(recursive: true);
    final File localAudio = File(p.join(local.path, 'solo01.mp3'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
    final File localSrt = File(p.join(local.path, 'solo.srt'))
      ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\n一行目\n');
    await db.upsertSrtBook(
      SrtBooksCompanion.insert(
        uid: _uid,
        title: 'Solo Cast',
        audioPathsJson: Value(jsonEncode(<String>[localAudio.path])),
        srtPath: localSrt.path,
        importedAt: 1,
      ),
    );
    localBook = (await SrtBookRepository(db).findByUid(_uid))!;

    // host：同一本书，字幕换成了新版（下载更新后本机应拿到它）。
    final Directory host = Directory(p.join(temp.path, 'host'))
      ..createSync(recursive: true);
    final File hostAudio = File(p.join(host.path, 'solo01.mp3'))
      ..writeAsBytesSync(<int>[1, 2, 3, 4]);
    final File hostSrt = File(p.join(host.path, 'solo.srt'))
      ..writeAsStringSync(
        '1\n00:00:00,000 --> 00:00:01,000\n一行目。\n\n'
        '2\n00:00:01,000 --> 00:00:02,000\n二行目。\n',
      );
    await hostDb.upsertSrtBook(
      SrtBooksCompanion.insert(
        uid: _uid,
        title: 'Solo Cast',
        audioPathsJson: Value(jsonEncode(<String>[hostAudio.path])),
        srtPath: hostSrt.path,
        importedAt: 1,
      ),
    );
    await hostDb.replaceCuesForBook(_uid, <AudioCuesCompanion>[
      for (final (int i, String text) in <(int, String)>[
        (0, '一行目。'),
        (1, '二行目。'),
      ])
        AudioCuesCompanion.insert(
          bookKey: _uid,
          chapterHref: SrtParser.defaultChapter,
          sentenceIndex: i,
          textFragmentId: 'f$i',
          cueText: text,
          startMs: i * 1000,
          endMs: (i + 1) * 1000,
          audioFileIndex: 0,
        ),
    ]);

    container = ProviderContainer(
      overrides: <Override>[
        appProvider.overrideWith((ref) => appModel),
        fushiBooksProvider.overrideWith(
          (ref, language) => Future<List<MediaItem>>.value(const <MediaItem>[]),
        ),
        srtBooksProvider.overrideWith(
          (ref) => Future<List<SrtBook>>.value(<SrtBook>[localBook]),
        ),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    await hostDb.close();
  });

  Widget host(Widget body) => UncontrolledProviderScope(
    container: container,
    child: TranslationProvider(
      child: MaterialApp(
        builder: (BuildContext context, Widget? child) =>
            child ?? const SizedBox.shrink(),
        home: Scaffold(body: body),
      ),
    ),
  );

  ReaderFushiHistoryPage buildPage(RemoteBookClient client) =>
      ReaderFushiHistoryPage(
        remoteBookClientLoader: () async => client,
        remoteBookDownloadDestination: (RemoteBookInfo book) async =>
            File(p.join(temp.path, '${book.title.hashCode}.epub')),
        remoteBookImporter: (File file) async => null,
      );

  Future<void> seedRecord(String revision) =>
      prefs.setInterconnectAudiobookRevision(
        remoteAudiobookRevisionKeyForSrt(_uid),
        // 测试 client 没有配对地址：对端身份为空串。
        RemoteAudiobookRevisionRecord(
          sourceId: 'interconnect|',
          revision: revision,
        ),
      );

  final Finder updateMeta = find.byKey(
    const ValueKey<String>('shelf_meta_audiobook_update'),
  );

  testWidgets('host 版本与下载时相同：不提示更新', (WidgetTester tester) async {
    await seedRecord('r1-same');
    final _FakeHost client = _FakeHost(hostDb, revision: 'r1-same');

    await tester.pumpWidget(host(buildPage(client)));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('srt_entry_$_uid')),
      findsOneWidget,
    );
    expect(updateMeta, findsNothing);
  });

  testWidgets('host 版本变了：副行提示「对端有更新」，菜单「下载更新」整本重拉并记下新版本', (
    WidgetTester tester,
  ) async {
    await seedRecord('r1-old');
    final _FakeHost client = _FakeHost(hostDb, revision: 'r1-new');

    await tester.pumpWidget(host(buildPage(client)));
    await tester.pumpAndSettle();

    expect(updateMeta, findsOneWidget);
    expect(
      find.textContaining(t.remote_book_audiobook_update_available),
      findsOneWidget,
    );

    await tester.longPress(
      find.byKey(const ValueKey<String>('srt_entry_$_uid')),
    );
    await tester.pumpAndSettle();
    final Finder download = find.text(t.remote_book_audiobook_update_download);
    expect(download, findsOneWidget);
    expect(
      find.text(t.remote_book_audiobook_redownload),
      findsNothing,
      reason: '有更新时同一项改叫「下载更新」，不并列两个整本下载',
    );

    final InterconnectDownloadManager manager = container.read(
      interconnectDownloadManagerProvider,
    );
    final String taskId = InterconnectDownloadManager.srtAudiobookTaskId(_uid);
    await tester.runAsync(() async {
      await tester.tap(download);
      for (int i = 0; i < 200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final InterconnectDownloadStatus? status = manager
            .taskFor(taskId)
            ?.status;
        if (status == InterconnectDownloadStatus.completed ||
            status == InterconnectDownloadStatus.failed) {
          break;
        }
      }
    });
    await tester.pumpAndSettle();

    expect(manager.taskFor(taskId)?.error, isNull);
    expect(client.fetches, <bool>[true], reason: '下载更新 = 整本重拉（fresh）');
    final List<AudioCueRow> cues = await db.getCuesForBook(_uid);
    expect(cues.map((AudioCueRow r) => r.cueText), <String>[
      '一行目。',
      '二行目。',
    ], reason: '本机拿到 host 的新字幕');
    expect(
      prefs
          .interconnectAudiobookRevisions[remoteAudiobookRevisionKeyForSrt(
            _uid,
          )]
          ?.revision,
      'r1-new',
    );
    // 落地后书架重算远端状态（真 IO：读库 / 偏好），在 runAsync 里让它跑完再看。
    for (int i = 0; i < 50 && updateMeta.evaluate().isNotEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(updateMeta, findsNothing, reason: '落地后提示消失');
  });

  test('判据：没记过 / 换了对端 / 旧 host 不报版本都不提示', () {
    const RemoteAudiobookRevisionRecord rec = RemoteAudiobookRevisionRecord(
      sourceId: 'interconnect|host-a',
      revision: 'r1-a',
    );
    expect(
      remoteAudiobookUpdateAvailable(
        stored: rec,
        sourceId: 'interconnect|host-a',
        remoteRevision: 'r1-b',
      ),
      isTrue,
    );
    expect(
      remoteAudiobookUpdateAvailable(
        stored: null,
        sourceId: 'interconnect|host-a',
        remoteRevision: 'r1-b',
      ),
      isFalse,
    );
    expect(
      remoteAudiobookUpdateAvailable(
        stored: rec,
        sourceId: 'interconnect|host-b',
        remoteRevision: 'r1-b',
      ),
      isFalse,
    );
    expect(
      remoteAudiobookUpdateAvailable(
        stored: rec,
        sourceId: 'interconnect|host-a',
        remoteRevision: null,
      ),
      isFalse,
    );
    final Map<String, RemoteAudiobookRevisionRecord> decoded =
        decodeRemoteAudiobookRevisions(
          encodeRemoteAudiobookRevisions(
            <String, RemoteAudiobookRevisionRecord>{'srt:x': rec},
          ),
        );
    expect(decoded['srt:x']?.revision, 'r1-a');
    expect(decodeRemoteAudiobookRevisions('not json'), isEmpty);
    expect(
      remoteAudiobookUpdateKeys(
        bookRefetch: const <String, String>{'local-key': 'host-key'},
        srtRefetchUids: const <String>['u1', 'u2'],
        remoteRevisions: const <String, String>{
          'host-key': 'r1-b',
          'u1': 'r1-a',
          'u2': 'r1-z',
        },
        stored: const <String, RemoteAudiobookRevisionRecord>{
          'book:local-key': rec,
          'srt:u1': rec,
        },
        sourceId: 'interconnect|host-a',
      ),
      <String>{'book:local-key'},
    );
  });
}

/// 互联后端假实现：清单报 [revision]；下载时现场从 host 库导出一份真包。
class _FakeHost extends InterconnectSyncBackend {
  _FakeHost(this.hostDb, {required this.revision})
    : super.withProbe((String url, String token) async => true);

  final FushiDatabase hostDb;
  String revision;
  final List<bool> fetches = <bool>[];

  @override
  Future<List<RemoteBookInfo>> listRemoteBooks() async =>
      const <RemoteBookInfo>[];

  @override
  Future<List<RemoteAudiobookInfo>> listRemoteAudiobooks() async =>
      <RemoteAudiobookInfo>[
        RemoteAudiobookInfo(
          bookKey: '',
          uid: _uid,
          title: 'Solo Cast',
          contentRevision: revision,
        ),
      ];

  @override
  Future<void> getRemoteAudiobook(
    String bookKey,
    File dest, {
    void Function(double progress)? onProgress,
    bool fresh = false,
  }) async {
    fetches.add(fresh);
    dest.parent.createSync(recursive: true);
    await SyncAssetPackageService(
      db: hostDb,
    ).exportAudioDatabasePackage(srtBookUid: bookKey, outputFile: dest);
  }
}

/// 下载落地要 `appModel.appDirectory`（有声书根 `<app>/audiobooks`）。
class _AppModel extends AppModel {
  _AppModel(this._dir) : super(testPlatformServices());

  final Directory _dir;

  @override
  Directory get appDirectory => _dir;
}

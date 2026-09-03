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
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/remote_book_client.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi/src/sync/ttu_filename.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// BUG-1693 批审计 P1（BUG-1561 书侧补齐）：远端书 / 纯 SRT 有声书下载此前挂在书架页
/// State（`_downloadingBooks`），失败反馈只有一条被 `if (!mounted) return;` 守着的
/// SnackBar——用户点完下载切走页面，失败就永远没人知道。修复后任务挂 app 级
/// [InterconnectDownloadManager]，占位卡按任务状态渲染进度环 / 失败角标：失败角标是
/// 离页后失败态的**唯一恒定出口**，重进页面照样看得到。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_remote_dl_badge_pp');
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
  late ProviderContainer container;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory storeDir =
        Directory.systemTemp.createTempSync('hibiki_remote_dl_badge_store');
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
    container = ProviderContainer(overrides: <Override>[
      appProvider.overrideWith((ref) => appModel),
      fushiBooksProvider.overrideWith(
        (ref, language) => Future<List<MediaItem>>.value(const <MediaItem>[]),
      ),
      srtBooksProvider.overrideWith(
        (ref) => Future<List<SrtBook>>.value(const <SrtBook>[]),
      ),
    ]);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  // 外置 ProviderContainer：页面卸载（模拟用户离页）后 app 级下载管理器必须继续
  // 活着——这正是被测语义，所以不能用随 pumpWidget 重建的 ProviderScope。
  Widget host(Widget body) => UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            builder: (BuildContext context, Widget? child) =>
                child ?? const SizedBox.shrink(),
            home: Scaffold(
              body: body,
            ),
          ),
        ),
      );

  ReaderFushiHistoryPage buildPage(RemoteBookClient client) =>
      ReaderFushiHistoryPage(
        remoteBookClientLoader: () async => client,
        remoteBookDownloadDestination: (RemoteBookInfo book) async =>
            File('${pathProviderDir.path}/${book.title.hashCode}.epub'),
        remoteBookImporter: (File file) async => null,
      );

  String safeKey(String title) =>
      sanitizeTtuFilename(title).replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');

  testWidgets('P1 主诉：下载失败发生在离页后，重进页面失败角标仍可见（tooltip 带友好原因）',
      (WidgetTester tester) async {
    final _GatedFailingRemoteBookClient client =
        _GatedFailingRemoteBookClient();
    final String key = safeKey('Doomed Book');

    await tester.pumpWidget(host(buildPage(client)));
    await tester.pumpAndSettle();

    // 点下载 → 任务进管理器，占位卡显示进度环。
    await tester.tap(find.byKey(ValueKey<String>('remote_book_download_$key')));
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(ValueKey<String>('remote_book_downloading_$key')),
      findsOneWidget,
    );

    // 用户离页（页面 State dispose）——任务活在 app 级管理器里照跑。
    await tester.pumpWidget(host(const SizedBox()));
    await tester.pump();

    // 此刻下载才失败：旧实现的 SnackBar 被 !mounted 吃掉、失败凭空蒸发。
    client.gate.completeError(const SocketException('connection refused'));
    await tester.pump();
    await tester.pump();

    final InterconnectDownloadTask? task = container
        .read(interconnectDownloadManagerProvider)
        .taskFor(InterconnectDownloadManager.bookTaskId('Doomed Book'));
    expect(task, isNotNull, reason: '任务必须活在 app 级管理器里，不随页面 dispose 消失');
    expect(task!.status, InterconnectDownloadStatus.failed);
    expect(task.error, t.sync_err_network,
        reason: '角标 tooltip 数据源须是本地化友好文案，不是原始异常文本');

    // 重进页面：失败角标是恒定出口，重进照样看得到。
    await tester.pumpWidget(host(buildPage(client)));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey<String>('remote_book_download_failed_$key')),
      findsOneWidget,
      reason: 'BUG-1561 书侧：失败态必须落在占位卡上，而不是只存在于没人看见的 SnackBar',
    );
    expect(
      find.byTooltip('${t.remote_book_download_failed}: ${t.sync_err_network}'),
      findsOneWidget,
    );
    // 离页期间没有任何 SnackBar 出口，也不该在重进时补弹。
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('纯 SRT 有声书占位卡下载失败 → 失败角标（下载按钮被顶掉，可再点重试）',
      (WidgetTester tester) async {
    final _FakeInterconnectRemoteClient client =
        _FakeInterconnectRemoteClient();
    final String key = safeKey('Solo Cast');

    await tester.pumpWidget(host(buildPage(client)));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey<String>('remote_srt_card_$key')),
      findsOneWidget,
      reason: '前置：standalone SRT 占位卡在场',
    );

    final InterconnectDownloadManager manager =
        container.read(interconnectDownloadManagerProvider);
    final String taskId =
        InterconnectDownloadManager.srtAudiobookTaskId('srt-uid-1');
    // getTemporaryDirectory / 临时文件删除是真实 IO，须在 runAsync 里驱动。
    await tester.runAsync(() async {
      await tester
          .tap(find.byKey(ValueKey<String>('remote_srt_download_$key')));
      for (int i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (manager.taskFor(taskId)?.status ==
            InterconnectDownloadStatus.failed) {
          break;
        }
      }
    });
    await tester.pump();

    expect(manager.taskFor(taskId)?.status, InterconnectDownloadStatus.failed);
    expect(
      find.byKey(ValueKey<String>('remote_srt_download_failed_$key')),
      findsOneWidget,
      reason: 'SRT 占位卡的失败态同样走管理器角标，不再是页面 State 里的一次性 SnackBar',
    );
    expect(
      find.byKey(ValueKey<String>('remote_srt_download_$key')),
      findsNothing,
      reason: '失败角标替换下载按钮的位置（卡片 onTap 仍可重试）',
    );
    // 冲掉在场 SnackBar 的 4s 定时器，避免测试结束时挂着 pending timer。
    await tester.pumpAndSettle();
  });
}

/// 清单可用、下载卡在闸门上的假 client：测试在页面 dispose 后才 completeError，
/// 复现「失败发生在离页后」的原始路径。
class _GatedFailingRemoteBookClient implements RemoteBookClient {
  final Completer<void> gate = Completer<void>();

  @override
  RemoteBookSourceKind get remoteSourceKind =>
      RemoteBookSourceKind.interconnect;

  @override
  String get remoteLibrarySourceId => kInterconnectRemoteLibrarySourceId;

  @override
  Future<List<RemoteBookInfo>> listRemoteBooks() async => <RemoteBookInfo>[
        const RemoteBookInfo(title: 'Doomed Book', hasContent: true),
      ];

  @override
  Future<void> getRemoteBook(
    String title,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    onProgress?.call(0.2);
    await gate.future;
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

/// 覆盖清单/下载原语的互联后端假实现（standalone SRT 占位卡只对
/// [InterconnectSyncBackend] 类型开放，普通 [RemoteBookClient] fake 进不了这条路）。
class _FakeInterconnectRemoteClient extends InterconnectSyncBackend {
  _FakeInterconnectRemoteClient()
      : super.withProbe((String url, String token) async => true);

  @override
  Future<List<RemoteBookInfo>> listRemoteBooks() async =>
      const <RemoteBookInfo>[];

  @override
  Future<List<RemoteAudiobookInfo>> listRemoteAudiobooks() async =>
      const <RemoteAudiobookInfo>[
        RemoteAudiobookInfo(bookKey: '', uid: 'srt-uid-1', title: 'Solo Cast'),
      ];

  @override
  Future<void> getRemoteAudiobook(
    String bookKey,
    File dest, {
    void Function(double progress)? onProgress,
  }) async {
    throw const SocketException('connection reset by peer');
  }
}

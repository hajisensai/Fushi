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
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/remote_book_client.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart' show syncInProgress;
import 'package:fushi/src/sync/ttu_filename.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// BUG-1693 批审计 P1/P3：书架下拉刷新对「远端清单拉取失败」必须给可见反馈。
///
/// - P1：`_loadRemoteBooks` 失败置 `failed:true`，但 `_pullToRefreshBooks` 此前不
///   消费它——显式下拉失败与成功在 UI 上一模一样（指示器转一圈默默收起）。修复对齐
///   视频侧 `_pullToRefresh`：失败弹 `t.remote_book_list_failed` SnackBar。
/// - P3：standalone SRT 有声书清单单独失败此前被降级成「空列表」——占位卡静默
///   消失，与「对端真没有」不可区分。修复把它记进 `srtFailed` 汇入同一条失败提示，
///   同时**不**连坐隐藏拉取成功的书占位卡。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_remote_refresh_pp');
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
        Directory.systemTemp.createTempSync('hibiki_remote_refresh_store');
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
  });

  tearDown(() async {
    syncInProgress.value = false;
    await db.close();
  });

  // 书架全空时页面走 buildPlaceholder()（无 RefreshIndicator）；给一本本地 SRT
  // 书让主网格 + 下拉刷新入口在场——「远端拉取失败」的用户场景本就是「本地有库、
  // 远端刷不出来」。
  List<SrtBook> localSrtBooks() => <SrtBook>[
        SrtBook()
          ..uid = 'local-srt-uid'
          ..title = 'Local Audiobook'
          ..srtPath = '${pathProviderDir.path}/local.srt'
          ..importedAt = 0,
      ];

  Widget buildApp(RemoteBookClient client) => ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
          fushiBooksProvider.overrideWith(
            (ref, language) =>
                Future<List<MediaItem>>.value(const <MediaItem>[]),
          ),
          srtBooksProvider.overrideWith(
            (ref) => Future<List<SrtBook>>.value(localSrtBooks()),
          ),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            builder: (BuildContext context, Widget? child) =>
                child ?? const SizedBox.shrink(),
            home: Scaffold(
              body: ReaderFushiHistoryPage(
                remoteBookClientLoader: () async => client,
              ),
            ),
          ),
        ),
      );

  String safeKey(String title) =>
      sanitizeTtuFilename(title).replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');

  Future<void> triggerPullToRefresh(WidgetTester tester) async {
    final RefreshIndicator indicator =
        tester.widget<RefreshIndicator>(find.byType(RefreshIndicator).first);
    // 下拉刷新第一步是 runManualSyncWithFeedback；只在 onRefresh 期间置全局 busy
    // 让它确定性短路（announceBusy=false 不弹提示），本测试只关心「远端清单失败要
    // 可见」这一段。不能整场置 true：同步进度条会永动，pumpAndSettle 永不收敛。
    syncInProgress.value = true;
    try {
      await indicator.onRefresh();
    } finally {
      syncInProgress.value = false;
    }
    await tester.pump();
  }

  testWidgets('P1：书清单拉取失败 → 下拉刷新弹 remote_book_list_failed（不再静默）',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildApp(_ThrowingListRemoteBookClient()));
    await tester.pumpAndSettle();
    expect(find.text(t.remote_book_list_failed), findsNothing,
        reason: '被动加载失败不弹（离线语义只藏占位卡）；提示只属于显式下拉');

    await triggerPullToRefresh(tester);

    expect(find.text(t.remote_book_list_failed), findsOneWidget,
        reason: '显式下拉失败必须可见：failed 态此前置了没人消费');
    // 冲掉 SnackBar 定时器。
    await tester.pumpAndSettle();
  });

  testWidgets('P3：SRT 有声书清单单独失败 → 计入失败提示，且不连坐隐藏拉取成功的书占位卡',
      (WidgetTester tester) async {
    final _SrtListFailingInterconnectClient client =
        _SrtListFailingInterconnectClient();
    await tester.pumpWidget(buildApp(client));
    await tester.pumpAndSettle();

    final Finder bookCard = find
        .byKey(ValueKey<String>('remote_book_card_${safeKey('Live Book')}'));
    expect(bookCard, findsOneWidget,
        reason: '书清单拉取成功：占位卡必须渲染（srtFailed 不得连坐门控）');

    await triggerPullToRefresh(tester);

    expect(find.text(t.remote_book_list_failed), findsOneWidget,
        reason: 'P3：SRT 清单失败此前被降级成空列表，占位卡静默消失、下拉也无任何提示');
    expect(bookCard, findsOneWidget, reason: '失败提示之外，成功拉到的书占位卡仍在场');
    await tester.pumpAndSettle();
  });
}

class _ThrowingListRemoteBookClient implements RemoteBookClient {
  @override
  RemoteBookSourceKind get remoteSourceKind =>
      RemoteBookSourceKind.interconnect;

  @override
  String get remoteLibrarySourceId => kInterconnectRemoteLibrarySourceId;

  @override
  Future<List<RemoteBookInfo>> listRemoteBooks() async {
    throw const SocketException('host unreachable');
  }

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
}

/// 书清单成功、standalone SRT 有声书清单恒失败的互联后端假实现（P3 的精确形状：
/// 只有 [InterconnectSyncBackend] 类型才会走 listRemoteAudiobooks 这条路）。
class _SrtListFailingInterconnectClient extends InterconnectSyncBackend {
  _SrtListFailingInterconnectClient()
      : super.withProbe((String url, String token) async => true);

  @override
  Future<List<RemoteBookInfo>> listRemoteBooks() async =>
      const <RemoteBookInfo>[
        RemoteBookInfo(title: 'Live Book', hasContent: true),
      ];

  @override
  Future<List<RemoteAudiobookInfo>> listRemoteAudiobooks() async {
    throw const SocketException('audiobook endpoint down');
  }
}

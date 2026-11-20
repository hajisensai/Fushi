import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/pages/implementations/video_loading_overlay.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

class _TestAppModel extends AppModel {
  _TestAppModel(PlatformServices platformServices, this._db)
    : super(platformServices);

  final FushiDatabase _db;

  @override
  double get appUiScale => 1.0;

  @override
  FushiDatabase get database => _db;
}

/// 读库行这一步就抛（库被并发关闭 / 迁移中断 / 磁盘错误）：[VideoFushiPage] 的
/// `_initVideo` 对这一步没有局部 try/catch，异常只能落到 `_init` 的兜底。
class _ThrowingRowRepository extends VideoBookRepository {
  const _ThrowingRowRepository(super.db);

  @override
  Future<VideoBookRow?> getByBookUid(String bookUid) =>
      Future<VideoBookRow?>.error(StateError('database is closed'));
}

/// 取流按集挂起、由测试决定每一集何时失败：用来摆出「旧一程失败晚于新一程开始」。
class _GatedRemoteClient implements RemoteVideoClient {
  final Map<String, Completer<RemoteVideoStreamUrls>> _streams =
      <String, Completer<RemoteVideoStreamUrls>>{};

  bool requested(String id) => _streams.containsKey(id);

  void failStream(String id) =>
      _streams[id]!.completeError(const SocketException('stream gone'));

  @override
  String get remoteLibrarySourceId => 'test_gated_remote';

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async =>
      const <RemoteVideoInfo>[];

  @override
  Future<RemoteVideoStreamUrls> remoteVideoStreamUrls(
    String id, {
    int episodeIndex = 0,
  }) => (_streams[id] = Completer<RemoteVideoStreamUrls>()).future;

  @override
  Future<({int positionMs, int updatedAtMs})> remoteVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async => (positionMs: 0, updatedAtMs: 0);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected ${invocation.memberName}');
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late PreferencesRepository prefs;
  late Directory storeDir;
  late PlatformServices platformServices;
  late FakeAnkiRepository ankiRepository;
  late AppModel appModel;

  setUpAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => Directory.systemTemp.path,
    );
  });

  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
  });

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_video_load_fail');
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = _TestAppModel(platformServices, db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
  });

  Widget wrap(Widget page) => ProviderScope(
    overrides: <Override>[
      platformServicesProvider.overrideWithValue(platformServices),
      ankiRepositoryProvider.overrideWithValue(ankiRepository),
      appProvider.overrideWith((ref) => appModel),
    ],
    child: TranslationProvider(child: MaterialApp(home: page)),
  );

  /// 交替推真实异步与假时钟（与 video_missing_resource_test 同一手法），直到 [done]。
  Future<void> driveUntil(WidgetTester tester, bool Function() done) async {
    for (int round = 0; round < 20 && !done(); round++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 20));
    }
    // 条件可能在最后一段真实异步里才成立（setState 已排上、帧还没出）：补一帧。
    await tester.pump(const Duration(milliseconds: 20));
  }

  // BUG-4906：此前 `_init` 把未预期异常 rethrow 进无人 await 的 future——页面不进
  // 失败态、没有原因也没有重试入口，永久停在加载态（测试框架里表现为未处理异常）。
  testWidgets('init 的未预期异常进入失败态并给出重试入口', (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(
        VideoFushiPage(
          bookUid: 'video/throws',
          repo: _ThrowingRowRepository(db),
        ),
      ),
    );
    final VideoFushiTestHooks hooks =
        tester.state(find.byType(VideoFushiPage)) as VideoFushiTestHooks;
    await driveUntil(tester, () => hooks.debugLoadFailed);

    expect(hooks.debugLoadFailed, isTrue);
    expect(hooks.debugLoadFailureReason, isNotNull);
    expect(hooks.debugHasPendingController, isFalse);
    expect(find.byType(VideoLoadingOverlay), findsNothing);
    expect(find.text(t.video_load_failed_title), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  // BUG-4907：远端换集时作废的那一程（用户在它取流途中又换了集）晚到的失败，
  // 此前照样把页面置成失败态，盖住正在载入的新一集。
  testWidgets('作废的远端换集失败不置失败态，最新一程失败仍报', (WidgetTester tester) async {
    const RemoteVideoInfo first = RemoteVideoInfo(id: 'ep-a', title: 'A');
    const RemoteVideoInfo second = RemoteVideoInfo(id: 'ep-b', title: 'B');
    final _GatedRemoteClient client = _GatedRemoteClient();

    await tester.pumpWidget(
      wrap(
        VideoFushiPage.remote(
          info: first,
          repo: VideoBookRepository(db),
          client: client,
          remoteCollectionMembers: const <RemoteVideoInfo>[first, second],
        ),
      ),
    );
    final VideoFushiTestHooks hooks =
        tester.state(find.byType(VideoFushiPage)) as VideoFushiTestHooks;
    await driveUntil(tester, () => client.requested('ep-a'));
    expect(client.requested('ep-a'), isTrue);

    unawaited(hooks.debugLoadRemoteEpisode(1));
    await driveUntil(tester, () => client.requested('ep-b'));
    expect(client.requested('ep-b'), isTrue);

    client.failStream('ep-a');
    await driveUntil(tester, () => hooks.debugLoadFailed);
    expect(
      hooks.debugLoadFailed,
      isFalse,
      reason: 'superseded episode load must not fail the page',
    );

    client.failStream('ep-b');
    await driveUntil(tester, () => hooks.debugLoadFailed);
    expect(hooks.debugLoadFailed, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

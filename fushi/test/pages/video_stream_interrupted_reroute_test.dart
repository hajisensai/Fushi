// 播放途中断流（PR #4007，拍板台 design-media-server-failover-transport）的页面级
// 接线：EOF 远在片尾之前时，播放页问一次线路故障转移器；换到新线路就收尾旧会话
// （释放流 → 上报停止）并按 EOF 位置重新取流；换不了按「播完」处理；等待期间换了集
// 就什么都不做。故障转移器本身的探测 / 写回见 test/sync/media_server_route_failover_test.dart。
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
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/media_server/media_server_route_failover.dart';
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

/// 媒体服务器客户端替身：取流挂起（测试环境没有真实播放器，不需要真流），故障转移
/// 由测试决定何时、以什么结果返回；释放 / 停止上报 / 取流按发生顺序记进 [events]。
class _FailoverRemoteClient
    implements
        RemoteVideoClient,
        RemoteVideoRouteFailover,
        RemoteVideoPlaybackRelease,
        RemoteVideoPlaybackStop {
  final List<String> events = <String>[];
  final List<Object> failoverErrors = <Object>[];
  Completer<bool>? _failover;

  int streamRequests(String id) =>
      events.where((String e) => e == 'stream:$id').length;

  bool get failoverPending =>
      _failover != null && !_failover!.isCompleted && failoverErrors.isNotEmpty;

  void completeFailover(bool switched) => _failover!.complete(switched);

  @override
  String get remoteLibrarySourceId => 'test_failover_remote';

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async =>
      const <RemoteVideoInfo>[];

  @override
  Future<RemoteVideoStreamUrls> remoteVideoStreamUrls(
    String id, {
    int episodeIndex = 0,
  }) {
    events.add('stream:$id');
    return Completer<RemoteVideoStreamUrls>().future;
  }

  @override
  Future<({int positionMs, int updatedAtMs})> remoteVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async => (positionMs: 0, updatedAtMs: 0);

  @override
  Future<bool> failoverRemoteVideoRoute(Object error) {
    failoverErrors.add(error);
    return (_failover = Completer<bool>()).future;
  }

  @override
  Future<void> releaseRemoteVideoPlayback(String id) async {
    events.add('release:$id');
  }

  @override
  Future<void> stopRemoteVideoPlayback(String id, int positionMs) async {
    events.add('stop:$id@$positionMs');
  }

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

  const RemoteVideoInfo first = RemoteVideoInfo(id: 'ep-a', title: 'A');
  const RemoteVideoInfo second = RemoteVideoInfo(id: 'ep-b', title: 'B');
  // 24 分钟的片子在 10 分钟处 EOF：远在片尾之前 = 流断了。
  const int durationMs = 1440000;
  const int interruptedAtMs = 600000;

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
    storeDir = Directory.systemTemp.createTempSync('fushi_video_reroute');
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

  /// 交替推真实异步与假时钟（与 video_page_load_failures_test 同一手法），直到 [done]。
  Future<void> driveUntil(WidgetTester tester, bool Function() done) async {
    for (int round = 0; round < 20 && !done(); round++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pump(const Duration(milliseconds: 20));
  }

  /// 打开 [first]（与 [second] 组成合集），等它发出第一次取流。
  Future<(VideoFushiTestHooks, _FailoverRemoteClient)> openRemote(
    WidgetTester tester,
  ) async {
    final _FailoverRemoteClient client = _FailoverRemoteClient();
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
    await driveUntil(tester, () => client.streamRequests('ep-a') == 1);
    expect(client.streamRequests('ep-a'), 1);
    return (hooks, client);
  }

  testWidgets('流断了且换到新线路：先释放旧流、上报停止，再按断流位置重新取流', (WidgetTester tester) async {
    final (VideoFushiTestHooks hooks, _FailoverRemoteClient client) =
        await openRemote(tester);

    hooks.debugHandlePlaybackEnded(
      positionMs: interruptedAtMs,
      durationMs: durationMs,
    );
    await driveUntil(tester, () => client.failoverPending);
    expect(client.failoverErrors.single, isA<MediaServerStreamInterrupted>());
    // 问故障转移器期间不收尾、不重载。
    expect(client.events, <String>['stream:ep-a']);

    client.completeFailover(true);
    await driveUntil(tester, () => client.streamRequests('ep-a') == 2);
    expect(client.events, <String>[
      'stream:ep-a',
      'release:ep-a',
      'stop:ep-a@$interruptedAtMs',
      'stream:ep-a',
    ]);
    expect(hooks.debugLoadFailed, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('流断了但没有别的可达线路：按播完处理（上报停止），不释放、不重新取流', (
    WidgetTester tester,
  ) async {
    final (VideoFushiTestHooks hooks, _FailoverRemoteClient client) =
        await openRemote(tester);

    hooks.debugHandlePlaybackEnded(
      positionMs: interruptedAtMs,
      durationMs: durationMs,
    );
    await driveUntil(tester, () => client.failoverPending);
    client.completeFailover(false);
    await driveUntil(
      tester,
      () => client.events.contains('stop:ep-a@$interruptedAtMs'),
    );
    expect(client.events, <String>[
      'stream:ep-a',
      'stop:ep-a@$interruptedAtMs',
    ]);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('EOF 就在片尾：正常播完，不问故障转移器', (WidgetTester tester) async {
    final (VideoFushiTestHooks hooks, _FailoverRemoteClient client) =
        await openRemote(tester);

    hooks.debugHandlePlaybackEnded(
      positionMs: durationMs - 1000,
      durationMs: durationMs,
    );
    await driveUntil(
      tester,
      () => client.events.contains('stop:ep-a@${durationMs - 1000}'),
    );
    expect(client.failoverErrors, isEmpty);
    expect(client.events, <String>[
      'stream:ep-a',
      'stop:ep-a@${durationMs - 1000}',
    ]);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('问故障转移器期间用户换了集：换线路成功也不收尾、不重载旧那一集', (WidgetTester tester) async {
    final (VideoFushiTestHooks hooks, _FailoverRemoteClient client) =
        await openRemote(tester);

    hooks.debugHandlePlaybackEnded(
      positionMs: interruptedAtMs,
      durationMs: durationMs,
    );
    await driveUntil(tester, () => client.failoverPending);

    unawaited(hooks.debugLoadRemoteEpisode(1));
    await driveUntil(tester, () => client.streamRequests('ep-b') == 1);
    expect(client.streamRequests('ep-b'), 1);
    final int eventsBefore = client.events.length;

    client.completeFailover(true);
    await driveUntil(tester, () => client.events.length > eventsBefore);
    expect(client.events.sublist(eventsBefore), isEmpty);
    expect(client.streamRequests('ep-a'), 1);
    expect(client.events, isNot(contains('stop:ep-a@$interruptedAtMs')));

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

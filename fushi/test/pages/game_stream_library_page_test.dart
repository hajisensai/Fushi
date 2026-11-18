import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/pages/implementations/game_stream_library_page.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi/src/utils/components/fushi_cover_block_layout.dart'
    show kFushiCoverBlockSpacing;
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';

typedef _Handler =
    Map<String, dynamic> Function(String path, Map<String, dynamic> body);

class _FakeTransport implements GameStreamTransport {
  _FakeTransport(this.handler);

  final _Handler handler;
  final List<String> paths = <String>[];

  @override
  Future<GameStreamPostResult> post({
    required String path,
    required Map<String, dynamic> body,
    required Duration timeout,
  }) async {
    paths.add(path);
    return GameStreamPostResult(json: handler(path, body));
  }
}

const FushiClientUrl _peer = FushiClientUrl(
  url: 'https://192.168.1.20:8766',
  deviceName: 'Host PC',
  fingerprintSha256: 'aa:bb',
);

Map<String, dynamic> _library({bool launchEnabled = true}) => <String, dynamic>{
  'version': kGameStreamWireVersion,
  'launchEnabled': launchEnabled,
  'games': <Map<String, Object?>>[
    const GameStreamLibraryGame(id: 'g1', title: 'Alpha').toJson(),
    const GameStreamLibraryGame(
      id: 'g2',
      title: 'Beta',
      running: true,
    ).toJson(),
  ],
};

Map<String, dynamic> _sessionJson(String id, {String? gameId}) {
  final String now = DateTime.utc(2026, 9, 23).toIso8601String();
  return <String, dynamic>{
    'version': kGameStreamWireVersion,
    'sessionId': id,
    'state': 'waiting',
    'createdAt': now,
    'updatedAt': now,
    if (gameId != null) 'gameId': gameId,
    if (gameId != null) 'gameTitle': 'Alpha',
  };
}

Map<String, dynamic> _launch(String state, {String? sessionId}) =>
    <String, dynamic>{
      'launch': <String, Object?>{
        'launchId': 'l1',
        'gameId': 'g1',
        'state': state,
        'updatedAt': 1,
        if (sessionId != null) 'sessionId': sessionId,
      },
    };

class _Opened {
  _Opened(this.session, this.settings);
  final GameStreamSession session;
  final GameStreamVideoSettings settings;
}

Future<List<_Opened>> _pump(
  WidgetTester tester, {
  required _FakeTransport transport,
  List<FushiClientUrl> peers = const <FushiClientUrl>[_peer],
  GameStreamVideoSettings settings = const GameStreamVideoSettings(),
  Map<String, _FakeTransport> transportsByUrl =
      const <String, _FakeTransport>{},
  VoidCallback? onInterconnect,
}) async {
  tester.view.physicalSize = const Size(1200, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final List<_Opened> opened = <_Opened>[];
  await tester.pumpWidget(
    MaterialApp(
      home: FushiFocusRoot(
        child: GameStreamLibraryPage(
          services: GameStreamLibraryServices(
            loadPeers: () async => peers,
            createClient: (FushiClientUrl peer) => FushiGameStreamClient(
              transport: transportsByUrl[peer.url] ?? transport,
            )..bindPeer(peer),
            openSession:
                (
                  BuildContext context,
                  GameStreamHostConnection host,
                  GameStreamSession session,
                  GameStreamVideoSettings settings,
                ) async {
                  opened.add(_Opened(session, settings));
                },
            readSettings: () => settings,
            writeSettings: (GameStreamVideoSettings _) async {},
            openInterconnectSettings: (BuildContext _) async =>
                onInterconnect?.call(),
            clientId: 'test-client',
            launchPollInterval: const Duration(milliseconds: 10),
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
  return opened;
}

/// 焦点驱动：把焦点交给 [focusId] 站点，再按 Enter（不点坐标）。
Future<void> _enterOn(WidgetTester tester, String focusId) async {
  final FushiFocusController controller = FushiFocusRoot.controllerOf(
    tester.element(find.byType(GameStreamLibraryPage)),
  );
  expect(
    controller.requestById(FushiFocusId(focusId)),
    isTrue,
    reason: '$focusId 必须注册焦点站点（手柄 / 键盘可选中）',
  );
  await tester.pump();
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pump();
}

/// 焦点驱动：聚焦 [target] 按钮自己的焦点节点，再按 Enter。
Future<void> _enterOnButton(WidgetTester tester, Finder target) async {
  final FocusNode node = Focus.of(
    tester.element(
      find.descendant(of: target, matching: find.byType(Text)).first,
    ),
  );
  node.requestFocus();
  await tester.pump();
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pump();
}

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  testWidgets('renders the host library as a poster grid with running badge', (
    WidgetTester tester,
  ) async {
    final _FakeTransport transport = _FakeTransport(
      (String path, Map<String, dynamic> body) => switch (path) {
        '/api/game-stream/sessions' => <String, dynamic>{
          'sessions': <Object>[],
        },
        '/api/game-stream/library' => _library(),
        _ => throw StateError('unexpected $path'),
      },
    );
    await _pump(tester, transport: transport);

    expect(find.text('Host PC'), findsOneWidget);
    expect(find.text(t.game_stream_host_online(n: 2)), findsOneWidget);
    expect(find.byKey(GameStreamLibraryPage.gameCardKey('g1')), findsOneWidget);
    expect(find.byKey(GameStreamLibraryPage.gameCardKey('g2')), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text(t.game_stream_running), findsOneWidget);
    expect(find.text(t.game_stream_host_launch_off), findsNothing);
  });

  testWidgets('launching a game polls the host and opens the stream session', (
    WidgetTester tester,
  ) async {
    int statusPolls = 0;
    bool streaming = false;
    const GameStreamVideoSettings settings = GameStreamVideoSettings(
      maxHeight: 720,
      maxFps: 30,
    );
    final _FakeTransport transport = _FakeTransport((
      String path,
      Map<String, dynamic> body,
    ) {
      switch (path) {
        case '/api/game-stream/sessions':
          return <String, dynamic>{
            'sessions': <Object>[
              if (streaming) _sessionJson('s1', gameId: 'g1'),
            ],
          };
        case '/api/game-stream/library':
          return _library();
        case '/api/game-stream/launch':
          expect(body['gameId'], 'g1');
          expect(body['clientId'], 'test-client');
          expect(body['settings'], settings.toJson());
          return _launch('starting');
        case '/api/game-stream/launch/status':
          statusPolls++;
          if (statusPolls < 2) return _launch('waitingWindow');
          streaming = true;
          return _launch('streaming', sessionId: 's1');
      }
      throw StateError('unexpected $path');
    });
    final List<_Opened> opened = await _pump(
      tester,
      transport: transport,
      settings: settings,
    );

    await _enterOn(tester, 'game-stream-card-aa:bb-g1');
    expect(find.text(t.game_stream_launch_starting), findsOneWidget);
    await _settle(tester);

    expect(opened, hasLength(1));
    expect(opened.single.session.sessionId, 's1');
    expect(opened.single.session.gameId, 'g1');
    expect(opened.single.settings.maxHeight, 720);
    expect(statusPolls, 2);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets(
    'remote launch off: idle games cannot launch, no launch request',
    (WidgetTester tester) async {
      final _FakeTransport transport = _FakeTransport(
        (String path, Map<String, dynamic> body) => switch (path) {
          '/api/game-stream/sessions' => <String, dynamic>{
            'sessions': <Object>[],
          },
          '/api/game-stream/library' => _library(launchEnabled: false),
          _ => throw StateError('unexpected $path'),
        },
      );
      final List<_Opened> opened = await _pump(tester, transport: transport);
      expect(
        find.byKey(GameStreamLibraryPage.launchOffKey('aa:bb')),
        findsOneWidget,
      );
      expect(find.text(t.game_stream_host_launch_off), findsOneWidget);
      // 没在跑的游戏：副行直说「未运行 · 不可启动」，不再给出点了才报错的启动入口。
      expect(find.text(t.game_stream_launch_unavailable), findsOneWidget);

      // 本 PR 起没在跑、又不能远程启动的块没有动作（onTap == null），FushiCard
      // 不为无动作的卡注册焦点站点：手柄 / 键盘根本停不上去，也就无从按 Enter
      // 发启动请求。运行中的 g2 照旧是可加入的停靠点。
      final FushiFocusController controller = FushiFocusRoot.controllerOf(
        tester.element(find.byType(GameStreamLibraryPage)),
      );
      expect(
        controller.requestById(const FushiFocusId('game-stream-card-aa:bb-g1')),
        isFalse,
        reason: '不可启动的块不应是焦点停靠点',
      );
      expect(
        controller.requestById(const FushiFocusId('game-stream-card-aa:bb-g2')),
        isTrue,
        reason: '运行中的块仍可经手柄 / 键盘加入',
      );
      await _settle(tester);

      expect(transport.paths, isNot(contains('/api/game-stream/launch')));
      expect(find.text(t.game_stream_launch_starting), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(opened, isEmpty);
    },
  );

  testWidgets('a host refusing plaintext says to turn on HTTPS, not update', (
    WidgetTester tester,
  ) async {
    final _FakeTransport transport = _FakeTransport(
      (String path, Map<String, dynamic> body) =>
          throw const GameStreamRequestError(
            statusCode: 403,
            code: 'https_required',
          ),
    );
    await _pump(tester, transport: transport);

    expect(find.text(t.game_stream_host_https_required), findsOneWidget);
    expect(find.text(t.game_stream_host_outdated), findsNothing);
  });

  testWidgets('a host with game stream off says to turn it on, not update', (
    WidgetTester tester,
  ) async {
    final _FakeTransport transport = _FakeTransport(
      (String path, Map<String, dynamic> body) =>
          throw const GameStreamRequestError(
            statusCode: 404,
            code: 'game_stream_off',
          ),
    );
    await _pump(tester, transport: transport);

    expect(find.text(t.game_stream_host_stream_off), findsOneWidget);
    expect(find.text(t.game_stream_host_outdated), findsNothing);
  });

  testWidgets('a host refusing an unpaired credential says to re-pair', (
    WidgetTester tester,
  ) async {
    final _FakeTransport transport = _FakeTransport(
      (String path, Map<String, dynamic> body) =>
          throw const GameStreamRequestError(
            statusCode: 403,
            code: 'unauthorized_peer',
          ),
    );
    int interconnect = 0;
    await _pump(
      tester,
      transport: transport,
      onInterconnect: () => interconnect++,
    );

    expect(find.text(t.game_stream_host_unauthorized), findsOneWidget);
    expect(find.text(t.game_stream_host_outdated), findsNothing);
    // 被拒（要重新配对）的降级态给「打开互联设置」，不是没用的「重试」。
    final Finder repair = find.byKey(
      GameStreamLibraryPage.hostInterconnectKey('aa:bb'),
    );
    expect(repair, findsOneWidget);
    expect(
      find.byKey(GameStreamLibraryPage.hostRetryKey('aa:bb')),
      findsNothing,
    );
    await _enterOnButton(tester, repair);
    await _settle(tester);
    expect(interconnect, 1);
  });

  testWidgets('a current host without a library says so and keeps sessions', (
    WidgetTester tester,
  ) async {
    final _FakeTransport transport = _FakeTransport(
      (String path, Map<String, dynamic> body) => switch (path) {
        '/api/game-stream/sessions' => <String, dynamic>{
          'sessions': <Object>[_sessionJson('s-1')],
        },
        '/api/game-stream/library' => throw const GameStreamRequestError(
          statusCode: 404,
          code: 'library_off',
        ),
        _ => throw StateError('unexpected $path'),
      },
    );
    await _pump(tester, transport: transport);

    expect(find.text(t.game_stream_host_library_off), findsOneWidget);
    expect(find.text(t.game_stream_host_outdated), findsNothing);
    expect(find.byKey(GameStreamLibraryPage.sessionKey('s-1')), findsOneWidget);
  });

  testWidgets('an old host without the library route still offers sessions', (
    WidgetTester tester,
  ) async {
    final _FakeTransport transport = _FakeTransport(
      (String path, Map<String, dynamic> body) => switch (path) {
        '/api/game-stream/sessions' => <String, dynamic>{
          'sessions': <Object>[_sessionJson('old-1')],
        },
        '/api/game-stream/library' => throw const GameStreamRequestError(
          statusCode: 404,
          code: 'http_rejected',
        ),
        _ => throw StateError('unexpected $path'),
      },
    );
    final List<_Opened> opened = await _pump(tester, transport: transport);

    expect(find.text(t.game_stream_host_outdated), findsOneWidget);
    expect(find.byKey(GameStreamLibraryPage.gameCardKey('g1')), findsNothing);
    expect(
      find.byKey(GameStreamLibraryPage.sessionKey('old-1')),
      findsOneWidget,
    );

    await _enterOn(tester, 'game-stream-session-old-1');
    await _settle(tester);
    expect(opened.single.session.sessionId, 'old-1');
  });

  testWidgets('no paired host shows the interconnect entry', (
    WidgetTester tester,
  ) async {
    final _FakeTransport transport = _FakeTransport(
      (String path, Map<String, dynamic> body) =>
          throw StateError('unexpected $path'),
    );
    await _pump(tester, transport: transport, peers: const <FushiClientUrl>[]);

    expect(find.text(t.game_stream_no_hosts), findsOneWidget);
    expect(
      find.byKey(GameStreamLibraryPage.interconnectButtonKey),
      findsOneWidget,
    );
    expect(transport.paths, isEmpty);
  });

  testWidgets('every paired host is its own group with a status row', (
    WidgetTester tester,
  ) async {
    const FushiClientUrl offline = FushiClientUrl(
      url: 'https://192.168.1.30:8766',
      deviceName: 'Laptop',
      fingerprintSha256: 'cc:dd',
    );
    final _FakeTransport online = _FakeTransport(
      (String path, Map<String, dynamic> body) => switch (path) {
        '/api/game-stream/sessions' => <String, dynamic>{
          'sessions': <Object>[],
        },
        '/api/game-stream/library' => _library(),
        _ => throw StateError('unexpected $path'),
      },
    );
    final _FakeTransport unreachable = _FakeTransport(
      (String path, Map<String, dynamic> body) =>
          throw const GameStreamUnreachableError('offline'),
    );
    await _pump(
      tester,
      transport: online,
      peers: const <FushiClientUrl>[_peer, offline],
      transportsByUrl: <String, _FakeTransport>{offline.url: unreachable},
    );

    // 不再是「一次只看一台」的切换 chip：两台主机同屏各一组。
    expect(find.byKey(GameStreamLibraryPage.hostKey('aa:bb')), findsOneWidget);
    expect(find.byKey(GameStreamLibraryPage.hostKey('cc:dd')), findsOneWidget);
    expect(find.text('Host PC'), findsOneWidget);
    expect(find.text('Laptop'), findsOneWidget);
    expect(find.text(t.game_stream_host_online(n: 2)), findsOneWidget);
    expect(find.text(t.game_stream_unreachable), findsOneWidget);
    // 连不上的主机给「重试」，组内不画游戏块。
    expect(
      find.byKey(GameStreamLibraryPage.hostRetryKey('cc:dd')),
      findsOneWidget,
    );
    expect(find.byKey(GameStreamLibraryPage.gameCardKey('g1')), findsOneWidget);
  });

  testWidgets('the first online host leads with the running game, enlarged', (
    WidgetTester tester,
  ) async {
    final _FakeTransport transport = _FakeTransport(
      (String path, Map<String, dynamic> body) => switch (path) {
        '/api/game-stream/sessions' => <String, dynamic>{
          'sessions': <Object>[],
        },
        '/api/game-stream/library' => _library(),
        _ => throw StateError('unexpected $path'),
      },
    );
    await _pump(tester, transport: transport);

    final Finder running = find.byKey(GameStreamLibraryPage.gameCardKey('g2'));
    final Finder idle = find.byKey(GameStreamLibraryPage.gameCardKey('g1'));
    expect(
      tester.getSize(running).width,
      greaterThan(tester.getSize(idle).width),
      reason: '运行中的 Beta 是唯一的加大首块',
    );
    expect(tester.getTopLeft(running).dx, lessThan(tester.getTopLeft(idle).dx));
  });

  test('block columns: 4 at >=900dp, 3 at >=600dp, else 2', () {
    expect(gameStreamBlockColumns(1200), 4);
    expect(gameStreamBlockColumns(900), 4);
    expect(gameStreamBlockColumns(899), 3);
    expect(gameStreamBlockColumns(600), 3);
    expect(gameStreamBlockColumns(599), 2);
    for (final double width in <double>[360, 640, 960, 1400]) {
      final double target = gameStreamBlockTargetWidth(width);
      // computeFushiCoverBlockPlan 的列数公式：round((宽 + 间距) / (目标 + 间距))。
      expect(
        ((width + kFushiCoverBlockSpacing) / (target + kFushiCoverBlockSpacing))
            .round(),
        gameStreamBlockColumns(width),
      );
    }
  });

  test('hero pick: running first, else most recently played', () {
    expect(gameStreamHeroIndex(const <GameStreamLibraryGame>[]), -1);
    expect(
      gameStreamHeroIndex(const <GameStreamLibraryGame>[
        GameStreamLibraryGame(id: 'a', title: 'A', lastPlayedAt: 50),
        GameStreamLibraryGame(id: 'b', title: 'B', running: true),
      ]),
      1,
    );
    expect(
      gameStreamHeroIndex(const <GameStreamLibraryGame>[
        GameStreamLibraryGame(id: 'a', title: 'A', lastPlayedAt: 10),
        GameStreamLibraryGame(id: 'b', title: 'B', lastPlayedAt: 90),
        GameStreamLibraryGame(id: 'c', title: 'C'),
      ]),
      1,
    );
  });

  test('game subtitle says running / not launchable / last played', () {
    final DateTime now = DateTime(2026, 11, 15);
    const GameStreamLibraryGame idle = GameStreamLibraryGame(
      id: 'a',
      title: 'A',
    );
    const GameStreamLibraryGame live = GameStreamLibraryGame(
      id: 'b',
      title: 'B',
      running: true,
    );
    expect(
      gameStreamGameSubtitle(live, launchEnabled: false, now: now),
      t.game_stream_running,
    );
    expect(
      gameStreamGameSubtitle(idle, launchEnabled: false, now: now),
      t.game_stream_launch_unavailable,
    );
    expect(gameStreamGameSubtitle(idle, launchEnabled: true, now: now), '');
    expect(
      gameStreamGameSubtitle(
        live,
        launchEnabled: true,
        now: now,
        runningInChip: true,
      ),
      '',
    );
  });
}

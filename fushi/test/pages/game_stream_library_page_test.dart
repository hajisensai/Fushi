import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/game_stream_library_page.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
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
}) async {
  tester.view.physicalSize = const Size(1200, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final List<_Opened> opened = <_Opened>[];
  await tester.pumpWidget(
    MaterialApp(
      home: GameStreamLibraryPage(
        services: GameStreamLibraryServices(
          loadPeers: () async => peers,
          createClient: (FushiClientUrl peer) =>
              FushiGameStreamClient(transport: transport)..bindPeer(peer),
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
          openInterconnectSettings: (BuildContext _) async {},
          clientId: 'test-client',
          launchPollInterval: const Duration(milliseconds: 10),
        ),
      ),
    ),
  );
  await _settle(tester);
  return opened;
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

    await tester.tap(find.byKey(GameStreamLibraryPage.gameCardKey('g1')));
    await tester.pump();
    expect(find.text(t.game_stream_launch_starting), findsOneWidget);
    await _settle(tester);

    expect(opened, hasLength(1));
    expect(opened.single.session.sessionId, 's1');
    expect(opened.single.session.gameId, 'g1');
    expect(opened.single.settings.maxHeight, 720);
    expect(statusPolls, 2);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('launch_disabled explains how to enable remote launch', (
    WidgetTester tester,
  ) async {
    final _FakeTransport transport = _FakeTransport(
      (String path, Map<String, dynamic> body) => switch (path) {
        '/api/game-stream/sessions' => <String, dynamic>{
          'sessions': <Object>[],
        },
        '/api/game-stream/library' => _library(launchEnabled: false),
        '/api/game-stream/launch' => throw const GameStreamRequestError(
          statusCode: 403,
          code: GameStreamLaunchFailure.disabled,
        ),
        _ => throw StateError('unexpected $path'),
      },
    );
    final List<_Opened> opened = await _pump(tester, transport: transport);
    expect(find.text(t.game_stream_host_launch_off), findsOneWidget);

    await tester.tap(find.byKey(GameStreamLibraryPage.gameCardKey('g1')));
    await _settle(tester);

    expect(find.text(t.game_stream_launch_disabled), findsOneWidget);
    expect(opened, isEmpty);
    await tester.tap(find.text(t.dialog_ok));
    await _settle(tester);
    expect(find.byType(AlertDialog), findsNothing);
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

    await tester.tap(find.text(t.game_stream_join_action));
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
}

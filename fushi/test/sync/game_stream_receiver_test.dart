import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi/src/sync/game_stream_receiver.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';

class _Transport implements GameStreamTransport {
  Future<GameStreamPostResult> Function(Map<String, dynamic>)? handler;

  @override
  Future<GameStreamPostResult> post({
    required String path,
    required Map<String, dynamic> body,
    required Duration timeout,
  }) async => handler == null
      ? const GameStreamPostResult(
          json: <String, dynamic>{'signals': <Object>[]},
        )
      : handler!(body);
}

class _Renderer extends RTCVideoRenderer {
  int initializeCount = 0;
  int disposeCount = 0;
  Completer<void>? initializeGate;
  MediaStream? stream;

  @override
  Future<void> initialize() async {
    initializeCount++;
    await initializeGate?.future;
  }

  @override
  set srcObject(MediaStream? value) {
    if (disposeCount != 0) throw StateError('Renderer is disposed');
    stream = value;
  }

  @override
  MediaStream? get srcObject => stream;

  @override
  Future<void> dispose() async {
    disposeCount++;
    await super.dispose();
  }
}

class _Peer extends RTCPeerConnection {
  final List<String> applied = <String>[];
  int closeCount = 0;
  int disposeCount = 0;
  bool remoteDescriptionSet = false;

  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    applied.add('offer');
    remoteDescriptionSet = true;
  }

  @override
  Future<RTCSessionDescription> createAnswer([
    Map<String, dynamic>? constraints,
  ]) async => RTCSessionDescription('answer-sdp', 'answer');

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {
    applied.add('answer');
  }

  @override
  Future<void> addCandidate(RTCIceCandidate candidate) async {
    if (!remoteDescriptionSet) throw StateError('No remote description');
    applied.add(candidate.candidate!);
  }

  @override
  Future<void> close() async {
    closeCount++;
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Channel extends RTCDataChannel {
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  Completer<void>? sendGate;
  RTCDataChannelState channelState = RTCDataChannelState.RTCDataChannelOpen;

  @override
  String get label => 'fushi-game-control';

  @override
  RTCDataChannelState get state => channelState;

  void changeState(RTCDataChannelState value) {
    channelState = value;
    onDataChannelState?.call(value);
  }

  @override
  Future<void> send(RTCDataChannelMessage message) async {
    sent.add(jsonDecode(message.text) as Map<String, dynamic>);
    final Completer<void>? gate = sendGate;
    if (gate != null) await gate.future;
  }

  void ack(int sequence, {bool accepted = true, String? reason}) {
    onMessage?.call(
      RTCDataChannelMessage(
        jsonEncode(<String, Object?>{
          'kind': 'ack',
          'ack': GameStreamInputAck(
            sequence: sequence,
            accepted: accepted,
            reason: reason,
          ).toJson(),
        }),
      ),
    );
  }

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Stream implements MediaStream {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Track implements MediaStreamTrack {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

GameStreamSignal _hostSignal(int sequence, GameStreamSignalType type) =>
    GameStreamSignal(
      sessionId: 'session',
      senderId: 'host',
      senderRole: GameStreamPeerRole.host,
      type: type,
      sequence: sequence,
      payload: type == GameStreamSignalType.offer
          ? <String, Object?>{'sdp': 'offer-sdp', 'type': 'offer'}
          : <String, Object?>{'candidate': 'remote-ice-$sequence'},
    );

GameStreamInputEvent _input(int sequence) => GameStreamInputEvent(
  sessionId: 'session',
  clientId: 'phone',
  sequence: sequence,
  kind: GameStreamInputKind.key,
  action: GameStreamInputAction.down,
  timestampMs: 1,
  key: 'Enter',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Transport transport;
  late _Renderer renderer;
  late _Peer peer;
  late FushiGameStreamReceiver receiver;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    transport = _Transport();
    renderer = _Renderer();
    peer = _Peer();
    receiver = FushiGameStreamReceiver(
      client: FushiGameStreamClient(transport: transport),
      videoRenderer: renderer,
      peerFactory: () async => peer,
    );
  });

  tearDown(() async {
    receiver.dispose();
    await Future<void>.value();
    debugDefaultTargetPlatformOverride = null;
  });

  test('rejects non-Android before allocating native resources', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await expectLater(
      receiver.connect(sessionId: 'session', clientId: 'phone'),
      throwsUnsupportedError,
    );
    expect(renderer.initializeCount, 0);
    expect(peer.closeCount, 0);
  });

  test('ready requires the first rendered video frame', () async {
    await receiver.connect(sessionId: 'session', clientId: 'phone');
    peer.onTrack?.call(
      RTCTrackEvent(streams: <MediaStream>[_Stream()], track: _Track()),
    );
    expect(receiver.ready, isFalse);
    renderer.onFirstFrameRendered?.call();
    expect(receiver.ready, isTrue);
  });

  test('a successful signaling poll clears a temporary HTTP error', () async {
    transport.handler = (Map<String, dynamic> body) async {
      throw const GameStreamUnreachableError('LAN unavailable');
    };
    await receiver.connect(sessionId: 'session', clientId: 'phone');
    expect(receiver.error, contains('LAN unavailable'));
    transport.handler = null;
    receiver.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    expect(receiver.error, isNull);
    expect(peer.closeCount, 0);
  });

  test(
    'buffers ICE before offer and keeps independent signaling cursors',
    () async {
      final List<Map<String, dynamic>> requests = <Map<String, dynamic>>[];
      transport.handler = (Map<String, dynamic> body) async {
        requests.add(body);
        if (body['signal'] != null) {
          // sendSignal responses must not advance the host polling cursor.
          return GameStreamPostResult(
            json: <String, dynamic>{
              'signals': <Object>[
                _hostSignal(99, GameStreamSignalType.iceCandidate).toJson(),
              ],
            },
          );
        }
        return GameStreamPostResult(
          json: <String, dynamic>{
            'signals': (body['after'] as int) < 1
                ? <Object>[
                    _hostSignal(0, GameStreamSignalType.iceCandidate).toJson(),
                    _hostSignal(1, GameStreamSignalType.offer).toJson(),
                  ]
                : <Object>[],
          },
        );
      };
      await receiver.connect(sessionId: 'session', clientId: 'phone');
      expect(peer.applied, <String>['offer', 'remote-ice-0', 'answer']);
      final Map<String, dynamic> answer = requests.singleWhere(
        (Map<String, dynamic> body) => body['signal'] != null,
      );
      expect((answer['signal'] as Map)['sequence'], 0);
      expect((answer['signal'] as Map)['type'], 'answer');
      receiver.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.value();
      expect(requests.last['after'], 1);
    },
  );

  test('outbound signaling is serial and polling never overlaps', () async {
    int activePolls = 0;
    int maxActivePolls = 0;
    int activeSends = 0;
    int maxActiveSends = 0;
    final List<int> sent = <int>[];
    final List<Completer<GameStreamPostResult>> sendGates =
        <Completer<GameStreamPostResult>>[];
    Completer<GameStreamPostResult>? pollGate;
    transport.handler = (Map<String, dynamic> body) async {
      if (body['signal'] != null) {
        activeSends++;
        maxActiveSends = activeSends > maxActiveSends
            ? activeSends
            : maxActiveSends;
        sent.add((body['signal'] as Map)['sequence'] as int);
        final Completer<GameStreamPostResult> gate =
            Completer<GameStreamPostResult>();
        sendGates.add(gate);
        final GameStreamPostResult result = await gate.future;
        activeSends--;
        return result;
      }
      if (pollGate == null) {
        return const GameStreamPostResult(
          json: <String, dynamic>{'signals': <Object>[]},
        );
      }
      activePolls++;
      maxActivePolls = activePolls > maxActivePolls
          ? activePolls
          : maxActivePolls;
      final GameStreamPostResult result = await pollGate.future;
      activePolls--;
      return result;
    };
    await receiver.connect(sessionId: 'session', clientId: 'phone');
    pollGate = Completer<GameStreamPostResult>();
    peer.onIceCandidate?.call(RTCIceCandidate('first', '0', 0));
    peer.onIceCandidate?.call(RTCIceCandidate('second', '0', 0));
    await Future<void>.delayed(Duration.zero);
    expect(sent, <int>[0]);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(maxActivePolls, 1);
    sendGates.first.complete(
      const GameStreamPostResult(
        json: <String, dynamic>{'signals': <Object>[]},
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(sent, <int>[0, 1]);
    expect(maxActiveSends, 1);
    sendGates.last.complete(
      const GameStreamPostResult(
        json: <String, dynamic>{'signals': <Object>[]},
      ),
    );
    pollGate.complete(
      const GameStreamPostResult(
        json: <String, dynamic>{'signals': <Object>[]},
      ),
    );
    await Future<void>.delayed(Duration.zero);
    receiver.dispose();
    await Future<void>.delayed(Duration.zero);
  });

  test('failed SDP answer does not consume the host offer cursor', () async {
    final List<int> polledAfter = <int>[];
    int answers = 0;
    transport.handler = (Map<String, dynamic> body) async {
      if (body['signal'] != null) {
        answers++;
        if (answers == 1) {
          throw const GameStreamUnreachableError('answer delivery failed');
        }
        return const GameStreamPostResult(
          json: <String, dynamic>{'signals': <Object>[]},
        );
      }
      final int after = body['after'] as int;
      polledAfter.add(after);
      return GameStreamPostResult(
        json: <String, dynamic>{
          'signals': <Object>[
            if (after < 0) _hostSignal(0, GameStreamSignalType.offer).toJson(),
          ],
        },
      );
    };
    await receiver.connect(sessionId: 'session', clientId: 'phone');
    expect(receiver.error, contains('answer delivery failed'));
    receiver.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    expect(polledAfter, <int>[-1, -1]);
    expect(answers, 2);
    expect(receiver.error, isNull);
  });

  test(
    'sendInput resolves host ACK, preserves timeout sequence and cancels on disconnect',
    () async {
      await receiver.connect(sessionId: 'session', clientId: 'phone');
      peer.onConnectionState?.call(
        RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      );
      final _Channel channel = _Channel();
      peer.onDataChannel?.call(channel);
      bool completed = false;
      final Future<GameStreamInputAck> first = receiver.sendInput(_input(7));
      unawaited(first.then((_) => completed = true));
      await Future<void>.delayed(Duration.zero);
      expect(channel.sent.single['event']['sequence'], 7);
      expect(completed, isFalse);
      channel.ack(7, accepted: false, reason: 'target_not_foreground');
      expect((await first).reason, 'target_not_foreground');
      final Future<GameStreamInputAck> timeout = receiver.sendInput(_input(8));
      await Future<void>.delayed(const Duration(seconds: 3));
      final GameStreamInputAck timedOut = await timeout;
      expect(timedOut.sequence, 8);
      expect(timedOut.reason, 'ack_timeout');
      final Future<GameStreamInputAck> pending = receiver.sendInput(_input(9));
      await receiver.disconnect();
      final GameStreamInputAck disconnected = await pending;
      expect(disconnected.sequence, 9);
      expect(disconnected.reason, 'disconnected');
      receiver.dispose();
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'ACK timeout drops queued input and releases before fresh controls',
    () async {
      await receiver.connect(sessionId: 'session', clientId: 'phone');
      peer.onConnectionState?.call(
        RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      );
      final Completer<void> sendGate = Completer<void>();
      final _Channel channel = _Channel()..sendGate = sendGate;
      peer.onDataChannel?.call(channel);
      final Future<GameStreamInputAck> first = receiver.sendInput(_input(1));
      await Future<void>.value();
      final Future<GameStreamInputAck> queued = receiver.sendInput(_input(2));

      expect((await first).reason, 'ack_timeout');
      expect((await queued).reason, 'ack_timeout');
      final Future<GameStreamInputAck> fresh = receiver.sendInput(_input(3));
      sendGate.complete();
      await Future<void>.delayed(Duration.zero);
      channel.ack(1); // Late ACK cannot revive the expired input epoch.
      channel.ack(3);
      expect((await fresh).accepted, isTrue);
      expect(
        channel.sent.map((Map<String, dynamic> message) => message['kind']),
        <String>['input', 'releaseAll', 'input'],
      );
      expect(
        channel.sent
            .where((Map<String, dynamic> message) => message['kind'] == 'input')
            .map(
              (Map<String, dynamic> message) =>
                  (message['event'] as Map<String, dynamic>)['sequence'],
            ),
        <int>[1, 3],
        reason: 'A DOWN rejected by timeout must never reach the game later',
      );
      expect(channel.sent[1]['sessionId'], 'session');
      expect(channel.sent[1]['clientId'], 'phone');
    },
  );

  test(
    'closed control channel requires host restart even while media connects',
    () async {
      int polls = 0;
      transport.handler = (Map<String, dynamic> body) async {
        polls++;
        return const GameStreamPostResult(
          json: <String, dynamic>{'signals': <Object>[]},
        );
      };
      await receiver.connect(sessionId: 'session', clientId: 'phone');
      peer.onConnectionState?.call(
        RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      );
      peer.onTrack?.call(
        RTCTrackEvent(streams: <MediaStream>[_Stream()], track: _Track()),
      );
      renderer.onFirstFrameRendered?.call();
      final _Channel channel = _Channel();
      peer.onDataChannel?.call(channel);
      final Future<GameStreamInputAck> pending = receiver.sendInput(_input(1));
      await Future<void>.value();
      channel.changeState(RTCDataChannelState.RTCDataChannelClosed);
      expect((await pending).reason, 'control_channel_closed');
      expect(receiver.state, GameStreamReceiverState.failed);
      expect(receiver.ready, isFalse);
      expect(receiver.reconnectRequired, isTrue);
      expect(receiver.error, 'control_channel_closed_host_restart_required');

      // Android resume and a late media callback cannot revive this session.
      receiver.didChangeAppLifecycleState(AppLifecycleState.paused);
      receiver.didChangeAppLifecycleState(AppLifecycleState.resumed);
      peer.onConnectionState?.call(
        RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      );
      renderer.onFirstFrameRendered?.call();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(polls, 1);
      expect(receiver.ready, isFalse);
      expect(receiver.reconnectRequired, isTrue);
      expect(receiver.error, 'control_channel_closed_host_restart_required');
      expect((await receiver.sendInput(_input(2))).accepted, isFalse);
      await expectLater(
        receiver.connect(sessionId: 'session', clientId: 'phone'),
        throwsStateError,
      );
    },
  );

  test(
    'short disconnect and Android background keep the same native peer',
    () async {
      await receiver.connect(sessionId: 'session', clientId: 'phone');
      peer.onConnectionState?.call(
        RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      );
      peer.onConnectionState?.call(
        RTCPeerConnectionState.RTCPeerConnectionStateDisconnected,
      );
      expect(receiver.state, GameStreamReceiverState.reconnecting);
      receiver.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(receiver.backgrounded, isTrue);
      receiver.didChangeAppLifecycleState(AppLifecycleState.resumed);
      peer.onConnectionState?.call(
        RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      );
      expect(receiver.error, isNull);
      expect(receiver.backgrounded, isFalse);
      expect(peer.closeCount, 0);
      await receiver.connect(sessionId: 'session', clientId: 'phone');
      expect(renderer.initializeCount, 1);
      peer.onConnectionState?.call(
        RTCPeerConnectionState.RTCPeerConnectionStateFailed,
      );
      expect(receiver.reconnectRequired, isTrue);
      expect(receiver.error, 'connection_failed_host_restart_required');
      await expectLater(
        receiver.connect(sessionId: 'session', clientId: 'phone'),
        throwsStateError,
      );
    },
  );

  test(
    'Android background releases held keys over the ordered channel',
    () async {
      await receiver.connect(sessionId: 'session', clientId: 'phone');
      peer.onConnectionState?.call(
        RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      );
      final _Channel channel = _Channel();
      peer.onDataChannel?.call(channel);
      final Future<GameStreamInputAck> down = receiver.sendInput(_input(1));
      await Future<void>.value();
      receiver.didChangeAppLifecycleState(AppLifecycleState.inactive);
      receiver.didChangeAppLifecycleState(AppLifecycleState.paused);
      final GameStreamInputAck interrupted = await down;
      expect(interrupted.reason, 'app_backgrounded');
      await Future<void>.value();
      expect(channel.sent.map((Map<String, dynamic> m) => m['kind']), <String>[
        'input',
        'releaseAll',
      ]);
      expect(channel.sent.last['sessionId'], 'session');
      expect(channel.sent.last['clientId'], 'phone');
      expect((await receiver.sendInput(_input(2))).accepted, isFalse);
    },
  );

  for (final bool background in <bool>[true, false]) {
    test(
      'resuming ${background ? 'Android' : 'ICE'} drops queued old input and preserves ordered release',
      () async {
        await receiver.connect(sessionId: 'session', clientId: 'phone');
        peer.onConnectionState?.call(
          RTCPeerConnectionState.RTCPeerConnectionStateConnected,
        );
        final Completer<void> sendGate = Completer<void>();
        final _Channel channel = _Channel()..sendGate = sendGate;
        peer.onDataChannel?.call(channel);
        final Future<GameStreamInputAck> first = receiver.sendInput(_input(1));
        await Future<void>.value();
        expect(channel.sent, hasLength(1));
        final Future<GameStreamInputAck> queued = receiver.sendInput(_input(2));
        if (background) {
          receiver.didChangeAppLifecycleState(AppLifecycleState.paused);
          receiver.didChangeAppLifecycleState(AppLifecycleState.resumed);
        } else {
          peer.onConnectionState?.call(
            RTCPeerConnectionState.RTCPeerConnectionStateDisconnected,
          );
          peer.onConnectionState?.call(
            RTCPeerConnectionState.RTCPeerConnectionStateConnected,
          );
        }
        final Future<GameStreamInputAck> fresh = receiver.sendInput(_input(3));
        final String rejection = background
            ? 'app_backgrounded'
            : 'connection_disconnected';
        expect((await first).reason, rejection);
        expect((await queued).reason, rejection);
        sendGate.complete();
        await Future<void>.delayed(Duration.zero);
        channel.ack(3);
        expect((await fresh).accepted, isTrue);
        expect(
          channel.sent.map((Map<String, dynamic> message) => message['kind']),
          <String>['input', 'releaseAll', 'input'],
        );
        expect(
          channel.sent
              .where(
                (Map<String, dynamic> message) => message['kind'] == 'input',
              )
              .map(
                (Map<String, dynamic> message) =>
                    (message['event'] as Map<String, dynamic>)['sequence'],
              ),
          <int>[1, 3],
          reason:
              'Input already rejected on pause must not reach the game later',
        );
        expect(channel.sent[1]['sessionId'], 'session');
        expect(channel.sent[1]['clientId'], 'phone');
      },
    );
  }

  test(
    'renderer initializes once across reconnect and no stale callbacks notify after dispose',
    () async {
      await receiver.connect(sessionId: 'session', clientId: 'phone');
      final Function(RTCPeerConnectionState)? callback = peer.onConnectionState;
      await receiver.disconnect();
      await receiver.connect(sessionId: 'next-session', clientId: 'phone');
      expect(renderer.initializeCount, 1);
      int notifications = 0;
      receiver.addListener(() => notifications++);
      receiver.dispose();
      callback?.call(RTCPeerConnectionState.RTCPeerConnectionStateConnected);
      await Future<void>.delayed(Duration.zero);
      expect(notifications, 0);
      expect(renderer.disposeCount, 1);
    },
  );

  test(
    'dispose during renderer initialization cleans up only after initialization',
    () async {
      renderer.initializeGate = Completer<void>();
      final Future<void> connecting = receiver.connect(
        sessionId: 'session',
        clientId: 'phone',
      );
      await Future<void>.value();
      await Future<void>.value();
      receiver.dispose();
      expect(renderer.disposeCount, 0);
      renderer.initializeGate!.complete();
      await connecting;
      await Future<void>.delayed(Duration.zero);
      expect(renderer.initializeCount, 1);
      expect(renderer.disposeCount, 1);
      expect(peer.disposeCount, 0);
    },
  );
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:fushi/src/sync/game_stream_host.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_service.dart';

const int _hwnd = 12345;
const String _peerId = 'late-peer';

/// Exercise the real flutter_webrtc Dart objects, including their disposal
/// methods, while delaying only the native allocation response under test.
class _NativeHost {
  _NativeHost(this.delayedMethod);

  final String delayedMethod;
  final Completer<Object?> allocation = Completer<Object?>();
  final List<MethodCall> rtcCalls = <MethodCall>[];
  final List<MethodCall> inputCalls = <MethodCall>[];
  bool allocationPending = false;
  int controlCount = 0;

  Future<Object?> rtc(MethodCall call) async {
    rtcCalls.add(call);
    if (call.method == delayedMethod) {
      allocationPending = true;
      return allocation.future;
    }
    switch (call.method) {
      case 'initialize':
      case 'trackDispose':
      case 'streamDispose':
      case 'peerConnectionClose':
      case 'peerConnectionDispose':
      case 'setLocalDescription':
      case 'dataChannelClose':
      case 'dataChannelSend':
        return null;
      case 'getDesktopSources':
        return <String, Object?>{
          'sources': <Object?>[
            <String, Object?>{
              'id': '$_hwnd',
              'name': 'Bound game',
              'type': 'window',
              'thumbnailSize': <String, int>{'width': 1, 'height': 1},
            },
          ],
        };
      case 'getDisplayMedia':
        return capture;
      case 'createPeerConnection':
        return <String, Object?>{'peerConnectionId': _peerId};
      case 'addTrack':
        return <String, Object?>{
          'senderId': (call.arguments as Map)['trackId'],
          'track': <String, Object?>{},
          'ownsTrack': false,
          'rtpParameters': <String, Object?>{
            'encodings': <Object?>[],
            'headerExtensions': <Object?>[],
            'codecs': <Object?>[],
            'rtcp': <String, Object?>{'reducedSize': false},
          },
        };
      case 'createDataChannel':
        return <String, Object?>{
          'id': 1,
          'flutterId': 'control-${++controlCount}',
        };
      case 'createOffer':
        return <String, Object?>{'sdp': 'test-offer', 'type': 'offer'};
      case 'getSenders':
        return <String, Object?>{'senders': <Object?>[]};
      case 'getStats':
        return <String, Object?>{'stats': <Object?>[]};
      default:
        throw StateError('Unexpected WebRTC call after cancellation: $call');
    }
  }

  Future<Object?> input(MethodCall call) async {
    inputCalls.add(call);
    if (call.method == delayedMethod) {
      allocationPending = true;
      return allocation.future;
    }
    switch (call.method) {
      case 'bind':
      case 'activate':
      case 'send':
      case 'release':
      case 'unbind':
        return null;
      case 'inspect':
        return <String, Object?>{
          'alive': true,
          'processMatches': true,
          'visible': true,
          'minimized': false,
          'width': 1920,
          'height': 1080,
        };
      default:
        throw StateError('Unexpected input call: $call');
    }
  }

  static Map<String, Object?> get capture => <String, Object?>{
    'streamId': 'late-capture',
    'audioTracks': <Object?>[_track('audio')],
    'videoTracks': <Object?>[_track('video')],
  };

  static Map<String, Object?> _track(String kind) => <String, Object?>{
    'id': '$kind-track',
    'label': kind,
    'kind': kind,
    'enabled': true,
    'settings': <String, Object>{
      'width': 1920,
      'height': 1080,
      'fushiClientArea': true,
    },
  };
}

Future<void> _flushUntil(WidgetTester tester, bool Function() complete) async {
  for (int attempt = 0; attempt < 30 && !complete(); attempt++) {
    // Stream subscription cancellation can complete through a root-zone
    // Future cached by dart:async; allow that queue to drain as well.
    await tester.runAsync(() async {});
    await tester.pump(const Duration(milliseconds: 1));
  }
  expect(complete(), isTrue, reason: 'Expected asynchronous native phase');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'control-only close releases acknowledged input and old close cannot stop restart',
    (WidgetTester tester) async {
      final _NativeHost native = _NativeHost('never-delayed');
      final TestDefaultBinaryMessenger messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const MethodChannel rtc = MethodChannel('FlutterWebRTC.Method');
      const MethodChannel input = MethodChannel('app.fushi/game_stream_input');
      const MethodChannel events = MethodChannel('FlutterWebRTC.Event');
      const MethodChannel peerEvents = MethodChannel(
        'FlutterWebRTC/peerConnectionEvent$_peerId',
      );
      const String controlOne =
          'FlutterWebRTC/dataChannelEvent${_peerId}control-1';
      const String controlTwo =
          'FlutterWebRTC/dataChannelEvent${_peerId}control-2';
      final List<MethodChannel> channels = <MethodChannel>[
        rtc,
        input,
        events,
        peerEvents,
        const MethodChannel(controlOne),
        const MethodChannel(controlTwo),
      ];
      messenger.setMockMethodCallHandler(rtc, native.rtc);
      messenger.setMockMethodCallHandler(input, native.input);
      for (final MethodChannel channel in channels.skip(2)) {
        messenger.setMockMethodCallHandler(channel, (_) async => null);
      }
      final FushiRemoteGameStreamService service =
          FushiRemoteGameStreamService();
      final FushiGameStreamHost host = FushiGameStreamHost(service: service);
      Future<void> emit(String channel, Map<String, Object?> event) async {
        await messenger.handlePlatformMessage(
          channel,
          const StandardMethodCodec().encodeSuccessEnvelope(event),
          (_) {},
        );
        await tester.pump();
      }

      Future<GameStreamSession> start() async {
        GameStreamSession? session;
        Object? failure;
        StackTrace? failureStack;
        final Future<void> starting = host
            .start(hwnd: _hwnd)
            .then<void>(
              (GameStreamSession value) => session = value,
              onError: (Object error, StackTrace stack) {
                failure = error;
                failureStack = stack;
              },
            );
        await _flushUntil(tester, () => session != null || failure != null);
        expect(failure, isNull, reason: failureStack?.toString());
        await starting;
        return session!;
      }

      Future<void> stop() async {
        bool complete = false;
        final Future<void> stopping = host.stop().then<void>(
          (_) => complete = true,
        );
        await _flushUntil(tester, () => complete);
        await stopping;
      }

      try {
        final GameStreamSession first = await start();
        final void Function(RTCDataChannelState)? oldStateCallback =
            host.debugControlChannel!.onDataChannelState;
        service.joinSession(sessionId: first.sessionId, clientId: 'client');
        await emit(peerEvents.name, <String, Object?>{
          'event': 'peerConnectionState',
          'state': 'connected',
        });
        await emit(controlOne, <String, Object?>{
          'event': 'dataChannelStateChanged',
          'id': 1,
          'state': 'open',
        });
        expect(host.started, isTrue);
        expect(service.session?.state, GameStreamSessionState.connected);
        expect(
          native.inputCalls.where((MethodCall c) => c.method == 'unbind'),
          isEmpty,
        );
        await emit(controlOne, <String, Object?>{
          'event': 'dataChannelReceiveMessage',
          'id': 1,
          'type': 'text',
          'data': jsonEncode(<String, Object?>{
            'kind': 'input',
            'event': <String, Object?>{
              'version': 1,
              'sessionId': first.sessionId,
              'clientId': 'client',
              'sequence': 1,
              'timestampMs': DateTime.now().millisecondsSinceEpoch,
              'kind': 'key',
              'action': 'down',
              'key': 'Enter',
            },
          }),
        });
        await _flushUntil(
          tester,
          () => native.rtcCalls.any(
            (MethodCall c) => c.method == 'dataChannelSend',
          ),
        );
        final Map<String, dynamic> ack =
            jsonDecode(
                  (native.rtcCalls
                              .lastWhere(
                                (MethodCall c) => c.method == 'dataChannelSend',
                              )
                              .arguments
                          as Map)['data']
                      as String,
                )
                as Map<String, dynamic>;
        expect((ack['ack'] as Map)['accepted'], isTrue);
        expect(
          native.inputCalls.where((MethodCall c) => c.method == 'send'),
          hasLength(1),
        );

        // No peerConnectionState disconnected/failed event is delivered.
        await emit(controlOne, <String, Object?>{
          'event': 'dataChannelStateChanged',
          'id': 1,
          'state': 'closed',
        });
        await _flushUntil(
          tester,
          () =>
              !host.started &&
              native.inputCalls.any((MethodCall c) => c.method == 'unbind'),
        );
        await stop();
        expect(first.state, GameStreamSessionState.stopped);
        expect(first.reason, 'control_channel_closed');
        expect(
          native.inputCalls.where((MethodCall c) => c.method == 'unbind'),
          hasLength(1),
        );
        expect(
          native.rtcCalls.where((MethodCall c) => c.method == 'trackDispose'),
          hasLength(2),
        );
        expect(
          native.rtcCalls.where(
            (MethodCall c) => c.method == 'peerConnectionDispose',
          ),
          hasLength(1),
        );

        final GameStreamSession second = await start();
        expect(second.sessionId, isNot(first.sessionId));
        oldStateCallback!(RTCDataChannelState.RTCDataChannelClosed);
        await tester.pump(const Duration(milliseconds: 1));
        expect(host.started, isTrue);
        expect(second.state.isTerminal, isFalse);
        expect(
          native.inputCalls.where((MethodCall c) => c.method == 'unbind'),
          hasLength(1),
        );
        await stop();
      } finally {
        await stop();
        host.dispose();
        service.dispose();
        await tester.pump(const Duration(milliseconds: 1));
        for (final MethodChannel channel in channels) {
          messenger.setMockMethodCallHandler(channel, null);
        }
      }
    },
    skip: !Platform.isWindows,
  );

  testWidgets('rejects an unpatched whole-window capture backend', (
    WidgetTester tester,
  ) async {
    final _NativeHost native = _NativeHost('never-delayed');
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const MethodChannel rtc = MethodChannel('FlutterWebRTC.Method');
    const MethodChannel input = MethodChannel('app.fushi/game_stream_input');
    const MethodChannel events = MethodChannel('FlutterWebRTC.Event');
    messenger.setMockMethodCallHandler(rtc, (MethodCall call) async {
      if (call.method != 'getDisplayMedia') return native.rtc(call);
      final Map<String, Object?> capture = _NativeHost.capture;
      final Map<String, Object?> track =
          (capture['videoTracks']! as List<Object?>).single!
              as Map<String, Object?>;
      (track['settings']! as Map<String, Object>).remove('fushiClientArea');
      return capture;
    });
    messenger.setMockMethodCallHandler(input, native.input);
    messenger.setMockMethodCallHandler(events, (_) async => null);
    final FushiRemoteGameStreamService service = FushiRemoteGameStreamService();
    final FushiGameStreamHost host = FushiGameStreamHost(service: service);
    try {
      Object? failure;
      bool completed = false;
      final Future<void> starting = host
          .start(hwnd: _hwnd)
          .then<void>(
            (_) => completed = true,
            onError: (Object error) {
              failure = error;
              completed = true;
            },
          );
      await _flushUntil(tester, () => completed);
      await starting;
      expect(failure.toString(), contains('capture adapter is unavailable'));
      expect(host.started, isFalse);
      expect(service.session?.state.isTerminal, isTrue);
      expect(
        native.rtcCalls.where((MethodCall c) => c.method == 'trackDispose'),
        hasLength(2),
      );
      expect(
        native.rtcCalls.where(
          (MethodCall c) => c.method == 'createPeerConnection',
        ),
        isEmpty,
      );
    } finally {
      host.dispose();
      service.dispose();
      await tester.pump(const Duration(milliseconds: 1));
      for (final MethodChannel channel in <MethodChannel>[rtc, input, events]) {
        messenger.setMockMethodCallHandler(channel, null);
      }
    }
  }, skip: !Platform.isWindows);

  for (final String delayedMethod in <String>[
    'bind',
    'activate',
    'getDisplayMedia',
    'createPeerConnection',
  ]) {
    testWidgets(
      'stop during $delayedMethod releases late resources and stays stopped',
      (WidgetTester tester) async {
        final _NativeHost native = _NativeHost(delayedMethod);
        final TestDefaultBinaryMessenger messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const MethodChannel rtc = MethodChannel('FlutterWebRTC.Method');
        const MethodChannel input = MethodChannel(
          'app.fushi/game_stream_input',
        );
        const MethodChannel events = MethodChannel('FlutterWebRTC.Event');
        const MethodChannel peerEvents = MethodChannel(
          'FlutterWebRTC/peerConnectionEvent$_peerId',
        );
        messenger.setMockMethodCallHandler(rtc, native.rtc);
        messenger.setMockMethodCallHandler(input, native.input);
        messenger.setMockMethodCallHandler(events, (_) async => null);
        messenger.setMockMethodCallHandler(peerEvents, (_) async => null);
        final FushiRemoteGameStreamService service =
            FushiRemoteGameStreamService();
        final FushiGameStreamHost host = FushiGameStreamHost(service: service);
        try {
          Object? startError;
          bool startCompleted = false;
          final Future<void> starting = host
              .start(
                hwnd: _hwnd,
                // Window-only streaming never activates; only the foreground
                // input mode reaches the activate phase.
                settings: delayedMethod == 'activate'
                    ? const GameStreamVideoSettings(
                        inputFocus: GameStreamInputFocus.foreground,
                      )
                    : const GameStreamVideoSettings(),
              )
              .then<void>(
                (_) => startCompleted = true,
                onError: (Object error, StackTrace stack) {
                  startError = error;
                  startCompleted = true;
                },
              );
          await _flushUntil(tester, () => native.allocationPending);
          expect(host.starting, isTrue);
          expect(host.started, isFalse);

          bool stopCompleted = false;
          final Future<void> stopping = host.stop().then<void>(
            (_) => stopCompleted = true,
          );
          await _flushUntil(tester, () => stopCompleted);
          await stopping;
          expect(startCompleted, isFalse);
          expect(service.session!.state.isTerminal, isTrue);
          if (delayedMethod != 'bind') {
            expect(
              native.inputCalls.where((MethodCall c) => c.method == 'unbind'),
              hasLength(1),
            );
          }

          native.allocation.complete(switch (delayedMethod) {
            'getDisplayMedia' => _NativeHost.capture,
            'createPeerConnection' => <String, Object?>{
              'peerConnectionId': _peerId,
            },
            _ => null,
          });
          await _flushUntil(tester, () => startCompleted).catchError((
            Object e,
          ) {
            // Include the boundary reached if the cancellation stalls.
            fail('$e\nRTC: ${native.rtcCalls}\nInput: ${native.inputCalls}');
          });
          await starting;
          expect(startError, isA<StateError>());
          expect(startError.toString(), contains('Capture cancelled'));
          expect(host.started, isFalse);
          expect(host.starting, isFalse);
          expect(service.session!.state, GameStreamSessionState.stopped);
          expect(
            native.inputCalls.where((MethodCall c) => c.method == 'unbind'),
            hasLength(1),
          );
          if (delayedMethod == 'getDisplayMedia' ||
              delayedMethod == 'createPeerConnection') {
            expect(
              native.inputCalls.any((MethodCall c) => c.method == 'activate'),
              isFalse,
              reason: 'Window-only streaming must not pull the game forward',
            );
          }

          if (delayedMethod == 'getDisplayMedia' ||
              delayedMethod == 'createPeerConnection') {
            expect(
              native.rtcCalls
                  .where((MethodCall c) => c.method == 'trackDispose')
                  .map((MethodCall c) => (c.arguments as Map)['trackId']),
              unorderedEquals(<String>['audio-track', 'video-track']),
            );
            expect(
              native.rtcCalls
                  .where((MethodCall c) => c.method == 'streamDispose')
                  .map((MethodCall c) => (c.arguments as Map)['streamId']),
              <String>['late-capture'],
            );
          }
          if (delayedMethod == 'createPeerConnection') {
            for (final String method in <String>[
              'peerConnectionClose',
              'peerConnectionDispose',
            ]) {
              expect(
                native.rtcCalls
                    .where((MethodCall c) => c.method == method)
                    .map(
                      (MethodCall c) =>
                          (c.arguments as Map)['peerConnectionId'],
                    ),
                <String>[_peerId],
              );
            }
          }

          // A late completion must not install the 350 ms session pump or the
          // two-second stats timer, nor publish an offer after stop.
          final int rtcCount = native.rtcCalls.length;
          final int inputCount = native.inputCalls.length;
          await tester.pump(const Duration(seconds: 5));
          expect(native.rtcCalls, hasLength(rtcCount));
          expect(native.inputCalls, hasLength(inputCount));
        } finally {
          host.dispose();
          service.dispose();
          await tester.pump(const Duration(milliseconds: 1));
          for (final MethodChannel channel in <MethodChannel>[
            rtc,
            input,
            events,
            peerEvents,
          ]) {
            messenger.setMockMethodCallHandler(channel, null);
          }
        }
      },
      skip: !Platform.isWindows,
    );
  }
}

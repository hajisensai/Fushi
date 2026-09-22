import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:fushi/src/platform/game_stream_input_channel.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_service.dart';

typedef GameStreamHostInput = Future<void> Function(GameStreamInputEvent event);

/// Local-only Windows capture owner. Paired HTTP requests can join an existing
/// session but cannot instantiate this class or select another capture source.
class FushiGameStreamHost extends ChangeNotifier {
  FushiGameStreamHost({required this.service, this.onInput}) {
    service.onInput = (GameStreamInputEvent event, GameStreamSession _) async {
      if (onInput != null) {
        await onInput!(event);
      } else {
        try {
          await GameStreamInputChannel.send(event.toJson());
        } on PlatformException catch (error) {
          throw GameStreamInputRejected(error.code);
        }
      }
    };
    service.onText = (GameStreamTextEvent event) async {
      _pendingTexts.add(event);
      if (_pendingTexts.length > 128) _pendingTexts.removeAt(0);
      await _sendPendingTexts();
    };
    service.onStop = () => stop(reason: service.session?.reason ?? 'stopped');
  }

  final FushiRemoteGameStreamService service;
  final GameStreamHostInput? onInput;
  RTCPeerConnection? _connection;
  MediaStream? _capture;
  RTCDataChannel? _control;
  Timer? _timer;
  Timer? _statsTimer;
  Future<void>? _stopping;
  bool _starting = false;
  bool _pumping = false;
  bool _adapting = false;
  bool _sendingTexts = false;
  bool _disposed = false;
  bool _started = false;
  bool _remoteDescriptionSet = false;
  int _generation = 0;
  int _hostSequence = 0;
  int _clientSequence = -1;
  int? _boundHwnd;
  String? _lastClientId;
  final List<GameStreamTextEvent> _pendingTexts = <GameStreamTextEvent>[];
  final List<RTCIceCandidate> _pendingCandidates = <RTCIceCandidate>[];
  Future<void> _inputs = Future<void>.value();
  double _minimumScale = 1;
  int _bitrate = 8000000;
  String? _error;

  bool get started => _started;
  bool get starting => _starting;
  String? get error => _error;
  GameStreamSession? get session => service.session;

  @visibleForTesting
  Future<List<StatsReport>> debugStats() async =>
      await _connection?.getStats() ?? <StatsReport>[];

  @visibleForTesting
  MediaStream? get debugCaptureStream => _capture;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  Future<GameStreamSession> start({required int hwnd}) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('Game streaming host is Windows-only');
    }
    if (_starting) throw StateError('Capture is already starting');
    if (_stopping != null) await _stopping;
    if (_started) return service.session!;
    _starting = true;
    _error = null;
    final int generation = ++_generation;
    _hostSequence = 0;
    _clientSequence = -1;
    _remoteDescriptionSet = false;
    _pendingCandidates.clear();
    _pendingTexts.clear();
    _bitrate = 8000000;
    final GameStreamSession current = service.createSession(
      windowId: 'hwnd:$hwnd',
    );
    notifyListeners();
    try {
      await GameStreamInputChannel.bind(hwnd);
      if (generation != _generation) {
        await GameStreamInputChannel.unbind();
        throw StateError('Capture cancelled');
      }
      _boundHwnd = hwnd;
      await GameStreamInputChannel.activate();
      _requireGeneration(generation);
      final List<DesktopCapturerSource> sources = await desktopCapturer
          .getSources(
            types: <SourceType>[SourceType.Window],
            thumbnailSize: ThumbnailSize(1, 1),
          );
      _requireGeneration(generation);
      // Upstream Windows source IDs are HWND decimal strings. Never fall back
      // to another window or the desktop if this source disappeared.
      final List<DesktopCapturerSource> matches = sources
          .where(
            (DesktopCapturerSource source) => int.tryParse(source.id) == hwnd,
          )
          .toList();
      if (matches.length != 1) throw StateError('Game window unavailable');
      final Map<String, Object?> info = await GameStreamInputChannel.inspect();
      _requireGeneration(generation);
      if (info['alive'] != true ||
          info['processMatches'] != true ||
          info['minimized'] == true) {
        throw StateError('Game window unavailable for capture');
      }
      final int width = (info['width'] as num?)?.toInt() ?? 1920;
      final int height = (info['height'] as num?)?.toInt() ?? 1080;
      _minimumScale = math.max(1, math.max(width / 1920, height / 1080));
      final MediaStream capture = await navigator.mediaDevices.getDisplayMedia(
        <String, dynamic>{
          'video': <String, dynamic>{
            'deviceId': <String, String>{'exact': matches.single.id},
            'mandatory': <String, double>{'frameRate': 60.0},
            'cursor': 'never',
            // App-owned WGC adapter crops to the exact client area before
            // feeding WebRTC; pointer coordinates use that same client area.
            'fushiClientArea': true,
          },
          'audio': true,
        },
      );
      if (generation != _generation) {
        await _cleanUp(<Future<void> Function()>[
          for (final MediaStreamTrack track in capture.getTracks()) track.stop,
          capture.dispose,
        ]);
        throw StateError('Capture cancelled');
      }
      _capture = capture;
      if (capture.getVideoTracks().isEmpty ||
          capture.getAudioTracks().isEmpty) {
        throw StateError(
          'Window video or application loopback audio is unavailable',
        );
      }
      if (generation != _generation) throw StateError('Capture cancelled');
      final Map<String, Object?> capturedTarget =
          await GameStreamInputChannel.inspect();
      _requireGeneration(generation);
      if (capturedTarget['alive'] != true ||
          capturedTarget['processMatches'] != true ||
          capturedTarget['minimized'] == true ||
          capturedTarget['visible'] != true) {
        throw StateError('Game window changed while capture was starting');
      }
      final Map<String, dynamic> settings = capture
          .getVideoTracks()
          .single
          .getSettings();
      if (settings['fushiClientArea'] != true) {
        throw StateError('Client-area window capture adapter is unavailable');
      }
      final num? captureWidth = settings['width'] as num?;
      final num? captureHeight = settings['height'] as num?;
      if (captureWidth != null && captureHeight != null) {
        _minimumScale = math.max(
          1,
          math.max(captureWidth / 1920, captureHeight / 1080),
        );
      }
      final RTCPeerConnection connection = await createPeerConnection(
        <String, dynamic>{
          'iceServers': <Object>[],
          'sdpSemantics': 'unified-plan',
        },
      );
      if (generation != _generation) {
        await _cleanUp(<Future<void> Function()>[
          connection.close,
          connection.dispose,
        ]);
        throw StateError('Capture cancelled');
      }
      _connection = connection;
      for (final MediaStreamTrack track in capture.getTracks()) {
        await connection.addTrack(track, capture);
        _requireGeneration(generation);
      }
      final RTCDataChannel control = await connection.createDataChannel(
        'fushi-game-control',
        RTCDataChannelInit()..ordered = true,
      );
      if (generation != _generation) {
        await _cleanUp(<Future<void> Function()>[control.close]);
        throw StateError('Capture cancelled');
      }
      _control = control;
      _control!.onMessage = (RTCDataChannelMessage message) {
        if (message.isBinary || message.text.length > 8192) return;
        _inputs = _inputs.then((_) => _receiveControl(message.text));
      };
      _control!.onDataChannelState = (RTCDataChannelState state) {
        if (state == RTCDataChannelState.RTCDataChannelOpen) {
          unawaited(_sendPendingTexts());
        }
      };
      connection.onConnectionState = (RTCPeerConnectionState state) {
        if (generation != _generation || current.state.isTerminal) return;
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          service.markConnected(sessionId: current.sessionId);
          notifyListeners();
        } else if (state ==
            RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          unawaited(stop(reason: 'connection_failed'));
        } else if (state ==
            RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          unawaited(GameStreamInputChannel.release());
        }
      };
      connection.onIceCandidate = (RTCIceCandidate candidate) {
        if (generation != _generation ||
            current.state.isTerminal ||
            candidate.candidate?.isNotEmpty != true) {
          return;
        }
        _publish(current, GameStreamSignalType.iceCandidate, <String, Object?>{
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
      };
      final RTCSessionDescription offer = await connection.createOffer();
      _requireGeneration(generation);
      await connection.setLocalDescription(offer);
      _requireGeneration(generation);
      _publish(current, GameStreamSignalType.offer, <String, Object?>{
        'sdp': offer.sdp,
        'type': 'offer',
      });
      if (generation != _generation) throw StateError('Capture cancelled');
      _started = true;
      await _setVideoParameters();
      _requireGeneration(generation);
      _timer = Timer.periodic(const Duration(milliseconds: 350), (_) {
        unawaited(_pump());
      });
      _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        unawaited(_adaptVideoSender());
      });
      notifyListeners();
      return current;
    } catch (error) {
      _error = '$error';
      await stop(reason: 'capture_failed');
      rethrow;
    } finally {
      _starting = false;
      notifyListeners();
    }
  }

  void _requireGeneration(int generation) {
    if (_disposed || generation != _generation) {
      throw StateError('Capture cancelled');
    }
  }

  void _publish(
    GameStreamSession session,
    GameStreamSignalType type,
    Map<String, Object?> payload,
  ) {
    service.publishSignal(
      GameStreamSignal(
        sessionId: session.sessionId,
        senderId: 'host',
        senderRole: GameStreamPeerRole.host,
        type: type,
        sequence: _hostSequence++,
        payload: payload,
      ),
    );
  }

  Future<void> _pump() async {
    if (_pumping || !_started) return;
    _pumping = true;
    final int generation = _generation;
    try {
      final GameStreamSession? current = service.session;
      final RTCPeerConnection? connection = _connection;
      if (current == null || connection == null) return;
      if (current.state.isTerminal) {
        await stop(reason: current.reason ?? 'stopped');
        return;
      }
      final Map<String, Object?> info = await GameStreamInputChannel.inspect();
      if (generation != _generation) return;
      if (info['alive'] != true ||
          info['processMatches'] != true ||
          info['minimized'] == true ||
          info['visible'] != true) {
        await stop(reason: 'window_unavailable');
        return;
      }
      if (_lastClientId != current.clientId) {
        _lastClientId = current.clientId;
        notifyListeners();
      }
      for (final GameStreamSignal signal in service.signalsFromClient(
        after: _clientSequence,
      )) {
        if (generation != _generation) return;
        if (signal.type == GameStreamSignalType.answer) {
          if (!_remoteDescriptionSet) {
            await connection.setRemoteDescription(
              RTCSessionDescription(signal.payload['sdp'] as String, 'answer'),
            );
            _remoteDescriptionSet = true;
            for (final RTCIceCandidate candidate in _pendingCandidates) {
              await connection.addCandidate(candidate);
            }
            _pendingCandidates.clear();
          }
        } else if (signal.type == GameStreamSignalType.iceCandidate) {
          final RTCIceCandidate candidate = RTCIceCandidate(
            signal.payload['candidate'] as String?,
            signal.payload['sdpMid'] as String?,
            (signal.payload['sdpMLineIndex'] as num?)?.toInt(),
          );
          if (_remoteDescriptionSet) {
            await connection.addCandidate(candidate);
          } else {
            _pendingCandidates.add(candidate);
          }
        }
        _clientSequence = signal.sequence;
      }
    } catch (error) {
      if (generation == _generation) {
        _error = '$error';
        await stop(reason: 'stream_failed');
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _setVideoParameters() async {
    final RTCPeerConnection? connection = _connection;
    if (connection == null) return;
    for (final RTCRtpSender sender in await connection.getSenders()) {
      if (sender.track?.kind != 'video') continue;
      final RTCRtpParameters parameters = sender.parameters;
      for (final RTCRtpEncoding encoding
          in parameters.encodings ?? <RTCRtpEncoding>[]) {
        encoding.maxBitrate = _bitrate;
        encoding.maxFramerate = _bitrate < 4000000 ? 30 : 60;
        encoding.scaleResolutionDownBy =
            _minimumScale * (_bitrate < 3000000 ? 2 : 1);
      }
      if (!await sender.setParameters(parameters)) {
        throw StateError('Video encoding limits were rejected');
      }
    }
  }

  Future<void> _adaptVideoSender() async {
    if (_adapting || !_started || _connection == null) return;
    _adapting = true;
    try {
      double? available;
      double? rtt;
      for (final StatsReport report in await _connection!.getStats()) {
        if (report.type == 'candidate-pair' &&
            report.values['state'] == 'succeeded' &&
            report.values['nominated'] == true) {
          available = (report.values['availableOutgoingBitrate'] as num?)
              ?.toDouble();
          rtt = (report.values['currentRoundTripTime'] as num?)?.toDouble();
        }
      }
      final int previous = _bitrate;
      if (rtt != null && rtt > .1) {
        _bitrate = (_bitrate * .7).round().clamp(1000000, 8000000);
      } else if (available != null) {
        _bitrate = (available * .75).round().clamp(1000000, 8000000);
      }
      if (_started && previous != _bitrate) await _setVideoParameters();
    } catch (error) {
      _error = 'Video adaptation: $error';
      notifyListeners();
    } finally {
      _adapting = false;
    }
  }

  Future<void> _receiveControl(String text) async {
    try {
      final Object? raw = jsonDecode(text);
      if (raw is! Map) return;
      if (raw['kind'] == 'releaseAll') {
        final GameStreamSession? current = session;
        if (current != null &&
            !current.state.isTerminal &&
            raw['sessionId'] == current.sessionId &&
            raw['clientId'] == current.clientId) {
          await GameStreamInputChannel.release();
        }
        return;
      }
      if (raw['kind'] != 'input') return;
      final GameStreamInputEvent input = GameStreamInputEvent.fromJson(
        raw['event'],
      );
      final GameStreamInputAck ack = await service.handleInput(input);
      await _send(<String, Object?>{'kind': 'ack', 'ack': ack.toJson()});
    } on Object catch (error) {
      _error = 'Input rejected: $error';
      notifyListeners();
    }
  }

  Future<void> _sendPendingTexts() async {
    if (_sendingTexts) return;
    _sendingTexts = true;
    final int generation = _generation;
    try {
      while (_pendingTexts.isNotEmpty && generation == _generation) {
        final RTCDataChannel? channel = _control;
        if (channel?.state != RTCDataChannelState.RTCDataChannelOpen) return;
        final GameStreamTextEvent event = _pendingTexts.removeAt(0);
        await _send(<String, Object?>{'kind': 'text', 'event': event.toJson()});
      }
    } finally {
      _sendingTexts = false;
    }
  }

  Future<void> _send(Map<String, Object?> value) async {
    final RTCDataChannel? channel = _control;
    if (channel?.state != RTCDataChannelState.RTCDataChannelOpen) return;
    try {
      await channel!.send(RTCDataChannelMessage(jsonEncode(value)));
    } catch (error) {
      _error = 'Control channel: $error';
      notifyListeners();
    }
  }

  Future<void> stop({String reason = 'stopped'}) {
    final Future<void>? active = _stopping;
    if (active != null) return active;
    // Schedule teardown after recording its future so service.onStop re-entry
    // returns the same work instead of disposing a peer connection twice.
    final Future<void> stopping = Future<void>(() => _stop(reason));
    _stopping = stopping;
    return stopping.whenComplete(() => _stopping = null);
  }

  Future<void> _stop(String reason) async {
    ++_generation;
    _started = false;
    _timer?.cancel();
    _statsTimer?.cancel();
    _timer = null;
    _statsTimer = null;
    final GameStreamSession? current = session;
    if (current != null && !current.state.isTerminal) {
      service.stop(sessionId: current.sessionId, reason: reason);
    }
    final MediaStream? capture = _capture;
    final RTCPeerConnection? connection = _connection;
    final RTCDataChannel? control = _control;
    _capture = null;
    _connection = null;
    _control = null;
    _pendingTexts.clear();
    _lastClientId = null;
    final List<Future<void> Function()> cleanup = <Future<void> Function()>[
      if (_boundHwnd != null) GameStreamInputChannel.unbind,
      for (final MediaStreamTrack track
          in capture?.getTracks() ?? <MediaStreamTrack>[])
        track.stop,
      if (control != null) control.close,
      if (connection != null) connection.close,
      if (connection != null) connection.dispose,
      if (capture != null) capture.dispose,
    ];
    _boundHwnd = null;
    await _cleanUp(cleanup);
    notifyListeners();
  }

  Future<void> _cleanUp(Iterable<Future<void> Function()> cleanup) async {
    for (final Future<void> Function() action in cleanup) {
      try {
        await action();
      } catch (error) {
        _error = 'Stream cleanup: $error';
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}

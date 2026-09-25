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

/// Specific rejection reason from the Windows runner: it reports
/// `input_rejected` as the code and the reason (window_not_foreground,
/// unsupported_native_pointer, …) as the message.
String gameStreamInputRejectionReason(PlatformException error) {
  final String? message = error.message;
  return message != null &&
          message.isNotEmpty &&
          message.length <= 64 &&
          RegExp(r'^[a-z0-9_]+$').hasMatch(message)
      ? message
      : error.code;
}

/// `scaleResolutionDownBy` that brings [captureHeight] under [maxHeight].
double gameStreamResolutionScale({
  required int captureHeight,
  required int maxHeight,
}) => captureHeight <= maxHeight || maxHeight <= 0
    ? 1
    : captureHeight / maxHeight;

/// Encoder bitrate bounds in bits per second.
///
/// WebRTC's own congestion controller (GCC) already keeps the encoder under
/// its bandwidth estimate, so the host only states bounds and never feeds the
/// estimate back into `maxBitrate`: doing that capped the probe ceiling, the
/// estimate followed the cap down and a steady LAN ratcheted to the floor —
/// most visibly on still visual-novel screens, whose tiny send rate keeps the
/// estimate low. [max] is the receiver's target; [start] skips libwebrtc's
/// 300 kbps default ramp so the first seconds are not blurry. Adaptive keeps a
/// floor of at most 1 Mbps; fixed pins all three to the target (Moonlight's
/// fixed-bitrate behaviour).
({int min, int start, int max}) gameStreamBitrateWindow({
  required int targetBps,
  required bool adaptive,
}) {
  if (!adaptive) return (min: targetBps, start: targetBps, max: targetBps);
  final int floor = math.min(1000000, targetBps);
  return (
    min: floor,
    start: (targetBps ~/ 2).clamp(floor, targetBps),
    max: targetBps,
  );
}

const Set<String> _kVideoSdpHelperCodecs = <String>{
  'rtx',
  'red',
  'ulpfec',
  'flexfec-03',
};

/// Sets `x-google-start-bitrate` (kbps) on every media codec of the video
/// section of [sdp]. Applied by the sender to the remote answer: libwebrtc's
/// send-side bandwidth estimator starts from it instead of 300 kbps. Only the
/// start rate goes through SDP because it only matters at negotiation; the
/// floor and ceiling stay with `setParameters`, which a later settings update
/// can move — a `x-google-min/max-bitrate` pinned here would outlive it, so
/// any such value in the answer is dropped. Retransmission / FEC payloads are
/// left untouched.
String gameStreamTuneVideoSdp(String sdp, {required int startKbps}) {
  final String eol = sdp.contains('\r\n') ? '\r\n' : '\n';
  final List<String> lines = sdp.split(eol);
  final String params = 'x-google-start-bitrate=$startKbps';
  final RegExp rtpmap = RegExp(r'^a=rtpmap:(\d+) ([^/\s]+)/');
  final RegExp fmtp = RegExp(r'^a=fmtp:(\d+) (.*)$');
  final RegExp existing = RegExp(r'^x-google-(min|start|max)-bitrate=');
  final List<String> out = <String>[];
  int sectionStart = -1;
  bool video = false;

  void finishSection() {
    if (!video || sectionStart < 0) return;
    final List<String> section = out.sublist(sectionStart);
    final Set<String> media = <String>{};
    for (final String line in section) {
      final RegExpMatch? match = rtpmap.firstMatch(line);
      if (match != null &&
          !_kVideoSdpHelperCodecs.contains(match.group(2)!.toLowerCase())) {
        media.add(match.group(1)!);
      }
    }
    final Set<String> tuned = <String>{};
    final List<String> rewritten = <String>[];
    for (final String line in section) {
      final RegExpMatch? match = fmtp.firstMatch(line);
      if (match != null && media.contains(match.group(1))) {
        final List<String> kept = match
            .group(2)!
            .split(';')
            .map((String part) => part.trim())
            .where((String part) => part.isNotEmpty && !existing.hasMatch(part))
            .toList();
        rewritten.add(
          'a=fmtp:${match.group(1)} ${[...kept, params].join(';')}',
        );
        tuned.add(match.group(1)!);
      } else {
        rewritten.add(line);
      }
    }
    // Codecs such as VP8 carry no fmtp line: add one right after the rtpmap.
    for (int i = 0; i < rewritten.length; i++) {
      final RegExpMatch? match = rtpmap.firstMatch(rewritten[i]);
      final String? pt = match?.group(1);
      if (pt != null && media.contains(pt) && tuned.add(pt)) {
        rewritten.insert(i + 1, 'a=fmtp:$pt $params');
      }
    }
    out
      ..removeRange(sectionStart, out.length)
      ..addAll(rewritten);
  }

  for (final String line in lines) {
    if (line.startsWith('m=')) {
      finishSection();
      sectionStart = out.length;
      video = line.startsWith('m=video ');
    }
    out.add(line);
  }
  finishSection();
  return out.join(eol);
}

/// Local-only Windows capture owner. Paired HTTP requests can join an existing
/// session but cannot instantiate this class or select another capture source.
class FushiGameStreamHost extends ChangeNotifier {
  FushiGameStreamHost({required this.service, this.onInput}) {
    service.onInput = (GameStreamInputEvent event, GameStreamSession _) async {
      if (onInput != null) {
        await onInput!(event);
      } else {
        try {
          await GameStreamInputChannel.send(<String, Object?>{
            ...event.toJson(),
            'inputFocus': _settings.inputFocus.name,
          });
        } on PlatformException catch (error) {
          // The runner reports the specific reason (e.g. unsupported pointer,
          // window hidden) as the message; `code` is always input_rejected.
          throw GameStreamInputRejected(gameStreamInputRejectionReason(error));
        }
      }
    };
    service.onSettings = applySettings;
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
  Future<void>? _stopping;
  bool _starting = false;
  bool _pumping = false;
  bool _connected = false;
  DateTime _lastPump = DateTime.fromMillisecondsSinceEpoch(0);
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
  GameStreamVideoSettings _settings = const GameStreamVideoSettings();
  int _captureHeight = 1080;
  String? _error;

  /// Parameters in effect for the current session.
  GameStreamVideoSettings get settings => _settings;

  ({int min, int start, int max}) get _bitrates => gameStreamBitrateWindow(
    targetBps: _settings.bitrateKbps * 1000,
    adaptive: _settings.adaptiveBitrate,
  );

  bool get started => _started;
  bool get starting => _starting;
  String? get error => _error;
  GameStreamSession? get session => service.session;

  @visibleForTesting
  Future<List<StatsReport>> debugStats() async =>
      await _connection?.getStats() ?? <StatsReport>[];

  @visibleForTesting
  MediaStream? get debugCaptureStream => _capture;

  @visibleForTesting
  RTCDataChannel? get debugControlChannel => _control;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  /// Starts capturing [hwnd]. [settings] fixes the capture ceiling (a later
  /// join can lower resolution/fps/bitrate, never raise them above it).
  /// [launchId] reserves the session for the peer that launched the game.
  Future<GameStreamSession> start({
    required int hwnd,
    GameStreamVideoSettings settings = const GameStreamVideoSettings(),
    String? gameId,
    String? gameTitle,
    String? launchId,
  }) async {
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
    _settings = settings;
    _captureHeight = settings.maxHeight;
    _connected = false;
    final GameStreamSession current = service.createSession(
      windowId: 'hwnd:$hwnd',
      gameId: gameId,
      gameTitle: gameTitle,
      settings: settings,
      launchId: launchId,
    );
    notifyListeners();
    try {
      await GameStreamInputChannel.bind(hwnd);
      if (generation != _generation) {
        await GameStreamInputChannel.unbind();
        throw StateError('Capture cancelled');
      }
      _boundHwnd = hwnd;
      // Window-only streaming: WGC captures an occluded window and input is
      // posted to this HWND, so the game may stay behind other windows. Only
      // the foreground input mode brings it forward, and a refused activation
      // there is not fatal — input activates again on the next press.
      if (settings.inputFocus == GameStreamInputFocus.foreground) {
        try {
          await GameStreamInputChannel.activate();
        } on PlatformException catch (error) {
          _error = 'Activation: ${gameStreamInputRejectionReason(error)}';
        }
      }
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
      final MediaStream capture = await navigator.mediaDevices.getDisplayMedia(
        <String, dynamic>{
          'video': <String, dynamic>{
            'deviceId': <String, String>{'exact': matches.single.id},
            // The runner's WGC adapter scales the client area to fit inside
            // maxWidth × maxHeight and paces frames to frameRate.
            'mandatory': <String, Object>{
              'frameRate': settings.maxFps.toDouble(),
              'maxWidth': settings.maxWidth,
              'maxHeight': settings.maxHeight,
            },
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
      final Map<String, dynamic> trackSettings = capture
          .getVideoTracks()
          .single
          .getSettings();
      if (trackSettings['fushiClientArea'] != true) {
        throw StateError('Client-area window capture adapter is unavailable');
      }
      final num? captureHeight = trackSettings['height'] as num?;
      if (captureHeight != null && captureHeight > 0) {
        _captureHeight = captureHeight.round();
      }
      final RTCPeerConnection connection = await createPeerConnection(
        <String, dynamic>{
          'iceServers': <Object>[],
          'sdpSemantics': 'unified-plan',
          // One transport for audio, video and control: a single ICE check
          // list connects sooner and one path cannot fail independently.
          'bundlePolicy': 'max-bundle',
          'rtcpMuxPolicy': 'require',
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
        if (generation != _generation ||
            !identical(_control, control) ||
            service.session?.sessionId != current.sessionId ||
            current.state.isTerminal) {
          return;
        }
        if (state == RTCDataChannelState.RTCDataChannelOpen) {
          unawaited(_sendPendingTexts());
        } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
          unawaited(stop(reason: 'control_channel_closed'));
        }
      };
      connection.onConnectionState = (RTCPeerConnectionState state) {
        if (generation != _generation || current.state.isTerminal) return;
        _connected =
            state == RTCPeerConnectionState.RTCPeerConnectionStateConnected;
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
      _timer = Timer.periodic(kGameStreamNegotiationPoll, (_) {
        final DateTime now = DateTime.now();
        if (_connected &&
            now.difference(_lastPump) < kGameStreamConnectedPoll) {
          return;
        }
        _lastPump = now;
        unawaited(_pump());
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
              RTCSessionDescription(
                gameStreamTuneVideoSdp(
                  signal.payload['sdp'] as String,
                  startKbps: _bitrates.start ~/ 1000,
                ),
                'answer',
              ),
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

  /// Applies a receiver's request to the running encoder. Resolution and fps
  /// can only go down from the capture ceiling chosen at [start]; the
  /// returned settings are what is actually in effect.
  @visibleForTesting
  Future<GameStreamVideoSettings> applySettings(
    GameStreamVideoSettings requested,
  ) async {
    final GameStreamVideoSettings ceiling =
        service.session?.settings ?? _settings;
    final GameStreamVideoSettings effective = requested.copyWith(
      maxHeight: math.min(requested.maxHeight, _captureHeight),
      maxFps: math.min(requested.maxFps, ceiling.maxFps),
    );
    _settings = effective;
    if (_started) await _setVideoParameters();
    notifyListeners();
    return effective;
  }

  Future<void> _setVideoParameters() async {
    final RTCPeerConnection? connection = _connection;
    if (connection == null) return;
    final GameStreamVideoSettings settings = _settings;
    final ({int min, int start, int max}) rates = _bitrates;
    for (final RTCRtpSender sender in await connection.getSenders()) {
      if (sender.track?.kind != 'video') continue;
      final RTCRtpParameters parameters = sender.parameters;
      for (final RTCRtpEncoding encoding
          in parameters.encodings ?? <RTCRtpEncoding>[]) {
        encoding.minBitrate = rates.min;
        encoding.maxBitrate = rates.max;
        // DSCP marking on the LAN path: Wi-Fi WMM queues the video ahead of
        // background traffic from the same host.
        encoding.networkPriority = RTCPriorityType.high;
        encoding.maxFramerate = settings.maxFps;
        encoding.scaleResolutionDownBy = gameStreamResolutionScale(
          captureHeight: _captureHeight,
          maxHeight: settings.maxHeight,
        );
      }
      parameters.degradationPreference = switch (settings.degradation) {
        GameStreamDegradation.balanced => RTCDegradationPreference.BALANCED,
        GameStreamDegradation.maintainFramerate =>
          RTCDegradationPreference.MAINTAIN_FRAMERATE,
        GameStreamDegradation.maintainResolution =>
          RTCDegradationPreference.MAINTAIN_RESOLUTION,
      };
      if (!await sender.setParameters(parameters)) {
        throw StateError('Video encoding limits were rejected');
      }
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
    _connected = false;
    _timer?.cancel();
    _timer = null;
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

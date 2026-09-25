import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';

enum GameStreamReceiverState {
  idle,
  connecting,
  connected,
  reconnecting,
  failed,
  closed,
}

typedef GameStreamPeerFactory = Future<RTCPeerConnection> Function();

/// Codec list with [codec]'s entries first, the rest in their original order
/// (so RTX/RED/FEC stay available). Null when the device cannot decode it.
List<RTCRtpCodecCapability>? gameStreamPreferredCodecs(
  List<RTCRtpCodecCapability> available,
  GameStreamCodec codec,
) {
  final String? subtype = codec.mimeSubtype;
  if (subtype == null) return null;
  bool matches(RTCRtpCodecCapability c) =>
      c.mimeType.toLowerCase() == 'video/${subtype.toLowerCase()}';
  final List<RTCRtpCodecCapability> preferred = available
      .where(matches)
      .toList();
  if (preferred.isEmpty) return null;
  return <RTCRtpCodecCapability>[
    ...preferred,
    ...available.where((RTCRtpCodecCapability c) => !matches(c)),
  ];
}

/// Moonlight-style performance numbers derived from one `getStats` sample.
@immutable
class GameStreamStatsSample {
  const GameStreamStatsSample({
    required this.timestampMs,
    required this.bytesReceived,
    this.width,
    this.height,
    this.framesPerSecond,
    this.bitrateKbps,
    this.roundTripMs,
    this.jitterMs,
    this.packetsLost,
    this.packetsReceived,
    this.framesDropped,
    this.codec,
    this.decoder,
  });

  factory GameStreamStatsSample.fromReports(
    List<StatsReport> reports, {
    GameStreamStatsSample? previous,
    // Sample time; tests pin it, production reads the wall clock.
    int? nowMs,
  }) {
    Map<dynamic, dynamic>? video;
    double? rtt;
    final Map<String, String> codecs = <String, String>{};
    for (final StatsReport report in reports) {
      final Map<dynamic, dynamic> values = report.values;
      if (report.type == 'inbound-rtp' &&
          (values['kind'] ?? values['mediaType']) == 'video') {
        video = values;
      } else if (report.type == 'candidate-pair' &&
          values['state'] == 'succeeded' &&
          values['nominated'] == true) {
        rtt = (values['currentRoundTripTime'] as num?)?.toDouble();
      } else if (report.type == 'codec') {
        final Object? mime = values['mimeType'];
        if (mime is String) codecs[report.id] = mime.split('/').last;
      }
    }
    num? number(String key) => video?[key] is num ? video![key] as num : null;
    final int timestampMs = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final int bytes = number('bytesReceived')?.toInt() ?? 0;
    int? bitrate;
    if (previous != null &&
        timestampMs > previous.timestampMs &&
        bytes >= previous.bytesReceived) {
      bitrate =
          ((bytes - previous.bytesReceived) *
                  8 /
                  (timestampMs - previous.timestampMs))
              .round();
    }
    final Object? codecId = video?['codecId'];
    final Object? decoder = video?['decoderImplementation'];
    return GameStreamStatsSample(
      timestampMs: timestampMs,
      bytesReceived: bytes,
      width: number('frameWidth')?.toInt(),
      height: number('frameHeight')?.toInt(),
      framesPerSecond: number('framesPerSecond')?.toDouble(),
      bitrateKbps: bitrate,
      roundTripMs: rtt == null ? null : (rtt * 1000).round(),
      jitterMs: number('jitter') == null
          ? null
          : (number('jitter')! * 1000).round(),
      packetsLost: number('packetsLost')?.toInt(),
      packetsReceived: number('packetsReceived')?.toInt(),
      framesDropped: number('framesDropped')?.toInt(),
      codec: codecId is String ? codecs[codecId] : null,
      decoder: decoder is String && decoder.isNotEmpty ? decoder : null,
    );
  }

  final int timestampMs;
  final int bytesReceived;
  final int? width;
  final int? height;
  final double? framesPerSecond;
  final int? bitrateKbps;
  final int? roundTripMs;
  final int? jitterMs;
  final int? packetsLost;
  final int? packetsReceived;
  final int? framesDropped;
  final String? codec;
  final String? decoder;

  /// Lost packets as a share of all expected packets, 0..100.
  double? get lossPercent {
    final int? lost = packetsLost;
    final int? received = packetsReceived;
    if (lost == null || received == null || lost + received <= 0) return null;
    return lost * 100 / (lost + received);
  }
}

/// Android receiver for an already joined Fushi session. The host owns SDP
/// negotiation and creates the reliable, ordered `fushi-game-control` channel.
class FushiGameStreamReceiver extends ChangeNotifier
    with WidgetsBindingObserver {
  FushiGameStreamReceiver({
    required FushiGameStreamClient client,
    this.onTextEvent,
    this.onInputAck,
    RTCVideoRenderer? videoRenderer,
    GameStreamPeerFactory? peerFactory,
    Future<RTCRtpCapabilities> Function()? codecCapabilities,
  }) : _client = client,
       renderer = videoRenderer ?? RTCVideoRenderer(),
       _peerFactory = peerFactory ?? _createPeer,
       _codecCapabilities =
           codecCapabilities ?? (() => getRtpReceiverCapabilities('video')) {
    WidgetsBinding.instance.addObserver(this);
    renderer.onFirstFrameRendered = () {
      if (_disposed ||
          _hasTerminated ||
          _connection == null ||
          renderer.srcObject == null) {
        return;
      }
      _ready = true;
      _notify();
    };
  }

  static Future<RTCPeerConnection> _createPeer() =>
      createPeerConnection(<String, dynamic>{
        'iceServers': <Map<String, dynamic>>[],
        'sdpSemantics': 'unified-plan',
        'bundlePolicy': 'max-bundle',
        'rtcpMuxPolicy': 'require',
      });

  final FushiGameStreamClient _client;
  final GameStreamPeerFactory _peerFactory;
  final Future<RTCRtpCapabilities> Function() _codecCapabilities;
  final ValueChanged<GameStreamTextEvent>? onTextEvent;
  final ValueChanged<GameStreamInputAck>? onInputAck;
  final RTCVideoRenderer renderer;
  RTCPeerConnection? _connection;
  RTCDataChannel? _control;
  Timer? _pollTimer;
  DateTime _lastPoll = DateTime.fromMillisecondsSinceEpoch(0);
  String? _sessionId;
  String? _clientId;
  int _hostSignalSequence = -1;
  int _clientSignalSequence = -1;
  int _generation = 0;
  int _inputEpoch = 0;
  bool _disposed = false;
  bool _rendererInitialized = false;
  bool _rendererDisposed = false;
  bool _backgrounded = false;
  bool _remoteDescriptionSet = false;
  bool _ready = false;
  Future<void>? _rendererInit;
  Future<void>? _poll;
  Future<void> _signals = Future<void>.value();
  Future<void> _inputs = Future<void>.value();
  Future<void> _cleanup = Future<void>.value();
  final List<RTCIceCandidate> _pendingCandidates = <RTCIceCandidate>[];
  final Map<int, Completer<GameStreamInputAck>> _pendingAcks =
      <int, Completer<GameStreamInputAck>>{};
  GameStreamReceiverState _state = GameStreamReceiverState.idle;
  String? _error;
  String? _pollError;
  GameStreamVideoSettings _settings = const GameStreamVideoSettings();
  GameStreamStatsSample? _lastStats;
  String? _codecNote;

  GameStreamVideoSettings get settings => _settings;

  /// Why the requested codec was not applied (shown in the stats overlay).
  String? get codecNote => _codecNote;

  bool get ready => _ready;
  String? get error => _error;
  GameStreamReceiverState get state => _state;
  bool get backgrounded => _backgrounded;
  bool get reconnectRequired => _state == GameStreamReceiverState.failed;
  RTCDataChannel? get controlChannel => _control;

  bool get _hasTerminated =>
      _state == GameStreamReceiverState.failed ||
      _state == GameStreamReceiverState.closed;

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// [settings] picks the preferred codec for the answer and whether the
  /// loopback audio plays; bitrate/fps/resolution are applied by the host.
  Future<void> connect({
    required String sessionId,
    required String clientId,
    GameStreamVideoSettings settings = const GameStreamVideoSettings(),
  }) async {
    if (_disposed) throw StateError('Game-stream receiver is disposed');
    _settings = settings;
    _lastStats = null;
    _codecNote = null;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw UnsupportedError('Game streaming receiver is Android-only');
    }
    // A native peer can recover from a temporary LAN interruption. Rebuilding
    // it would consume the host's one offer with a different ICE identity.
    if (_sessionId == sessionId &&
        _clientId == clientId &&
        _connection != null) {
      if (reconnectRequired) {
        throw StateError('connection_failed_host_restart_required');
      }
      await _pollSignals();
      return;
    }
    await disconnect();
    if (_disposed) throw StateError('Game-stream receiver is disposed');
    final int generation = ++_generation;
    _sessionId = sessionId;
    _clientId = clientId;
    _state = GameStreamReceiverState.connecting;
    _error = null;
    _notify();
    try {
      await (_rendererInit ??= _initializeRenderer());
      if (!_isCurrent(generation)) return;
      final RTCPeerConnection connection = await _peerFactory();
      if (!_isCurrent(generation)) {
        await _closePeer(connection);
        return;
      }
      _connection = connection;
      connection.onTrack = (RTCTrackEvent event) {
        if (!_isCurrent(generation) ||
            _hasTerminated ||
            event.streams.isEmpty) {
          return;
        }
        renderer.srcObject = event.streams.first;
        // Remote tracks arrive enabled; only a muted receiver has to touch them.
        if (!_settings.audio) _applyAudioEnabled();
        _notify();
      };
      connection.onDataChannel = (RTCDataChannel channel) {
        if (_isCurrent(generation)) _bindDataChannel(channel, generation);
      };
      connection.onConnectionState = (RTCPeerConnectionState state) {
        if (_isCurrent(generation)) _handleConnectionState(state);
      };
      connection.onIceCandidate = (RTCIceCandidate candidate) {
        if (!_isCurrent(generation) ||
            _hasTerminated ||
            candidate.candidate?.isNotEmpty != true) {
          return;
        }
        unawaited(
          _queueSignal(GameStreamSignalType.iceCandidate, <String, Object?>{
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          }, generation).catchError((Object error) {
            if (_isCurrent(generation)) {
              _error = '$error';
              _notify();
            }
          }),
        );
      };
      await _pollSignals();
      if (_isCurrent(generation)) _startPolling();
    } catch (error) {
      if (_isCurrent(generation)) {
        await disconnect();
        _state = GameStreamReceiverState.failed;
        _error = '$error';
        _notify();
      }
      rethrow;
    }
  }

  Future<void> _initializeRenderer() async {
    await renderer.initialize();
    _rendererInitialized = true;
  }

  void _handleConnectionState(RTCPeerConnectionState state) {
    // A closed control channel cannot be renegotiated by this single-offer
    // host. Late media/ICE callbacks must not restore an unusable session.
    if (_hasTerminated) return;
    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        _state = GameStreamReceiverState.connected;
        _error = null;
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        // Leave the existing ICE transport intact for short network outages.
        _state = GameStreamReceiverState.reconnecting;
        _error = 'connection_disconnected';
        _invalidatePendingInputs('connection_disconnected');
        _releaseInputs();
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        _state = GameStreamReceiverState.failed;
        _error = 'connection_failed_host_restart_required';
        _ready = false;
        _invalidatePendingInputs('connection_failed');
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        _state = GameStreamReceiverState.closed;
        _ready = false;
        _error = 'connection_closed';
        _invalidatePendingInputs('connection_closed');
      case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
        _state = GameStreamReceiverState.connecting;
      case RTCPeerConnectionState.RTCPeerConnectionStateNew:
        break;
    }
    _notify();
  }

  void _startPolling() {
    if (_pollTimer != null || _backgrounded || _disposed || _hasTerminated) {
      return;
    }
    _pollTimer = Timer.periodic(kGameStreamNegotiationPoll, (_) {
      final DateTime now = DateTime.now();
      if (_state == GameStreamReceiverState.connected &&
          now.difference(_lastPoll) < kGameStreamConnectedPoll) {
        return;
      }
      _lastPoll = now;
      unawaited(_pollSignals());
    });
  }

  Future<void> _pollSignals() {
    if (_disposed || _backgrounded || _hasTerminated) {
      return Future<void>.value();
    }
    return _poll ??= _runPoll(_generation).whenComplete(() => _poll = null);
  }

  Future<void> _runPoll(int generation) async {
    final String? sessionId = _sessionId;
    final String? clientId = _clientId;
    final RTCPeerConnection? connection = _connection;
    if (sessionId == null || clientId == null || connection == null) return;
    try {
      final List<GameStreamSignal> signals = await _client.pollSignals(
        sessionId: sessionId,
        clientId: clientId,
        after: _hostSignalSequence,
      );
      if (!_isCurrent(generation) || _hasTerminated) return;
      signals.sort(
        (GameStreamSignal a, GameStreamSignal b) =>
            a.sequence.compareTo(b.sequence),
      );
      for (final GameStreamSignal signal in signals) {
        if (!_isCurrent(generation) || _hasTerminated) return;
        if (signal.sessionId != sessionId ||
            signal.senderRole != GameStreamPeerRole.host ||
            signal.sequence <= _hostSignalSequence) {
          continue;
        }
        await _applyHostSignal(connection, signal, generation);
        if (!_isCurrent(generation)) return;
        // Do not skip a failed offer/candidate: the next poll can apply it.
        _hostSignalSequence = signal.sequence;
      }
      if (_pollError != null && _error == _pollError) {
        _error = null;
        _notify();
      }
      _pollError = null;
    } catch (error) {
      if (_isCurrent(generation) &&
          _state != GameStreamReceiverState.failed &&
          _state != GameStreamReceiverState.closed) {
        _pollError = '$error';
        _error = _pollError;
        _notify();
      }
    }
  }

  Future<void> _applyHostSignal(
    RTCPeerConnection connection,
    GameStreamSignal signal,
    int generation,
  ) async {
    switch (signal.type) {
      case GameStreamSignalType.offer:
        final String? sdp = signal.payload['sdp'] as String?;
        if (sdp == null || sdp.isEmpty) {
          throw const FormatException('Missing host SDP');
        }
        await connection.setRemoteDescription(
          RTCSessionDescription(sdp, 'offer'),
        );
        if (!_isCurrent(generation)) return;
        _remoteDescriptionSet = true;
        while (_pendingCandidates.isNotEmpty) {
          await connection.addCandidate(_pendingCandidates.first);
          if (!_isCurrent(generation)) return;
          _pendingCandidates.removeAt(0);
        }
        // The sender encodes with the first codec listed in the answer, so the
        // receiver alone decides the codec — older hosts need no support.
        await _applyCodecPreference(connection);
        if (!_isCurrent(generation)) return;
        final RTCSessionDescription answer = await connection.createAnswer();
        if (!_isCurrent(generation)) return;
        await connection.setLocalDescription(answer);
        if (!_isCurrent(generation)) return;
        await _queueSignal(GameStreamSignalType.answer, <String, Object?>{
          'sdp': answer.sdp,
          'type': answer.type,
        }, generation);
      case GameStreamSignalType.iceCandidate:
        final String? candidate = signal.payload['candidate'] as String?;
        if (candidate == null || candidate.isEmpty) return;
        final RTCIceCandidate ice = RTCIceCandidate(
          candidate,
          signal.payload['sdpMid'] as String?,
          (signal.payload['sdpMLineIndex'] as num?)?.toInt(),
        );
        if (_remoteDescriptionSet) {
          await connection.addCandidate(ice);
        } else {
          _pendingCandidates.add(ice);
        }
      case GameStreamSignalType.bye:
        await disconnect();
        if (!_disposed) {
          _state = GameStreamReceiverState.closed;
          _error = 'host_stopped';
          _notify();
        }
      case GameStreamSignalType.renegotiation:
      case GameStreamSignalType.answer:
        break;
    }
  }

  Future<void> _applyCodecPreference(RTCPeerConnection connection) async {
    if (_settings.codec == GameStreamCodec.auto) return;
    try {
      final RTCRtpCapabilities capabilities = await _codecCapabilities();
      final List<RTCRtpCodecCapability>? ordered = gameStreamPreferredCodecs(
        capabilities.codecs ?? const <RTCRtpCodecCapability>[],
        _settings.codec,
      );
      if (ordered == null) {
        _codecNote = 'codec_unavailable';
        return;
      }
      for (final RTCRtpTransceiver transceiver
          in await connection.getTransceivers()) {
        if (transceiver.receiver.track?.kind == 'video') {
          await transceiver.setCodecPreferences(ordered);
        }
      }
    } catch (error) {
      // A decoder the device lacks must not cost the whole stream; libwebrtc
      // then negotiates its default order.
      _codecNote = 'codec_preference_failed';
    }
  }

  /// Applies bitrate / fps / a lower resolution cap to the running stream by
  /// repeating the join (the host treats a join from the already connected
  /// client as a parameter update). Returns what the host put into effect.
  /// A codec change is kept for the next connection: it needs a new offer.
  Future<GameStreamVideoSettings?> updateSettings(
    GameStreamVideoSettings next,
  ) async {
    final String? sessionId = _sessionId;
    final String? clientId = _clientId;
    _settings = next;
    _applyAudioEnabled();
    _notify();
    if (sessionId == null || clientId == null || _hasTerminated) return null;
    final GameStreamSession? session = await _client.join(
      sessionId: sessionId,
      clientId: clientId,
      settings: next,
    );
    return session?.settings;
  }

  /// Unmutes/mutes the host's loopback audio locally.
  void setAudioEnabled(bool enabled) {
    _settings = _settings.copyWith(audio: enabled);
    _applyAudioEnabled();
    _notify();
  }

  void _applyAudioEnabled() {
    final MediaStream? stream = renderer.srcObject;
    if (stream == null) return;
    for (final MediaStreamTrack track in stream.getAudioTracks()) {
      track.enabled = _settings.audio;
    }
  }

  /// One stats sample for the performance overlay; null when not connected.
  Future<GameStreamStatsSample?> sampleStats() async {
    final RTCPeerConnection? connection = _connection;
    if (connection == null) return null;
    final List<StatsReport> reports = await connection.getStats();
    final GameStreamStatsSample sample = GameStreamStatsSample.fromReports(
      reports,
      previous: _lastStats,
    );
    _lastStats = sample;
    return sample;
  }

  Future<void> _queueSignal(
    GameStreamSignalType type,
    Map<String, Object?> payload,
    int generation,
  ) {
    final Future<void> operation = _signals.then((_) async {
      if (!_isCurrent(generation) || _hasTerminated) return;
      final GameStreamSignal signal = GameStreamSignal(
        sessionId: _sessionId!,
        senderId: _clientId!,
        senderRole: GameStreamPeerRole.client,
        type: type,
        sequence: ++_clientSignalSequence,
        payload: payload,
      );
      // HTTP responses can contain host signals; ignore them here so only the
      // polling path advances the host cursor after successfully applying them.
      await _client.sendSignal(signal, after: _hostSignalSequence);
    });
    // Keep the serialization tail usable, but return the actual delivery to
    // the caller. In particular, a failed answer must not acknowledge the
    // host offer in the polling cursor, or negotiation can never complete.
    _signals = operation.catchError((Object _) {});
    return operation;
  }

  void _bindDataChannel(RTCDataChannel channel, int generation) {
    if (channel.label != 'fushi-game-control' || _control != null) {
      unawaited(channel.close());
      return;
    }
    _control = channel;
    channel.onDataChannelState = (RTCDataChannelState state) {
      if (!_isCurrent(generation)) return;
      if (state == RTCDataChannelState.RTCDataChannelClosed) {
        _pollTimer?.cancel();
        _pollTimer = null;
        _state = GameStreamReceiverState.failed;
        _ready = false;
        _invalidatePendingInputs('control_channel_closed');
        _error = 'control_channel_closed_host_restart_required';
        _notify();
      }
    };
    channel.onMessage = (RTCDataChannelMessage message) {
      if (!_isCurrent(generation) ||
          _hasTerminated ||
          message.isBinary ||
          message.text.length > 1024 * 1024) {
        return;
      }
      try {
        final Map<String, dynamic> json = decodeGameStreamJsonObject(
          message.text,
        );
        if (json['kind'] == 'ack') {
          final GameStreamInputAck ack = GameStreamInputAck.fromJson(
            json['ack'],
          );
          final Completer<GameStreamInputAck>? pending = _pendingAcks.remove(
            ack.sequence,
          );
          if (pending == null) return;
          pending.complete(ack);
          onInputAck?.call(ack);
        } else if (json['kind'] == 'text') {
          final GameStreamTextEvent event = GameStreamTextEvent.fromJson(
            json['event'],
          );
          if (event.sessionId != _sessionId) return;
          onTextEvent?.call(event);
          _notify();
        }
      } on FormatException {
        // Malformed peer messages do not mutate input or transcript state.
      }
    };
  }

  Future<GameStreamInputAck> sendInput(GameStreamInputEvent event) async {
    final RTCDataChannel? channel = _control;
    final int generation = _generation;
    final int inputEpoch = _inputEpoch;
    if (_disposed ||
        _backgrounded ||
        _state != GameStreamReceiverState.connected ||
        channel == null ||
        channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      return _reject(event.sequence, 'control_channel_unavailable');
    }
    if (event.sessionId != _sessionId || event.clientId != _clientId) {
      return _reject(event.sequence, 'session_mismatch');
    }
    if (_pendingAcks.containsKey(event.sequence)) {
      return _reject(event.sequence, 'duplicate_sequence');
    }
    final Completer<GameStreamInputAck> ack = Completer<GameStreamInputAck>();
    _pendingAcks[event.sequence] = ack;
    final Future<void> send = _inputs.then((_) async {
      if (!_isCurrent(generation) ||
          inputEpoch != _inputEpoch ||
          ack.isCompleted ||
          _backgrounded ||
          _state != GameStreamReceiverState.connected ||
          !identical(channel, _control) ||
          channel.state != RTCDataChannelState.RTCDataChannelOpen) {
        if (!ack.isCompleted) {
          ack.complete(_reject(event.sequence, 'control_channel_unavailable'));
        }
        return;
      }
      await channel.send(
        RTCDataChannelMessage(
          jsonEncode(<String, Object?>{
            'kind': 'input',
            'event': event.toJson(),
          }),
        ),
      );
    });
    _inputs = send.catchError((Object error) {
      if (!ack.isCompleted) {
        ack.complete(_reject(event.sequence, 'input_send_failed'));
      }
    });
    try {
      return await ack.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          if (_isCurrent(generation) &&
              inputEpoch == _inputEpoch &&
              identical(_pendingAcks[event.sequence], ack)) {
            // Timeout means delivery is uncertain: discard all queued input
            // from this epoch and release any DOWN already sent to the host.
            _invalidatePendingInputs('ack_timeout');
            _releaseInputs();
          }
          return _reject(event.sequence, 'ack_timeout');
        },
      );
    } finally {
      if (identical(_pendingAcks[event.sequence], ack)) {
        _pendingAcks.remove(event.sequence);
      }
    }
  }

  GameStreamInputAck _reject(int sequence, String reason) =>
      GameStreamInputAck(sequence: sequence, accepted: false, reason: reason);

  void _invalidatePendingInputs(String reason) {
    // Connection generation stays stable through pause/resume and ICE recovery.
    // Invalidate queued controls independently so a late native send cannot
    // revive input that has already been rejected to the page.
    ++_inputEpoch;
    for (final MapEntry<int, Completer<GameStreamInputAck>> pending
        in _pendingAcks.entries) {
      if (!pending.value.isCompleted) {
        pending.value.complete(_reject(pending.key, reason));
      }
    }
    _pendingAcks.clear();
  }

  /// Keep the native media connection during Android activity pauses (including
  /// rotation); suspend control/polling and resume the same ICE transport.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    final bool wasBackgrounded = _backgrounded;
    _backgrounded = state != AppLifecycleState.resumed;
    if (_backgrounded) {
      if (!wasBackgrounded) _releaseInputs();
      _pollTimer?.cancel();
      _pollTimer = null;
      _invalidatePendingInputs('app_backgrounded');
    } else if (_connection != null) {
      _startPolling();
      unawaited(_pollSignals());
    }
    _notify();
  }

  void _releaseInputs() {
    final RTCDataChannel? channel = _control;
    final int generation = _generation;
    if (channel?.state != RTCDataChannelState.RTCDataChannelOpen) return;
    // The same reliable queue places release after any input already in flight.
    // This release is intentionally scoped to the connection, not inputEpoch:
    // it must survive resume and precede any newly accepted controls. Queued
    // inputs from before the interruption are rejected by their input epoch.
    _inputs = _inputs
        .then((_) async {
          if (!_isCurrent(generation)) return;
          await channel!.send(
            RTCDataChannelMessage(
              jsonEncode(<String, Object?>{
                'kind': 'releaseAll',
                'sessionId': _sessionId,
                'clientId': _clientId,
              }),
            ),
          );
        })
        .catchError((Object error) {
          // The host also releases every key when the native peer disconnects.
          if (_isCurrent(generation) && !_hasTerminated) {
            _error = 'control_channel_unavailable';
            _notify();
          }
        });
  }

  Future<void> disconnect() {
    _generation++;
    _pollTimer?.cancel();
    _pollTimer = null;
    final RTCPeerConnection? connection = _connection;
    _connection = null;
    _control = null;
    _sessionId = null;
    _clientId = null;
    _hostSignalSequence = -1;
    _clientSignalSequence = -1;
    _remoteDescriptionSet = false;
    _pendingCandidates.clear();
    _ready = false;
    _state = GameStreamReceiverState.idle;
    _invalidatePendingInputs('disconnected');
    if (_rendererInitialized && !_rendererDisposed) renderer.srcObject = null;
    _notify();
    _cleanup = _cleanup.then((_) async {
      if (connection != null) await _closePeer(connection);
    });
    return _cleanup;
  }

  Future<void> _closePeer(RTCPeerConnection connection) async {
    connection.onTrack = null;
    connection.onDataChannel = null;
    connection.onIceCandidate = null;
    connection.onConnectionState = null;
    try {
      await connection.close();
    } finally {
      await connection.dispose();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    final Future<void> closing = disconnect();
    // Await initialize before disposing the renderer, including disposal while
    // its platform call is still pending. Never notify after ChangeNotifier dies.
    unawaited(
      () async {
        try {
          await closing;
          await _rendererInit;
        } finally {
          _rendererDisposed = true;
          await renderer.dispose();
        }
      }().catchError((Object error) {
        // Cleanup has no UI listener after dispose. Retain the native diagnostic
        // for debuggers without leaking an unhandled asynchronous exception.
        _error = '$error';
      }),
    );
    super.dispose();
  }
}

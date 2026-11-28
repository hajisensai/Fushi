import 'dart:async';
import 'dart:math';

import 'dart:typed_data';

import 'package:dartssh2/src/ssh_channel_id.dart';
import 'package:dartssh2/src/ssh_transport.dart';
import 'package:dartssh2/src/utils/async_queue.dart';
import 'package:dartssh2/src/message/msg_channel.dart';
import 'package:dartssh2/src/ssh_message.dart';
import 'package:dartssh2/src/utils/stream.dart';

/// Handler of channel requests. Return true if the request was handled, false
/// if the request was not recognized or could not be handled.
typedef SSHChannelRequestHandler = bool Function(
  SSH_Message_Channel_Request request,
);

class SSHChannelController {
  final int localId;
  final int localMaximumPacketSize;
  final int localInitialWindowSize;

  final int remoteId;
  final int remoteMaximumPacketSize;
  final int remoteInitialWindowSize;

  final SSHPrintHandler? printDebug;

  final void Function(SSHMessage) sendMessage;

  SSHChannel get channel => SSHChannel(this);

  SSHChannelController({
    required this.localId,
    required this.localMaximumPacketSize,
    required this.localInitialWindowSize,
    required this.remoteId,
    required this.remoteInitialWindowSize,
    required this.remoteMaximumPacketSize,
    required this.sendMessage,
    this.printDebug,
  }) {
    if (remoteInitialWindowSize > 0) {
      _uploadLoop.activate();
    }
  }

  /// Remaining local receive window size.
  late var _localWindow = localInitialWindowSize;

  /// Remaining remote receive window size.
  late var _remoteWindow = remoteInitialWindowSize;

  /// A [StreamController] that receives data from the remote side.
  late final _remoteStream = StreamController<SSHChannelData>(
    onResume: _sendWindowAdjustIfNeeded,
  );

  /// A [StreamController] that accepts data from local end of the channel.
  final _localStream = StreamController<SSHChannelData>();

  late final _locaStreamConsumer = SSHChannelDataConsumer(_localStream.stream);

  /// Handler of channel requests from the remote side.
  late var _requestHandler = _defaultRequestHandler;

  /// An [AsyncQueue] of pending request replies from the remote side.
  final _requestReplyQueue = AsyncQueue<bool>();

  /// true if we have sent an EOF message to the remote side.
  var _hasSentEOF = false;

  /// true if we have sent an close message to the remote side.
  var _hasSentClose = false;

  final _done = Completer<void>();

  Future<bool> sendExec(String command) async {
    sendMessage(
      SSH_Message_Channel_Request.exec(
        recipientChannel: remoteId,
        wantReply: true,
        command: command,
      ),
    );
    return await _requestReplyQueue.next;
  }

  Future<bool> sendPtyReq({
    String terminalType = 'xterm-256color',
    int terminalWidth = 80,
    int terminalHeight = 25,
    int terminalPixelWidth = 0,
    int terminalPixelHeight = 0,
    Uint8List? terminalModes,
  }) async {
    sendMessage(
      SSH_Message_Channel_Request.pty(
        recipientChannel: remoteId,
        termType: terminalType,
        termWidth: terminalWidth,
        termHeight: terminalHeight,
        termPixelWidth: terminalPixelWidth,
        termPixelHeight: terminalPixelHeight,
        termModes: terminalModes ?? Uint8List(0),
        wantReply: true,
      ),
    );
    return await _requestReplyQueue.next;
  }

  Future<bool> sendShell() async {
    sendMessage(
      SSH_Message_Channel_Request.shell(
        recipientChannel: remoteId,
        wantReply: true,
      ),
    );
    return await _requestReplyQueue.next;
  }

  Future<bool> sendSubsystem(String subsystem) async {
    sendMessage(
      SSH_Message_Channel_Request.subsystem(
        recipientChannel: remoteId,
        subsystemName: subsystem,
        wantReply: true,
      ),
    );
    return await _requestReplyQueue.next;
  }

  void sendEnv(String name, String value) {
    sendMessage(
      SSH_Message_Channel_Request.env(
        recipientChannel: remoteId,
        variableName: name,
        variableValue: value,
        wantReply: true,
      ),
    );
  }

  void sendSignal(String signal) {
    sendMessage(
      SSH_Message_Channel_Request.signal(
        recipientChannel: remoteId,
        signalName: signal,
      ),
    );
  }

  void sendTerminalWindowChange({
    required int width,
    required int height,
    required int pixelWidth,
    required int pixelHeight,
  }) {
    sendMessage(
      SSH_Message_Channel_Request.windowChange(
        recipientChannel: remoteId,
        termWidth: width,
        termHeight: height,
        termPixelWidth: pixelWidth,
        termPixelHeight: pixelHeight,
      ),
    );
  }

  void handleMessage(SSHMessage message) {
    if (message is SSH_Message_Channel_Data) {
      _handleDataMessage(message.data);
    } else if (message is SSH_Message_Channel_Extended_Data) {
      _handleDataMessage(message.data, type: message.dataTypeCode);
    } else if (message is SSH_Message_Channel_Window_Adjust) {
      _handleWindowAdjustMessage(message.bytesToAdd);
    } else if (message is SSH_Message_Channel_EOF) {
      _handleEOFMessage();
    } else if (message is SSH_Message_Channel_Close) {
      _handleCloseMessage();
    } else if (message is SSH_Message_Channel_Request) {
      _handleRequestMessage(message);
    } else if (message is SSH_Message_Channel_Success) {
      _handleRequestSuccessMessage();
    } else if (message is SSH_Message_Channel_Failure) {
      _handleRequestFailureMessage();
    } else {
      throw UnimplementedError('Unimplemented message: $message');
    }
  }

  /// Closes our side of the channel. Returns a [Future] that completes when
  /// the remote side has closed the channel.
  Future<void> close() async {
    if (_done.isCompleted) return;

    _locaStreamConsumer.cancel();
    _sendEOFIfNeeded();

    if (_remoteStream.isClosed) {
      _sendCloseIfNeeded();
      _done.complete();
      return;
    }

    return _done.future;
  }

  /// Closes the channel immediately in both directions. This may send a close
  /// message to the remote side. After this no more data can be sent or
  /// received.
  void destroy() {
    if (_done.isCompleted) return;
    _remoteStream.close();
    _locaStreamConsumer.cancel();
    _sendEOFIfNeeded();
    _sendCloseIfNeeded();
    _done.complete();
  }

  /// FUSHI PATCH (BUG-5520): tears the channel down locally after the
  /// transport is gone. Unlike [destroy] it sends nothing: there is no peer to
  /// tell, and sending on a closed transport throws `SSHStateError`, which used
  /// to abort [destroy] before [_done] completed and leave the channel (and
  /// every SFTP request waiting on it) half-closed. [_done] completes first so
  /// the upload loop, woken by the consumer cancel, finds the channel finished
  /// and does not try to send EOF / close either.
  void abandon() {
    if (_done.isCompleted) return;
    _done.complete();
    _remoteStream.close();
    _locaStreamConsumer.cancel();
  }

  void _handleWindowAdjustMessage(int bytesToAdd) {
    printDebug?.call('SSHChannel._handleWindowAdjustMessage: $bytesToAdd');

    if (bytesToAdd < 0) {
      throw ArgumentError.value(bytesToAdd, 'bytesToAdd', 'must be positive');
    }

    _remoteWindow += bytesToAdd;

    if (_remoteWindow > 0) {
      _uploadLoop.activate();
    }
  }

  void _handleDataMessage(Uint8List data, {int? type}) {
    printDebug?.call('SSHChannel._handleDataMessage: len=${data.length}');

    if (_remoteStream.isClosed) {
      printDebug?.call('SSHChannel._handleDataMessage: remote already closed');
      return;
    }

    _remoteStream.add(SSHChannelData(data, type: type));

    _localWindow -= data.length;
    if (_localWindow < 0) {
      // Maybe we should close the channel here?
    }

    _sendWindowAdjustIfNeeded();
  }

  void _handleRequestMessage(SSH_Message_Channel_Request request) {
    printDebug?.call('SSHChannel._handleRequest: ${request.requestType}');

    final success = _requestHandler(request);
    if (!request.wantReply) return;
    success ? _sendRequestSuccess() : _sendRequestFailure();
  }

  void _handleRequestSuccessMessage() {
    printDebug?.call('SSHChannel._handleRequestSuccessMessage');
    _requestReplyQueue.add(true);
  }

  void _handleRequestFailureMessage() {
    printDebug?.call('SSHChannel._handleRequestFailureMessage');
    _requestReplyQueue.add(false);
  }

  void _handleEOFMessage() {
    printDebug?.call('SSHChannel._handleEOFMessage');
    _remoteStream.close();
  }

  void _handleCloseMessage() {
    printDebug?.call('SSHChannel._handleCLoseMessage');
    _remoteStream.close();
    close();
  }

  bool _defaultRequestHandler(SSH_Message_Channel_Request request) {
    return false;
  }

  void _sendEOFIfNeeded() {
    printDebug?.call('SSHChannel._sendEOFIfNeeded');
    if (_done.isCompleted) return;
    if (_hasSentEOF) return;
    _hasSentEOF = true;
    sendMessage(SSH_Message_Channel_EOF(recipientChannel: remoteId));
  }

  void _sendCloseIfNeeded() {
    printDebug?.call('SSHChannel._sendCloseIfNeeded');
    if (_done.isCompleted) return;
    if (_hasSentClose) return;
    _hasSentClose = true;
    sendMessage(SSH_Message_Channel_Close(recipientChannel: remoteId));
  }

  void _sendRequestSuccess() {
    printDebug?.call('SSHChannel._sendRequestSuccess');
    sendMessage(SSH_Message_Channel_Success(recipientChannel: remoteId));
  }

  void _sendRequestFailure() {
    printDebug?.call('SSHChannel._sendRequestFailure');
    sendMessage(SSH_Message_Channel_Failure(recipientChannel: remoteId));
  }

  void _sendWindowAdjustIfNeeded() {
    printDebug?.call('SSHChannel._sendWindowAdjustIfNeeded');

    if (_done.isCompleted) return;
    if (_remoteStream.isPaused) return;
    if (_localWindow <= 0) return;

    final bytesToAdd = localInitialWindowSize - _localWindow;
    _localWindow = localInitialWindowSize;

    sendMessage(
      SSH_Message_Channel_Window_Adjust(
        recipientChannel: remoteId,
        bytesToAdd: bytesToAdd,
      ),
    );
  }

  late final _uploadLoop = OnceSimultaneously(() async {
    while (true) {
      if (_remoteWindow <= 0) {
        return;
      }

      final dataToRead = min(_remoteWindow, remoteMaximumPacketSize);
      final data = await _locaStreamConsumer.read(dataToRead);

      if (data == null) {
        _sendEOFIfNeeded();

        if (_remoteStream.isClosed) {
          close();
        }
        return;
      }

      if (_hasSentEOF) {
        return;
      }

      printDebug?.call('SSHChannel._uploadLoop: len=${data.bytes.length}');

      final message = data.isExtendedData
          ? SSH_Message_Channel_Extended_Data(
              recipientChannel: remoteId,
              dataTypeCode: data.type!,
              data: data.bytes,
            )
          : SSH_Message_Channel_Data(
              recipientChannel: remoteId,
              data: data.bytes,
            );

      sendMessage(message);

      _remoteWindow -= data.bytes.length;
    }
  });
}

class SSHChannel {
  /// The channel id on the local side.
  SSHChannelId get channelId => _controller.localId;

  /// The channel id on the remote side.
  SSHChannelId get remoteChannelId => _controller.localId;

  /// The maximum packet size that the remote side can receive.
  int get maximumPacketSize => _controller.remoteMaximumPacketSize;

  /// A [Stream] of data received from the remote side.
  Stream<SSHChannelData> get stream => _controller._remoteStream.stream;

  /// A [StreamSink] that sends data to the remote side. Chucks must be
  /// equal to or less than [maximumPacketSize].
  StreamSink<SSHChannelData> get sink => _controller._localStream.sink;

  Future<void> get done => _controller._done.future;

  SSHChannel(this._controller);

  final SSHChannelController _controller;

  /// Send data to the remote side.
  void addData(Uint8List data, {int? type}) {
    sink.add(SSHChannelData(data, type: type));
  }

  void setRequestHandler(SSHChannelRequestHandler handler) {
    _controller._requestHandler = handler;
  }

  Future<bool> sendExec(String command) async {
    return await _controller.sendExec(command);
  }

  Future<bool> sendShell() async {
    return await _controller.sendShell();
  }

  void sendTerminalWindowChange({
    required int width,
    required int height,
    int pixelWidth = 0,
    int pixelHeight = 0,
  }) {
    _controller.sendTerminalWindowChange(
      width: width,
      height: height,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
    );
  }

  void sendSignal(String signal) {
    _controller.sendSignal(signal);
  }

  /// Closes our side of the channel. Returns a [Future] that completes when
  /// both sides of the channel are closed.
  Future<void> close() => _controller.close();

  /// Destroys the channel in both directions. After calling this method,
  /// no more data can be sent or received.
  void destroy() => _controller.destroy();

  @override
  String toString() => 'SSHChannel($channelId:$remoteChannelId)';
}

class SSHChannelData {
  /// Type of the data. Not null if the data is extended data. See: [SSHChannelExtendedDataType]
  final int? type;

  final Uint8List bytes;

  bool get isExtendedData => type != null;

  SSHChannelData(this.bytes, {this.type});
}

class SSHChannelExtendedDataType {
  static const stderr = 1;
}

class SSHChannelDataSplitter
    extends StreamTransformerBase<SSHChannelData, SSHChannelData> {
  SSHChannelDataSplitter(this.maxSize);

  final int maxSize;

  @override
  Stream<SSHChannelData> bind(Stream<SSHChannelData> stream) async* {
    await for (var chunk in stream) {
      if (chunk.bytes.length < maxSize) {
        yield chunk;
        continue;
      }

      final blocks = chunk.bytes.length ~/ maxSize;

      for (var i = 0; i < blocks; i++) {
        yield SSHChannelData(
          Uint8List.sublistView(chunk.bytes, i * maxSize, (i + 1) * maxSize),
          type: chunk.type,
        );
      }

      if (blocks * maxSize < chunk.bytes.length) {
        yield SSHChannelData(
          Uint8List.sublistView(chunk.bytes, blocks * maxSize),
          type: chunk.type,
        );
      }
    }
  }
}

class SSHChannelDataConsumer extends StreamConsumerBase<SSHChannelData> {
  SSHChannelDataConsumer(super.stream);

  @override
  int getLength(SSHChannelData chunk) {
    return chunk.bytes.length;
  }

  @override
  SSHChannelData getSublistView(SSHChannelData chunk, int start, int end) {
    return SSHChannelData(
      Uint8List.sublistView(chunk.bytes, start, end),
      type: chunk.type,
    );
  }
}

/// A function that can be invoked at most once simultaneously.
class OnceSimultaneously {
  OnceSimultaneously(this._fn);

  final Future Function() _fn;

  var _isRunning = false;

  /// Call the function. If the function is already running, this is a no-op.
  void activate() async {
    if (_isRunning) return;
    _isRunning = true;
    try {
      await _fn();
    } finally {
      _isRunning = false;
    }
  }
}

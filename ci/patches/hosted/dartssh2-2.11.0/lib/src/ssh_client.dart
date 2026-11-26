import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:dartssh2/src/http/http_client.dart';
import 'package:dartssh2/src/sftp/sftp_client.dart';
import 'package:dartssh2/src/ssh_algorithm.dart';
import 'package:dartssh2/src/ssh_channel.dart';
import 'package:dartssh2/src/ssh_channel_id.dart';
import 'package:dartssh2/src/ssh_errors.dart';
import 'package:dartssh2/src/ssh_forward.dart';
import 'package:dartssh2/src/ssh_keepalive.dart';
import 'package:dartssh2/src/ssh_key_pair.dart';
import 'package:dartssh2/src/ssh_session.dart';
import 'package:dartssh2/src/ssh_transport.dart';
import 'package:dartssh2/src/utils/async_queue.dart';
import 'package:dartssh2/src/message/msg_channel.dart';
import 'package:dartssh2/src/message/msg_request.dart';
import 'package:dartssh2/src/message/msg_service.dart';
import 'package:dartssh2/src/message/msg_userauth.dart';
import 'package:dartssh2/src/ssh_message.dart';
import 'package:dartssh2/src/socket/ssh_socket.dart';
import 'package:dartssh2/src/ssh_userauth.dart';

/// https://datatracker.ietf.org/doc/html/rfc4252#section-8
typedef SSHPasswordRequestHandler = FutureOr<String?> Function();

typedef SSHChangePasswordRequestHandler = FutureOr<SSHChangePasswordResponse?>
    Function(String prompt);

/// https://datatracker.ietf.org/doc/html/rfc4256#section-3.3
typedef SSHUserInfoRequestHandler = FutureOr<List<String>?> Function(
  SSHUserInfoRequest request,
);

/// https://datatracker.ietf.org/doc/html/rfc4252#section-5.4
typedef SSHUserauthBannerHandler = void Function(String banner);

typedef SSHAuthenticatedHandler = void Function();

typedef SSHRemoteConnectionFilter = bool Function(String host, int port);

// /// Function called when the host has sent additional host keys after the initial
// /// key exchange.
// typedef SSHHostKeysHandler = void Function(List<Uint8List>);

const _initialWindowSize = 1024 * 1024 * 2;

const _maximumPacketSize = 32768;

class SSHPtyConfig {
  /// Type of terminal, for example 'xterm', 'xterm-256color'.
  final String type;

  /// Width of the terminal in number of columns.
  final int width;

  /// Height of the terminal in number of rows.
  final int height;

  /// Width of the terminal in pixels. 0 if unknown.
  final int pixelWidth;

  /// Height of the terminal in pixels. 0 if unknown.
  final int pixelHeight;

  const SSHPtyConfig({
    this.type = 'xterm-256color',
    this.width = 80,
    this.height = 24,
    this.pixelWidth = 0,
    this.pixelHeight = 0,
  });
}

class SSHClient {
  final SSHSocket socket;

  /// The username to authenticate as.
  final String username;

  /// Function invoked with debug messages.
  final SSHPrintHandler? printDebug;

  /// Function invoked with network traffic messages.
  final SSHPrintHandler? printTrace;

  /// Crypto algorithms available for the client.
  final SSHAlgorithms algorithms;

  /// Function called when the first host key is received. Return true to accept
  /// the host key, false to reject it and close the connection. If this is
  /// null, the host key is accepted automatically.
  final SSHHostkeyVerifyHandler? onVerifyHostKey;

  /// List of key pairs to use for authentication. Set this field to enable
  /// authentication with public key.
  final List<SSHKeyPair>? identities;

  /// Set this field to enable the 'password' authentication method. Return null
  /// to skip to the next available authentication method.
  final SSHPasswordRequestHandler? onPasswordRequest;

  /// Set this field to enable setting new passwords when the server requests
  /// changing password when using the 'password' authentication method. Return
  /// null to skip to the next available authentication method.
  final SSHChangePasswordRequestHandler? onChangePasswordRequest;

  /// Set this field to enable the 'keyboard-interactive' authentication method.
  /// This may be called multiple times to request additional prompts. Return
  /// null to skip to the next available authentication method.
  final SSHUserInfoRequestHandler? onUserInfoRequest;

  /// The SSH server may send banner message at any time before authentication
  /// is successful. Set this field to receive the banner message.
  final SSHUserauthBannerHandler? onUserauthBanner;

  /// A [Future] that completes normally when the client is connected to the
  // Future<void> get handshake => _handshakeCompleter.future;

  /// Function called when authentication is complete.
  final SSHAuthenticatedHandler? onAuthenticated;

  /// The interval at which to send a keep-alive message through the [ping]
  /// method. Set this to null to disable automatic keep-alive messages.
  final Duration? keepAliveInterval;

  /// Function called when additional host keys are received. This is an OpenSSH
  /// extension. May not be called if the server does not support the extension.
  // final SSHHostKeysHandler? onHostKeys;

  /// A [Future] that completes when the transport is closed, or when an error
  /// occurs. After this [Future] completes, [isClosed] will be true and no more
  /// data can be sent or received.
  Future<void> get done => _transport.done;

  /// true if the connection is closed normally or due to an error.
  bool get isClosed => _transport.isClosed;

  SSHClient(
    this.socket, {
    required this.username,
    this.printDebug,
    this.printTrace,
    this.algorithms = const SSHAlgorithms(),
    this.onVerifyHostKey,
    this.identities,
    this.onPasswordRequest,
    this.onChangePasswordRequest,
    this.onUserInfoRequest,
    this.onUserauthBanner,
    this.onAuthenticated,
    this.keepAliveInterval = const Duration(seconds: 10),
  }) {
    _transport = SSHTransport(
      socket,
      isServer: false,
      printDebug: printDebug,
      printTrace: printTrace,
      algorithms: algorithms,
      onVerifyHostKey: onVerifyHostKey,
      onReady: _handleTransportReady,
      onPacket: _handlePacket,
    );

    _transport.done.then(
      (_) => _handleTransportClosed(),
      onError: (_) => _handleTransportClosed(),
    );

    _authenticated.future.catchError(
      (error, stackTrace) => _transport.closeWithError(error, stackTrace),
    );

    if (identities != null) {
      _keyPairsLeft.addAll(identities!);
    }
  }

  late final SSHTransport _transport;

  /// A [Completer] that completes when the client has authenticated, or
  /// completes with an error if the client could not authenticate.
  final _authenticated = Completer<void>();

  final _globalRequestReplyQueue = AsyncQueue<SSHMessage>();

  final _channelIdAllocator = SSHChannelIdAllocator();

  final _channelOpenReplyWaiters = <int, Completer<SSHMessage>>{};

  final _channels = <int, SSHChannelController>{};

  final _authMethodsLeft = Queue<SSHAuthMethod>();

  final _keyPairsLeft = Queue<SSHKeyPair>();

  final _remoteForwards = <SSHRemoteForward>{};

  late final _keepAlive = keepAliveInterval != null
      ? SSHKeepAlive(ping: ping, interval: keepAliveInterval!)
      : null;

  SSHAuthMethod? _currentAuthMethod;

  /// A [Future] that completes when the client has authenticated, or
  /// completes with an error if the client could not authenticate.
  Future<void> get authenticated => _authenticated.future;

  /// Identification string sent by the other side. For example,
  /// "SSH-2.0-OpenSSH_7.4p1". May be null if the handshake has not yet
  /// completed.
  String? get remoteVersion => _transport.remoteVersion;

  /// Request connections to a port on the other side be forwarded to the local
  /// side.
  /// Set [host] to null to listen on all interfaces, `"0.0.0.0"` to
  /// listen on all IPv4 interfaces, `"::"` to listen on all IPv6 interfaces,
  /// and `"localhost"` to listen on the loopback interface on all protocols.
  /// Set [port] to null to listen on a random port.
  Future<SSHRemoteForward?> forwardRemote({
    String? host,
    int? port,
    SSHRemoteConnectionFilter? filter,
  }) async {
    await _authenticated.future;

    // Lisning on all interfaces if not specified.
    host ??= '';

    // Lisning on a random port if not specified.
    port ??= 0;

    _sendMessage(SSH_Message_Global_Request.tcpipForward(host, port));
    final reply = await _globalRequestReplyQueue.next;

    if (reply is SSH_Message_Request_Failure) return null;

    if (reply is! SSH_Message_Request_Success) {
      throw SSHStateError('Unexpected reply to tcpip-forward request: $reply');
    }

    final reader = SSHMessageReader(reply.requestData);
    final assignedPort = port != 0 ? port : reader.readUint32();

    final remoteForward = SSHRemoteForward(this, host, assignedPort, filter);
    _remoteForwards.add(remoteForward);

    return remoteForward;
  }

  /// Cancel a previous request to forward connections to a port on the other
  /// side. Returns [true] if successful, [false] otherwise.
  /// See also: [forwardRemote].
  Future<bool> cancelForwardRemote(SSHRemoteForward forward) async {
    await _authenticated.future;

    if (!_remoteForwards.remove(forward)) return false;

    _sendMessage(
      SSH_Message_Global_Request.cancelTcpipForward(
        bindAddress: forward.host,
        bindPort: forward.port,
      ),
    );

    final reply = await _globalRequestReplyQueue.next;
    if (reply is SSH_Message_Request_Failure) {
      return false;
    }

    return true;
  }

  /// Forward connections to a [localHost]:[localPort] to [remoteHost]:[remotePort]
  /// [localHost] and [localPort] are only required by the protocol and do not
  /// need to be specified in most cases.
  Future<SSHForwardChannel> forwardLocal(
    String remoteHost,
    int remotePort, {
    String localHost = 'localhost',
    int localPort = 0,
  }) async {
    await _authenticated.future;
    final channelController = await _openForwardLocalChannel(
      localHost,
      localPort,
      remoteHost,
      remotePort,
    );
    return SSHForwardChannel(channelController.channel);
  }

  /// Execute [command] on the remote side. Returns a [SSHChannel] that can be
  /// used to read and write to the remote side.
  Future<SSHSession> execute(
    String command, {
    SSHPtyConfig? pty,
    Map<String, String>? environment,
  }) async {
    await _authenticated.future;

    final channelController = await _openSessionChannel();

    if (environment != null) {
      for (var pair in environment.entries) {
        channelController.sendEnv(pair.key, pair.value);
      }
    }

    if (pty != null) {
      final ptyOk = await channelController.sendPtyReq(
        terminalType: pty.type,
        terminalWidth: pty.width,
        terminalHeight: pty.height,
        terminalPixelWidth: pty.pixelWidth,
        terminalPixelHeight: pty.pixelHeight,
      );
      if (!ptyOk) {
        channelController.close();
        throw SSHChannelRequestError('Failed to start pty');
      }
    }

    final success = await channelController.sendExec(command);
    if (!success) {
      channelController.close();
      throw SSHChannelRequestError('Failed to execute');
    }

    return SSHSession(channelController.channel);
  }

  /// Start a shell on the remote side. Returns a [SSHSession] that can be
  /// used to read, write and control the pty on the remote side.
  Future<SSHSession> shell({
    SSHPtyConfig? pty = const SSHPtyConfig(),
    Map<String, String>? environment,
  }) async {
    await _authenticated.future;

    final channelController = await _openSessionChannel();

    if (environment != null) {
      for (var pair in environment.entries) {
        channelController.sendEnv(pair.key, pair.value);
      }
    }

    if (pty != null) {
      final ok = await channelController.sendPtyReq(
        terminalType: pty.type,
        terminalWidth: pty.width,
        terminalHeight: pty.height,
        terminalPixelWidth: pty.pixelWidth,
        terminalPixelHeight: pty.pixelHeight,
      );
      if (!ok) {
        channelController.close();
        throw SSHChannelRequestError('Failed to start pty');
      }
    }

    if (!await channelController.sendShell()) {
      channelController.close();
      throw SSHChannelRequestError('Failed to start shell');
    }

    return SSHSession(channelController.channel);
  }

  Future<void> subsystem(String subsystem) async {
    await _authenticated.future;

    final channelController = await _openSessionChannel();
    channelController.sendSubsystem(subsystem);
  }

  /// Open a new SFTP session. Returns a [SftpClient] that can be used to
  /// interact with the remote side.
  Future<SftpClient> sftp() async {
    await _authenticated.future;

    final channelController = await _openSessionChannel();
    channelController.sendSubsystem('sftp');

    return SftpClient(
      channelController.channel,
      printDebug: printDebug,
      printTrace: printTrace,
    );
  }

  /// Create a new [SSHHttpClient] that can be used to make HTTP requests
  /// that are tunneled over the SSH connection. The returned [SSHHttpClient]
  /// is a very basic implementation, only intended for making simple requests.
  SSHHttpClient httpClient() {
    return SSHHttpClient(this);
  }

  /// Execute [command] on the remote side non-interactively. Returns a
  /// [Future<String?>] that completes with the output of the command.
  /// This is a convenience method over [execute]. If [stdout] is false,
  /// the standard output of the command will be ignored. If [stderr] is
  /// false, the standard error of the command will be ignored.
  Future<Uint8List> run(
    String command, {
    bool runInPty = false,
    bool stdout = true,
    bool stderr = true,
    Map<String, String>? environment,
  }) async {
    final session = await execute(
      command,
      pty: runInPty ? const SSHPtyConfig() : null,
      environment: environment,
    );

    final result = BytesBuilder(copy: false);
    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();

    session.stdout.listen(
      stdout ? result.add : (_) {},
      onDone: stdoutDone.complete,
      onError: stderrDone.completeError,
    );

    session.stderr.listen(
      stderr ? result.add : (_) {},
      onDone: stderrDone.complete,
      onError: stderrDone.completeError,
    );

    await stdoutDone.future;
    await stderrDone.future;

    return result.takeBytes();
  }

  /// Send a empty message to the server to keep the connection alive.
  Future<void> ping() async {
    await _authenticated.future;
    _sendMessage(SSH_Message_Global_Request.keepAlive());
    await _globalRequestReplyQueue.next;
  }

  /// Shutdown the entire SSH connection. Sessions and channels will also be
  /// closed immediately.
  void close() {
    _closeChannels();
    _transport.close();
  }

  /// Close all channels that are currently open.
  void _closeChannels() {
    // FUSHI PATCH (BUG-5483): once the transport is closed, channels can only
    // be torn down locally; destroy() would try to send EOF / close and throw.
    final transportClosed = _transport.isClosed;
    for (final channel in _channels.values) {
      transportClosed ? channel.abandon() : channel.destroy();
      _channelIdAllocator.release(channel.localId);
    }

    _channels.clear();
  }

  void _handleTransportReady() {
    printDebug?.call('SSHClient._onTransportReady');
    _requestAuthentication();
  }

  void _handleTransportClosed() {
    printDebug?.call('SSHClient._onTransportClosed');
    if (!_authenticated.isCompleted) {
      _authenticated.completeError(
        SSHAuthAbortError('Connection closed before authentication'),
      );
    }
    _keepAlive?.stop();
    _closeChannels();
  }

  void _handlePacket(Uint8List payload) {
    try {
      _dispatchMessage(payload);
    } catch (e) {
      rethrow;
    }
  }

  void _sendMessage(SSHMessage message) {
    printTrace?.call('-> $socket: $message');
    _transport.sendPacket(message.encode());
  }

  void _catch(FutureOr<dynamic> Function() fn) {
    Future.sync(fn).catchError((e, st) {
      _transport.closeWithError(SSHInternalError(e), st);
    });
  }

  void _dispatchMessage(Uint8List message) {
    final messageId = SSHMessage.readMessageId(message);
    switch (messageId) {
      case SSH_Message_Service_Accept.messageId:
        return _handleServiceAccept(message);
      case SSH_Message_Userauth_Success.messageId:
        return _handleUserauthSuccess();
      case SSH_Message_Userauth_Failure.messageId:
        return _handleUserauthFailure(message);
      case SSH_Message_Userauth_Passwd_ChangeReq.messageId:
        return _handleUserauthIntermidiate(message);
      case SSH_Message_Userauth_Banner.messageId:
        return _handleUserauthBanner(message);
      case SSH_Message_Global_Request.messageId:
        return _handleGlobalRequest(message);
      case SSH_Message_Request_Success.messageId:
        return _handleGlobalRequestSuccess(message);
      case SSH_Message_Request_Failure.messageId:
        return _handleGlobalRequestFailure(message);
      case SSH_Message_Channel_Open.messageId:
        return _handleChannelOpen(message);
      case SSH_Message_Channel_Confirmation.messageId:
        return _handleChannelConfirmation(message);
      case SSH_Message_Channel_Open_Failure.messageId:
        return _handleChannelOpenFailure(message);
      case SSH_Message_Channel_Window_Adjust.messageId:
        return _handleChannelWindowAdjust(message);
      case SSH_Message_Channel_Success.messageId:
        return _handleChannelSuccess(message);
      case SSH_Message_Channel_Failure.messageId:
        return _handleChannelFailure(message);
      case SSH_Message_Channel_Data.messageId:
        return _handleChannelData(message);
      case SSH_Message_Channel_Extended_Data.messageId:
        return _handleChannelExtendedData(message);
      case SSH_Message_Channel_EOF.messageId:
        return _handleChannelEOF(message);
      case SSH_Message_Channel_Close.messageId:
        return _handleChannelClose(message);
      case SSH_Message_Channel_Request.messageId:
        return _handleChannelRequest(message);
      default:
        printDebug?.call('unknown messageId: $messageId');
    }
  }

  void _handleServiceAccept(Uint8List payload) {
    final message = SSH_Message_Service_Accept.decode(payload);
    printTrace?.call('<- $socket: $message');

    switch (message.serviceName) {
      case 'ssh-userauth':
        return _startAuthentication();
      default:
        printDebug?.call('unknown serviceName: ${message.serviceName}');
    }
  }

  void _handleUserauthSuccess() {
    printTrace?.call('<- $socket: SSH_Message_Userauth_Success');
    printDebug?.call('SSHClient._handleUserauthSuccess');
    _authenticated.complete();
    onAuthenticated?.call();
    _keepAlive?.start();
  }

  void _handleUserauthFailure(Uint8List payload) {
    final message = SSH_Message_Userauth_Failure.decode(payload);
    printTrace?.call('<- $socket: $message');
    printDebug?.call('SSHClient._handleUserauthFailure');
    _tryNextAuthMethod();
  }

  void _handleUserauthIntermidiate(Uint8List payload) {
    printDebug?.call('SSHClient._handleUserauthIntermidiate');

    switch (_currentAuthMethod) {
      case SSHAuthMethod.password:
        return _catch(() => _handleUserauthPasswordChangeRequest(payload));
      case SSHAuthMethod.keyboardInteractive:
        return _catch(() => _handleUserauthInfoRequest(payload));
      default:
        printDebug?.call('unknown auth method: $_currentAuthMethod');
    }
  }

  Future<void> _handleUserauthPasswordChangeRequest(Uint8List payload) async {
    printDebug?.call('SSHClient._handleUserauthPasswordChangeRequest');
    final message = SSH_Message_Userauth_Passwd_ChangeReq.decode(payload);
    printTrace?.call('<- $socket: $message');

    final response = await onChangePasswordRequest!(message.prompt);
    if (response == null) return _tryNextAuthMethod();

    _sendMessage(SSH_Message_Userauth_Request.newPassword(
      user: username,
      oldPassword: response.oldPassword,
      newPassword: response.newPassword,
    ));
  }

  Future<void> _handleUserauthInfoRequest(Uint8List payload) async {
    printDebug?.call('SSHClient._handleUserauthInfoRequest');
    final message = SSH_Message_Userauth_InfoRequest.decode(payload);
    printTrace?.call('<- $socket: $message');

    final responses = await onUserInfoRequest!(
      SSHUserInfoRequest(message.name, message.instruction, message.prompts),
    );

    if (responses == null) return _tryNextAuthMethod();

    if (responses.length != message.prompts.length) {
      throw ArgumentError(
        'responses.length (${responses.length}) != message.prompts.length (${message.prompts.length})',
      );
    }

    _sendMessage(SSH_Message_Userauth_InfoResponse(responses: responses));
  }

  void _handleUserauthBanner(Uint8List payload) {
    final message = SSH_Message_Userauth_Banner.decode(payload);
    printDebug?.call('<- $socket: $message');
    onUserauthBanner?.call(message.message);
  }

  void _handleGlobalRequest(Uint8List payload) {
    final message = SSH_Message_Global_Request.decode(payload);
    printTrace?.call('<- $socket: $message');

    // Currently we don't support any global requests on the client side.
    if (message.wantReply) {
      _sendMessage(SSH_Message_Request_Failure());
    }
  }

  // void _handleGlobalRequestHostkey(SSH_Message_Global_Request request) {
  //   printDebug?.call('SSHClient._handleGlobalRequestHostkey');
  //   // sendMessage(SSH_Message_Request_Success.e
  //   if (onHostKeys != null) {
  //     // onHostKeys(request.hostKeyAlgorithms);
  //   }
  // }

  void _handleGlobalRequestSuccess(Uint8List payload) {
    final message = SSH_Message_Request_Success.decode(payload);
    printTrace?.call('<- $socket: $message');
    _globalRequestReplyQueue.add(message);
  }

  void _handleGlobalRequestFailure(Uint8List payload) {
    final message = SSH_Message_Request_Failure.decode(payload);
    printTrace?.call('<- $socket: $message');
    _globalRequestReplyQueue.add(message);
  }

  void _handleChannelOpen(Uint8List payload) {
    final message = SSH_Message_Channel_Open.decode(payload);
    printTrace?.call('<- $socket: $message');

    switch (message.channelType) {
      case 'forwarded-tcpip':
        return _handleForwardedTcpipChannelOpen(message);
    }

    printDebug?.call('unknown channelType: ${message.channelType}');
    final reply = SSH_Message_Channel_Open_Failure(
      recipientChannel: message.senderChannel,
      reasonCode: SSH_Message_Channel_Open_Failure.codeUnknownChannelType,
      description: 'unknown channel type: ${message.channelType}',
    );
    _sendMessage(reply);
  }

  void _handleForwardedTcpipChannelOpen(SSH_Message_Channel_Open message) {
    printDebug?.call('SSHClient._handleTcpipForwardChannelOpen');

    final remoteForward = _findRemoteForward(message.host!, message.port!);

    if (remoteForward == null) {
      printDebug?.call('unknown remote forward: $message');
      final reply = SSH_Message_Channel_Open_Failure(
        recipientChannel: message.senderChannel,
        reasonCode: SSH_Message_Channel_Open_Failure.codeUnknownChannelType,
        description: 'unknown remote forward: $message',
      );
      _sendMessage(reply);
      return;
    }

    if (remoteForward.filter != null) {
      if (!remoteForward.filter!(message.host!, message.port!)) {
        printDebug?.call('remote forward rejected by filter: $message');
        final reply = SSH_Message_Channel_Open_Failure(
          recipientChannel: message.senderChannel,
          reasonCode: 1, // SSH_OPEN_ADMINISTRATIVELY_PROHIBITED
          description: 'rejected by filter',
        );
        _sendMessage(reply);
        return;
      }
    }

    final localChannelId = _channelIdAllocator.allocate();

    final confirmation = SSH_Message_Channel_Confirmation(
      recipientChannel: message.senderChannel,
      senderChannel: localChannelId,
      initialWindowSize: _initialWindowSize,
      maximumPacketSize: _maximumPacketSize,
      data: Uint8List(0),
    );

    _sendMessage(confirmation);

    final channelController = _acceptChannel(
      localChannelId: localChannelId,
      remoteChannelId: message.senderChannel,
      remoteInitialWindowSize: message.initialWindowSize,
      remoteMaximumPacketSize: message.maximumPacketSize,
    );

    remoteForward._connections.add(
      SSHForwardChannel(channelController.channel),
    );
  }

  /// Finds a remote forward that matches the given host and port.
  SSHRemoteForward? _findRemoteForward(String host, int port) {
    final result = _remoteForwards.where(
      (forward) => forward.host == host && forward.port == port,
    );
    return result.isEmpty ? null : result.first;
  }

  void _handleChannelConfirmation(Uint8List payload) {
    final message = SSH_Message_Channel_Confirmation.decode(payload);
    printTrace?.call('<- $socket: $message');
    _dispatchChannelOpenReply(message.recipientChannel, message);
  }

  void _handleChannelOpenFailure(Uint8List payload) {
    final message = SSH_Message_Channel_Open_Failure.decode(payload);
    printTrace?.call('<- $socket: $message');
    _dispatchChannelOpenReply(message.recipientChannel, message);
  }

  void _handleChannelWindowAdjust(Uint8List payload) {
    final message = SSH_Message_Channel_Window_Adjust.decode(payload);
    printTrace?.call('<- $socket: $message');
    _channels[message.recipientChannel]?.handleMessage(message);
  }

  void _handleChannelRequest(Uint8List payload) {
    final message = SSH_Message_Channel_Request.decode(payload);
    printTrace?.call('<- $socket: $message');
    _channels[message.recipientChannel]?.handleMessage(message);
  }

  void _handleChannelSuccess(Uint8List payload) {
    final message = SSH_Message_Channel_Success.decode(payload);
    printTrace?.call('<- $socket: $message');
    _channels[message.recipientChannel]?.handleMessage(message);
  }

  void _handleChannelFailure(Uint8List payload) {
    final message = SSH_Message_Channel_Failure.decode(payload);
    printTrace?.call('<- $socket: $message');
    _channels[message.recipientChannel]?.handleMessage(message);
  }

  void _handleChannelData(Uint8List payload) {
    final message = SSH_Message_Channel_Data.decode(payload);
    printTrace?.call('<- $socket: $message');
    _channels[message.recipientChannel]?.handleMessage(message);
  }

  void _handleChannelExtendedData(Uint8List payload) {
    final message = SSH_Message_Channel_Extended_Data.decode(payload);
    printTrace?.call('<- $socket: $message');
    _channels[message.recipientChannel]?.handleMessage(message);
  }

  void _handleChannelEOF(Uint8List payload) {
    final message = SSH_Message_Channel_EOF.decode(payload);
    printTrace?.call('<- $socket: $message');
    _channels[message.recipientChannel]?.handleMessage(message);
  }

  void _handleChannelClose(Uint8List payload) {
    final message = SSH_Message_Channel_Close.decode(payload);
    printTrace?.call('<- $socket: $message');
    final channel = _channels[message.recipientChannel];
    if (channel != null) {
      channel.close();
      _channels.remove(message.recipientChannel);
      _channelIdAllocator.release(message.recipientChannel);
    }
  }

  void _requestAuthentication() {
    printDebug?.call('SSHClient._requestAuthentication');
    _sendMessage(SSH_Message_Service_Request('ssh-userauth'));
  }

  void _startAuthentication() {
    printDebug?.call('SSHClient._startAuthentication');

    if (identities != null && identities!.isNotEmpty) {
      _authMethodsLeft.add(SSHAuthMethod.publicKey);
    }

    if (onPasswordRequest != null) {
      _authMethodsLeft.add(SSHAuthMethod.password);
    }

    if (onUserInfoRequest != null) {
      _authMethodsLeft.add(SSHAuthMethod.keyboardInteractive);
    }

    _authMethodsLeft.add(SSHAuthMethod.none);

    _tryNextAuthMethod();
  }

  void _tryNextAuthMethod() {
    printDebug?.call('SSHClient._tryNextAuthenticationMethod');

    if (_currentAuthMethod == SSHAuthMethod.publicKey) {
      if (_keyPairsLeft.isNotEmpty) {
        return _authWithNextPublicKey();
      }
    }

    if (_authMethodsLeft.isEmpty) {
      return _authenticated.completeError(
        SSHAuthFailError('All authentication methods failed'),
        StackTrace.current,
      );
    }

    _currentAuthMethod = _authMethodsLeft.removeFirst();
    printDebug?.call('_currentAuthMethod = $_currentAuthMethod');

    switch (_currentAuthMethod!) {
      case SSHAuthMethod.none:
        return _authWithNone();
      case SSHAuthMethod.password:
        return _catch(() => _authWithPassword());
      case SSHAuthMethod.publicKey:
        return _authWithNextPublicKey();
      case SSHAuthMethod.keyboardInteractive:
        return _authWithKeyboardInteractive();
    }
  }

  void _authWithNone() {
    printDebug?.call('SSHClient._authWithNone');
    _sendMessage(SSH_Message_Userauth_Request.none(user: username));
  }

  Future<void> _authWithPassword() async {
    printDebug?.call('SSHClient._authWithPassword');

    final password = await onPasswordRequest!();
    if (password == null) {
      _tryNextAuthMethod();
      return;
    }

    _sendMessage(
      SSH_Message_Userauth_Request.password(user: username, password: password),
    );
  }

  void _authWithNextPublicKey() {
    printDebug?.call('SSHClient._authWithPublicKey');

    final keyPair = _keyPairsLeft.removeFirst();

    final challenge = _transport.composeChallenge(
      username: username,
      service: 'ssh-connection',
      publicKeyAlgorithm: keyPair.type,
      publicKey: keyPair.toPublicKey().encode(),
    );

    _sendMessage(
      SSH_Message_Userauth_Request.publicKey(
        username: username,
        publicKeyAlgorithm: keyPair.type,
        publicKey: keyPair.toPublicKey().encode(),
        signature: keyPair.sign(challenge).encode(),
        // signature: null,
      ),
    );
  }

  void _authWithKeyboardInteractive() {
    printDebug?.call('SSHClient._authWithKeyboardInteractive');
    _sendMessage(
      SSH_Message_Userauth_Request.keyboardInteractive(user: username),
    );
  }

  Future<SSHChannelController> _openSessionChannel() async {
    final localChannelId = _channelIdAllocator.allocate();

    final request = SSH_Message_Channel_Open.session(
      senderChannel: localChannelId,
      initialWindowSize: _initialWindowSize,
      maximumPacketSize: _maximumPacketSize,
    );
    _sendMessage(request);

    return await _waitChannelOpen(localChannelId);
  }

  Future<SSHChannelController> _openForwardLocalChannel(
    String bindAddress,
    int bindPort,
    String remoteAddress,
    int remotePort,
  ) async {
    final localChannelId = _channelIdAllocator.allocate();

    final request = SSH_Message_Channel_Open.directTcpip(
      senderChannel: localChannelId,
      initialWindowSize: _initialWindowSize,
      maximumPacketSize: _maximumPacketSize,
      host: remoteAddress,
      port: remotePort,
      originatorIP: bindAddress,
      originatorPort: bindPort,
    );
    _sendMessage(request);

    return await _waitChannelOpen(localChannelId);
  }

  Future<SSHChannelController> _waitChannelOpen(
    SSHChannelId localChannelId,
  ) async {
    final message = await _waitChannelOpenReply(localChannelId);
    if (message is SSH_Message_Channel_Open_Failure) {
      throw SSHChannelOpenError(message.reasonCode, message.description);
    }

    final reply = message as SSH_Message_Channel_Confirmation;
    if (reply.recipientChannel != localChannelId) {
      throw SSHStateError('Unexpected channel confirmation');
    }

    return _acceptChannel(
      localChannelId: localChannelId,
      remoteChannelId: reply.senderChannel,
      remoteInitialWindowSize: reply.initialWindowSize,
      remoteMaximumPacketSize: reply.maximumPacketSize,
    );
  }

  SSHChannelController _acceptChannel({
    required SSHChannelId localChannelId,
    required SSHChannelId remoteChannelId,
    required int remoteInitialWindowSize,
    required int remoteMaximumPacketSize,
  }) {
    final channelController = SSHChannelController(
      localId: localChannelId,
      localInitialWindowSize: _initialWindowSize,
      localMaximumPacketSize: _maximumPacketSize,
      remoteId: remoteChannelId,
      remoteInitialWindowSize: remoteInitialWindowSize,
      remoteMaximumPacketSize: remoteMaximumPacketSize,
      sendMessage: _sendMessage,
      printDebug: printDebug,
    );

    _channels[localChannelId] = channelController;
    return channelController;
  }

  Future<SSHMessage> _waitChannelOpenReply(SSHChannelId id) async {
    if (_channelOpenReplyWaiters.containsKey(id)) {
      printDebug?.call('_waitChannelOpenReply: already waiting for $id');
      return _channelOpenReplyWaiters[id]!.future;
    }
    final replyCompleter = Completer<SSHMessage>();
    _channelOpenReplyWaiters[id] = replyCompleter;
    return replyCompleter.future;
  }

  void _dispatchChannelOpenReply(SSHChannelId id, SSHMessage message) {
    if (!_channelOpenReplyWaiters.containsKey(id)) {
      printDebug?.call('_dispatchChannelOpenReply: no pending request for $id');
      return;
    }
    final replyCompleter = _channelOpenReplyWaiters.remove(id)!;
    replyCompleter.complete(message);
  }
}

class SSHRemoteForward {
  final String host;

  final int port;

  final SSHRemoteConnectionFilter? filter;

  SSHRemoteForward(this._client, this.host, this.port, this.filter);

  final SSHClient _client;

  final _connections = StreamController<SSHForwardChannel>();

  Stream<SSHForwardChannel> get connections => _connections.stream;

  void close() {
    _connections.close();
    _client.cancelForwardRemote(this);
  }

  @override
  String toString() => '$runtimeType($host:$port)';
}

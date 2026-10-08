import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dartssh2/src/sftp/sftp_errors.dart';
import 'package:dartssh2/src/sftp/sftp_file_attrs.dart';
import 'package:dartssh2/src/sftp/sftp_file_open_mode.dart';
import 'package:dartssh2/src/sftp/sftp_name.dart';
import 'package:dartssh2/src/sftp/sftp_packet.dart';
import 'package:dartssh2/src/sftp/sftp_packet_ext.dart';
import 'package:dartssh2/src/sftp/sftp_request_id.dart';
import 'package:dartssh2/src/sftp/sftp_statvfs.dart';
import 'package:dartssh2/src/sftp/sftp_stream_io.dart';
import 'package:dartssh2/src/ssh_channel.dart';
import 'package:dartssh2/src/ssh_transport.dart';
import 'package:dartssh2/src/utils/chunk_buffer.dart';
import 'package:dartssh2/src/ssh_message.dart';

const _kVersion = 3;

class SftpClient {
  final SSHChannel _channel;

  final SSHPrintHandler? printDebug;

  final SSHPrintHandler? printTrace;

  SftpClient(this._channel, {this.printDebug, this.printTrace}) {
    _startHandshake();
    _channel.stream.listen(_handleData);
  }

  final _buffer = ChunkBuffer();

  final _handshake = Completer<SftpHandsake>();

  final _done = Completer<void>();

  final _requestId = SftpRequestId();

  final _replyWaiters = <int, Completer<SftpResponsePacket>>{};

  /// The handshake information received from the server.
  Future<SftpHandsake> get handshake => _handshake.future;

  /// Gets the attributes of the file at [path].
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async {
    final reply = followLink ? await _sendStat(path) : await _sendLStat(path);
    if (reply is SftpAttrsPacket) return reply.attrs;
    if (reply is! SftpStatusPacket) throw SftpError('Unexpected reply');
    throw SftpStatusError.fromStatus(reply);
  }

  /// Sets the attributes of the file at [path].
  Future<void> setStat(String path, SftpFileAttrs attrs) async {
    final reply = await _sendSetStat(path, attrs);
    if (reply is! SftpStatusPacket) throw SftpError('Unexpected reply');
    SftpStatusError.check(reply);
  }

  /// Opens a file for reading or/and writing.
  Future<SftpFile> open(
    String path, {
    SftpFileOpenMode mode = SftpFileOpenMode.read,
  }) async {
    final reply = await _sendOpen(path, mode, SftpFileAttrs());
    if (reply is SftpHandlePacket) return SftpFile(this, reply.handle);
    if (reply is! SftpStatusPacket) throw SftpError('Unexpected reply');
    throw SftpStatusError.fromStatus(reply);
  }

  /// Reads the items of a directory. Returns an [Stream] of [SftpName] chunks.
  /// Use [listdir] instead of this unless the directory contains a large number
  /// of items.
  Stream<List<SftpName>> readdir(String path) async* {
    final dir = await _opendir(path);
    while (true) {
      final names = await _readdir(dir);
      if (names == null) break;
      yield names;
    }
    await _close(dir);
  }

  /// List the items of a directory. This is a convenience method wrapping
  /// [readdir].
  Future<List<SftpName>> listdir(String path) async {
    final result = <SftpName>[];
    await for (final names in readdir(path)) {
      result.addAll(names);
    }
    return result;
  }

  /// Remove a file whose name is [filename]. This can only be used to remove
  /// files. Use [rmdir] to remove a directory.
  Future<void> remove(String filename) async {
    final reply = await _sendRemove(filename);
    if (reply is! SftpStatusPacket) throw SftpError('Unexpected reply');
    SftpStatusError.check(reply);
  }

  /// Makes a directory at the given [path].
  Future<void> mkdir(String path, [SftpFileAttrs? attrs]) async {
    final reply = await _sendMakeDir(path, attrs ?? SftpFileAttrs());
    if (reply is! SftpStatusPacket) throw SftpError('Unexpected reply');
    SftpStatusError.check(reply);
  }

  /// Removes a directory whose name is [dirname]. This can only be used to
  /// remove directories. Use [remove] to remove a file.
  /// This will fail if the directory is not empty.
  Future<void> rmdir(String dirname) async {
    final reply = await _sendRemoveDir(dirname);
    if (reply is! SftpStatusPacket) throw SftpError('Unexpected reply');
    SftpStatusError.check(reply);
  }

  /// Returns the absolute path of [path].
  Future<String> absolute(String path) async {
    final reply = await _sendRealPath(path);
    if (reply is SftpNamePacket) return reply.names.first.filename;
    if (reply is! SftpStatusPacket) throw SftpError('Unexpected reply');
    throw SftpStatusError.fromStatus(reply);
  }

  /// Renames a file or directory from [oldPath] to [newPath].
  Future<void> rename(String oldPath, String newPath) async {
    final reply = await _sendRename(oldPath, newPath);
    if (reply is! SftpStatusPacket) throw SftpError('Unexpected reply');
    SftpStatusError.check(reply);
  }

  /// Reads the target of a symbolic link.
  Future<String> readlink(String path) async {
    final reply = await _sendReadLink(path);
    if (reply is SftpNamePacket) return reply.names.first.filename;
    if (reply is! SftpStatusPacket) throw SftpError('Unexpected reply');
    throw SftpStatusError.fromStatus(reply);
  }

  /// Creates a symbolic link at [targetPath] that points to [linkPath].
  Future<void> link(String linkPath, String targetPath) async {
    final reply = await _sendSymlink(linkPath, targetPath);
    if (reply is! SftpStatusPacket) throw SftpError('Unexpected reply');
    SftpStatusError.check(reply);
  }

  /// Gets the information about a mounted filesystem. [path] is the pathname of
  /// any file within the mounted filesystem.
  ///
  /// **Note**: This is an extension to the SFTP protocol, supported by most
  /// openssh servers. A [SftpExtensionError] is thrown if the server does not
  /// support this extension.
  ///
  /// See also:
  ///
  /// - [SftpFile.statvfs] which requires an open [SftpFile] instance instead of
  ///   a path.
  Future<SftpStatVfs> statvfs(String path) async {
    await _checkExtension('statvfs@openssh.com', '2');
    final payload = SftpStatVfsRequest(path: path);
    final reply = await _sendExtended(payload);
    if (reply is SftpStatusPacket) throw SftpStatusError.fromStatus(reply);
    if (reply is! SftpExtendedReplyPacket) throw SftpError('Unexpected reply');
    final stat = SftpStatVfsReply.decode(reply.payload);
    return SftpStatVfs.fromReply(stat);
  }

  /// Close the sftp session.
  void close() {
    for (var waiter in _replyWaiters.values) {
      waiter.completeError(SftpAbortError("Connection closed"));
    }
    _replyWaiters.clear();
    _done.complete();
  }

  void _closeError(Object error, [StackTrace? stackTrace]) {
    stackTrace ??= StackTrace.current;
    for (var waiter in _replyWaiters.values) {
      waiter.completeError(error, stackTrace);
    }
    _replyWaiters.clear();
    _done.completeError(error, stackTrace);
  }

  void _startHandshake() {
    _sendPacket(SftpInitPacket(_kVersion));
  }

  /// Open a directory and return the handle.
  Future<Uint8List> _opendir(String path) async {
    final reply = await _sendOpenDir(path);
    if (reply is SftpHandlePacket) return reply.handle;
    if (reply is! SftpStatusPacket) throw SftpError('Unexpected reply');
    throw SftpStatusError.fromStatus(reply);
  }

  /// Reads the next bunch of entries from the directory. Returns `null` when
  /// there are no more entries.
  Future<List<SftpName>?> _readdir(Uint8List handle) async {
    final reply = await _sendReadDir(handle);
    if (reply is SftpNamePacket) return reply.names;
    if (reply is! SftpStatusPacket) throw SftpError('Unexpected reply');
    SftpStatusError.check(reply);
    return null;
  }

  Future<void> _close(Uint8List handle) async {
    final reply = await _sendClose(handle);
    if (reply is! SftpStatusPacket) throw SftpError('Unexpected reply');
    SftpStatusError.check(reply);
  }

  void _sendPacket(SftpPacket packet) {
    printTrace?.call('-> $_channel: $packet');
    final data = packet.encode();
    final writer = SSHMessageWriter();
    writer.writeUint32(data.length);
    writer.writeBytes(data);
    _channel.addData(writer.takeBytes());
  }

  Future<SftpResponsePacket> _sendOpen(
    String path,
    SftpFileOpenMode mode,
    SftpFileAttrs attrs,
  ) async {
    await handshake;
    final request = SftpOpenPacket(_requestId.next, path, mode.flag, attrs);
    _sendPacket(request);
    return await _waitReply(request.requestId);
  }

  Future<SftpResponsePacket> _sendClose(Uint8List handle) async {
    await handshake;
    final request = SftpClosePacket(_requestId.next, handle);
    _sendPacket(request);
    return await _waitReply(request.requestId);
  }

  Future<SftpResponsePacket> _sendRead(
    Uint8List handle,
    int offset,
    int length,
  ) async {
    await handshake;
    final request = SftpReadPacket(
      requestId: _requestId.next,
      handle: handle,
      offset: offset,
      length: length,
    );
    _sendPacket(request);
    return await _waitReply(request.requestId);
  }

  Future<SftpResponsePacket> _sendWrite(
    Uint8List handle,
    int offset,
    Uint8List data,
  ) async {
    await handshake;
    final request = SftpWritePacket(
      requestId: _requestId.next,
      handle: handle,
      offset: offset,
      data: data,
    );
    _sendPacket(request);
    return await _waitReply(request.requestId);
  }

  Future<SftpResponsePacket> _sendLStat(String path) async {
    await handshake;
    final request = SftpLStatPacket(_requestId.next, path);
    _sendPacket(request);
    return await _waitReply(request.requestId);
  }

  Future<SftpResponsePacket> _sendFStat(Uint8List handle) async {
    await handshake;
    final request = SftpFStatPacket(_requestId.next, handle);
    _sendPacket(request);
    return await _waitReply(request.requestId);
  }

  Future<SftpResponsePacket> _sendSetStat(
    String path,
    SftpFileAttrs attrs,
  ) async {
    await handshake;
    final request = SftpSetStatPacket(_requestId.next, path, attrs);
    _sendPacket(request);
    return await _waitReply(request.requestId);
  }

  Future<SftpResponsePacket> _sendFSetStat(
    Uint8List handle,
    SftpFileAttrs attrs,
  ) async {
    await handshake;
    final request = SftpFSetStatPacket(_requestId.next, handle, attrs);
    _sendPacket(request);
    return await _waitReply(request.requestId);
  }

  Future<SftpResponsePacket> _sendOpenDir(String path) async {
    await handshake;
    final request = SftpOpenDirPacket(_requestId.next, path);
    _sendPacket(request);
    return await _waitReply(request.requestId);
  }

  Future<SftpResponsePacket> _sendReadDir(Uint8List handle) async {
    await handshake;
    final request = SftpReadDirPacket(_requestId.next, handle);
    _sendPacket(request);
    return await _waitReply(request.requestId);
  }

  Future<SftpResponsePacket> _sendRemove(String filename) async {
    await handshake;
    final request = SftpRemovePacket(_requestId.next, filename);
    _sendPacket(request);
    return await _waitReply(request.requestId);
  }

  Future<SftpResponsePacket> _sendMakeDir(
    String path,
    SftpFileAttrs attrs,
  ) async {
    await handshake;
    final request = SftpMkdirPacket(_requestId.next, path, attrs);
    _sendPacket(request);
    return await _waitReply(request.requestId);
  }

  Future<SftpResponsePacket> _sendRemoveDir(String path) async {
    await handshake;
    final request = SftpRmdirPacket(_requestId.next, path);
    _sendPacket(request);
    return await _waitReply(request.requestId);
  }

  Future<SftpResponsePacket> _sendRealPath(String path) async {
    await handshake;
    final request = SftpRealpathPacket(_requestId.next, path);
    _sendPacket(request);
    return await _waitReply(request.requestId);
  }

  Future<SftpResponsePacket> _sendStat(String path) async {
    await handshake;
    final request = SftpStatPacket(_requestId.next, path);
    _sendPacket(request);
    return await _waitReply(request.requestId);
  }

  Future<SftpResponsePacket> _sendRename(
    String oldPath,
    String newPath,
  ) async {
    await handshake;
    final request = SftpRenamePacket(_requestId.next, oldPath, newPath);
    _sendPacket(request);
    return await _waitReply(request.requestId);
  }

  Future<SftpResponsePacket> _sendReadLink(String path) async {
    await handshake;
    final request = SftpReadlinkPacket(_requestId.next, path);
    _sendPacket(request);
    return await _waitReply(request.requestId);
  }

  Future<SftpResponsePacket> _sendSymlink(
    String linkPath,
    String targetPath,
  ) async {
    await handshake;
    final request = SftpSymlinkPacket(_requestId.next, linkPath, targetPath);
    _sendPacket(request);
    return await _waitReply(request.requestId);
  }

  Future<SftpResponsePacket> _sendExtended(SftpExtendedRequest payload) async {
    await handshake;
    final request = SftpExtendedPacket(_requestId.next, payload.encode());
    _sendPacket(request);
    return await _waitReply(request.requestId);
  }

  void _dispatchReply(SftpResponsePacket packet) {
    final completer = _replyWaiters.remove(packet.requestId);
    completer?.complete(packet);
  }

  Future<SftpResponsePacket> _waitReply(int requestId) {
    final completer = Completer<SftpResponsePacket>();
    _replyWaiters[requestId] = completer;
    return completer.future;
  }

  Future<void> _checkExtension(String name, String version) async {
    final handshake = await this.handshake;
    final extensionVersion = handshake.extensions[name];
    if (extensionVersion == null) {
      throw SftpExtensionUnsupportedError(name);
    }
    if (extensionVersion != version) {
      throw SftpExtensionVersionMismatchError(name, extensionVersion);
    }
  }

  void _handleData(SSHChannelData data) {
    _buffer.add(data.bytes);
    _handlePackets();
  }

  void _handlePackets() {
    const lengthHeader = 4; // 4 bytes packet length header
    while (_buffer.length >= lengthHeader) {
      final length = _buffer.byteData.getUint32(0);
      if (_buffer.length < lengthHeader + length) break;
      final packet = _buffer.consume(lengthHeader + length);
      final payload = Uint8List.sublistView(packet, lengthHeader);
      _handlePacket(payload);
    }
  }

  void _handlePacket(Uint8List payload) {
    final type = payload[0];
    switch (type) {
      case SftpVersionPacket.packetType:
        return _handleVersionPacket(payload);
      case SftpStatusPacket.packetType:
        return _handleStatusPacket(payload);
      case SftpHandlePacket.packetType:
        return _handleHandlePacket(payload);
      case SftpDataPacket.packetType:
        return _handleDataPacket(payload);
      case SftpNamePacket.packetType:
        return _handleNamePacket(payload);
      case SftpAttrsPacket.packetType:
        return _handleAttrsPacket(payload);
      case SftpExtendedReplyPacket.packetType:
        return _handleExtendedReplyPacket(payload);
      default:
        printDebug?.call('SftpClient._handlePacket: unknown packet: $type');
    }
  }

  void _handleVersionPacket(Uint8List payload) {
    final packet = SftpVersionPacket.decode(payload);
    printTrace?.call('<- $_channel: $packet');

    if (packet.version == _kVersion) {
      final handshake = SftpHandsake(packet.version, packet.extensions);
      return _handshake.complete(handshake);
    }

    final error = SftpError('Version mismatch: ${packet.version}');
    _handshake.completeError(error, StackTrace.current);
    _closeError(error);
  }

  void _handleStatusPacket(Uint8List payload) {
    final packet = SftpStatusPacket.decode(payload);
    printTrace?.call('<- $_channel: $packet');
    _dispatchReply(packet);
  }

  void _handleHandlePacket(Uint8List payload) {
    final packet = SftpHandlePacket.decode(payload);
    printTrace?.call('<- $_channel: $packet');
    _dispatchReply(packet);
  }

  void _handleNamePacket(Uint8List payload) {
    final packet = SftpNamePacket.decode(payload);
    printTrace?.call('<- $_channel: $packet');
    _dispatchReply(packet);
  }

  void _handleDataPacket(Uint8List payload) {
    final packet = SftpDataPacket.decode(payload);
    printTrace?.call('<- $_channel: len=${packet.data.length}');
    _dispatchReply(packet);
  }

  void _handleAttrsPacket(Uint8List payload) {
    final packet = SftpAttrsPacket.decode(payload);
    printTrace?.call('<- $_channel: $packet');
    _dispatchReply(packet);
  }

  void _handleExtendedReplyPacket(Uint8List payload) {
    final packet = SftpExtendedReplyPacket.decode(payload);
    printTrace?.call('<- $_channel: $packet');
    _dispatchReply(packet);
  }
}

class SftpFile {
  final Uint8List _handle;

  final SftpClient _client;

  SftpFile(this._client, this._handle);

  var _isClosed = false;

  bool get isClosed => _isClosed;

  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    await _client._close(_handle);
  }

  Future<SftpFileAttrs> stat() async {
    _mustNotBeClosed();
    final reply = await _client._sendFStat(_handle);
    if (reply is SftpAttrsPacket) return reply.attrs;
    if (reply is! SftpStatusPacket) throw SftpError('Unexpected reply');
    throw SftpStatusError.fromStatus(reply);
  }

  Future<void> setStat(SftpFileAttrs attrs) async {
    _mustNotBeClosed();
    final reply = await _client._sendFSetStat(_handle, attrs);
    if (reply is! SftpStatusPacket) throw SftpError('Unexpected reply');
    SftpStatusError.check(reply);
  }

  /// Reads at most [count] bytes from the file starting at [offset]. If
  /// [length] is null, reads until end of file.  Returns a [Stream] of chunks.
  /// [onProgress] is called with the total number of bytes already read.
  /// Use [readBytes] if you want a single Uint8List.
  Stream<Uint8List> read({
    int? length,
    int offset = 0,
    void Function(int bytesRead)? onProgress,
  }) async* {
    const chunkSize = 16 * 1024;
    const maxBytesOnTheWire = chunkSize * 64;

    // Get the file size if not specified.
    if (length == null) {
      final fileStat = await stat();
      final fileSize = fileStat.size;

      if (fileSize == null) {
        throw SftpError('Can not get file size');
      }

      length = fileSize - offset;
    }

    if (length == 0) return;

    if (length < 0) {
      throw SftpError('Length must be positive: $length');
    }

    final streamController = StreamController<Uint8List>();

    var bytessRecieved = 0;
    var bytessRequested = 0;

    Future<void> readChunk(int chunkStart) async {
      final chunkEnd = min(chunkStart + chunkSize, offset + length!);
      final chunkLength = chunkEnd - chunkStart;

      bytessRequested += chunkLength;

      late final Uint8List? chunk;

      try {
        chunk = await _readChunk(chunkLength, chunkStart);
      } catch (e, st) {
        if (!streamController.isClosed) {
          streamController.addError(e, st);
          streamController.close();
        }
        return;
      }

      if (chunk == null) {
        streamController.close();
        return;
      }

      streamController.add(chunk);
      bytessRecieved += chunkLength;

      if (onProgress != null) onProgress(bytessRecieved);

      if (bytessRecieved >= length!) {
        streamController.close();
        return;
      }
    }

    void scheduleRead() {
      if (streamController.isPaused || streamController.isClosed) {
        return;
      }

      while (bytessRequested < length!) {
        final bytesOnTheWire = bytessRequested - bytessRecieved;
        if (bytesOnTheWire >= maxBytesOnTheWire) return;
        readChunk(bytessRequested + offset).then((_) => scheduleRead());
      }
    }

    streamController.onListen = scheduleRead;
    streamController.onResume = scheduleRead;

    yield* streamController.stream;
  }

  /// Reads at most [length] bytes from the file starting at [offset]. If
  /// [length] is null, reads until end of the file.
  /// Use [read] if you want to stream large file in chunks.
  Future<Uint8List> readBytes({int? length, int offset = 0}) async {
    final buffer = BytesBuilder(copy: false);
    await for (final chunk in read(length: length, offset: offset)) {
      buffer.add(chunk);
    }
    return buffer.takeBytes();
  }

  /// Writes [stream] to the file starting at [offset].
  ///
  /// Returns a [SftpFileWriter] that can be used to control the write
  /// operation or wait for it to complete.
  SftpFileWriter write(
    Stream<Uint8List> stream, {
    int offset = 0,
    void Function(int total)? onProgress,
  }) {
    return SftpFileWriter(this, stream, offset, onProgress);
  }

  /// Writes [data] to the file starting at [offset].
  Future<void> writeBytes(Uint8List data, {int offset = 0}) async {
    const maxChunkSize = 16 * 1024;
    var bytesSent = 0;
    final futures = <Future<void>>[];
    while (bytesSent < data.length) {
      final chunkSize = min(data.length - bytesSent, maxChunkSize);
      final chunkBegin = bytesSent;
      final chunkEnd = chunkBegin + chunkSize;
      final chunk = Uint8List.sublistView(data, chunkBegin, chunkEnd);
      futures.add(_writeChunk(chunk, offset: offset + bytesSent));
      bytesSent += chunkSize;
    }
    await Future.wait(futures);
  }

  /// Gets filesystem statistics that this file is on.
  ///
  /// **Note**: This is an extension to the SFTP protocol, supported by most
  /// openssh servers. A [SftpExtensionError] is thrown if the server does not
  /// support this extension.
  ///
  /// See also:
  ///
  /// * [SftpClient.statvfs] which takes a path instead of a file handle as
  ///   argument.
  Future<SftpStatVfs> statvfs() async {
    _mustNotBeClosed();
    await _client._checkExtension('fstatvfs@openssh.com', '2');
    final payload = SftpFstatVfsRequest(handle: _handle);
    final reply = await _client._sendExtended(payload);
    if (reply is SftpStatusPacket) throw SftpStatusError.fromStatus(reply);
    if (reply is! SftpExtendedReplyPacket) throw SftpError('Unexpected reply');
    final stat = SftpStatVfsReply.decode(reply.payload);
    return SftpStatVfs.fromReply(stat);
  }

  Future<void> _writeChunk(Uint8List data, {int offset = 0}) async {
    // print('_writeChunk: offset=$offset');
    _mustNotBeClosed();
    final reply = await _client._sendWrite(_handle, offset, data);
    if (reply is! SftpStatusPacket) throw SftpError('Unexpected reply');
    SftpStatusError.check(reply);
  }

  Future<Uint8List?> _readChunk(int length, [int offset = 0]) async {
    _mustNotBeClosed();
    final reply = await _client._sendRead(_handle, offset, length);
    if (reply is SftpDataPacket) return reply.data;
    if (reply is! SftpStatusPacket) throw SftpError('Unexpected reply');
    SftpStatusError.check(reply);
    return null;
  }

  void _mustNotBeClosed() {
    if (isClosed) throw SftpError('File is closed');
  }

  @override
  String toString() => 'SftpFile(0x${hex.encode(_handle)})';
}

/// Handsake information received from the server.
class SftpHandsake {
  final int version;

  final Map<String, String> extensions;

  SftpHandsake(this.version, this.extensions);

  @override
  String toString() => 'SftpHandsake($version, $extensions)';
}

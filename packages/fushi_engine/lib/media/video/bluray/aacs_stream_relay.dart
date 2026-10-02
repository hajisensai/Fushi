import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:fushi_engine/media/video/bluray/aacs_content_decoder.dart';

/// An authenticated loopback view of one decrypted M2TS file.
///
/// File reads, AES and HTTP backpressure stay in a dedicated isolate. The URL
/// is a bearer capability: never persist or log it. Closing drains all request
/// finalizers before the worker exits, releasing optical-disc file handles.
final class AacsStreamRelay {
  AacsStreamRelay._(this.url, this._commands, this._exited);

  final String url;
  final SendPort _commands;
  final Future<void> _exited;
  Future<void>? _closing;

  static Future<AacsStreamRelay> open({
    required String streamPath,
    required Uint8List unitKeyFile,
    required Uint8List volumeUniqueKey,
  }) async {
    final ready = ReceivePort();
    final exited = ReceivePort();
    final exitFuture = exited.first.then<void>((_) => exited.close());
    try {
      await Isolate.spawn<List<Object>>(_serve, [
        ready.sendPort,
        streamPath,
        unitKeyFile,
        volumeUniqueKey,
      ], onExit: exited.sendPort);
      final result = await ready.first as List<Object>;
      if (result.length != 2) {
        await exitFuture;
        throw StateError('Unable to initialize AACS stream');
      }
      return AacsStreamRelay._(
        result[1] as String,
        result[0] as SendPort,
        exitFuture,
      );
    } catch (_) {
      exited.close();
      rethrow;
    } finally {
      ready.close();
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _commands.send(null);
    await _exited;
  }

  static Future<void> _serve(List<Object> args) async {
    final ready = args[0] as SendPort;
    final commands = ReceivePort();
    HttpServer? server;
    final requests = <Future<void>>{};
    var closing = false;
    try {
      final file = File(args[1] as String);
      final length = await file.length();
      if (length == 0 || length % AacsContentDecoder.alignedUnitLength != 0) {
        throw const FormatException('Incomplete AACS stream');
      }
      final decoder = AacsContentDecoder.fromVolumeUniqueKey(
        unitKeyFile: args[2] as Uint8List,
        volumeUniqueKey: args[3] as Uint8List,
      );
      // Fail before handing the URL to a player when its key cannot decode it.
      final probe = await file.open();
      try {
        decoder.decryptUnit(
          await _readExactly(probe, AacsContentDecoder.alignedUnitLength),
        );
      } finally {
        await probe.close();
      }
      final random = Random.secure();
      final token = base64Url.encode(
        List<int>.generate(32, (_) => random.nextInt(256)),
      );
      final path = '/$token/stream.m2ts';
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        late final Future<void> task;
        task = _respond(
          request,
          file,
          length,
          path,
          decoder,
          () => closing,
        ).whenComplete(() => requests.remove(task));
        requests.add(task);
      });
      ready.send([commands.sendPort, 'http://127.0.0.1:${server.port}$path']);
      await commands.first;
    } catch (_) {
      // Neither paths, bearer URLs nor key bytes cross an error/log boundary.
      ready.send(<Object>[]);
    } finally {
      closing = true;
      await server?.close(force: true);
      await Future.wait(requests.toList());
      commands.close();
    }
  }

  static Future<void> _respond(
    HttpRequest request,
    File file,
    int length,
    String path,
    AacsContentDecoder decoder,
    bool Function() isClosing,
  ) async {
    final response = request.response;
    RandomAccessFile? input;
    try {
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      if (request.uri.path != path || request.uri.hasQuery) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
        return;
      }
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.contentType = ContentType('video', 'mp2t');
      final range = _range(
        request.headers.value(HttpHeaders.rangeHeader),
        length,
      );
      if (range == null) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
        response.contentLength = 0;
        return;
      }
      final (start, end) = range;
      if (request.headers.value(HttpHeaders.rangeHeader) != null) {
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$length',
        );
      }
      response.contentLength = end - start + 1;
      if (request.method == 'HEAD') return;
      input = await file.open();
      const unitLength = AacsContentDecoder.alignedUnitLength;
      var position = start ~/ unitLength * unitLength;
      await input.setPosition(position);
      while (position <= end && !isClosing()) {
        final chunkLength = min(
          32 * unitLength,
          ((end - position) ~/ unitLength + 1) * unitLength,
        );
        final chunk = await _readExactly(input, chunkLength);
        if (isClosing()) break;
        for (var offset = 0; offset < chunkLength; offset += unitLength) {
          decoder.decryptUnit(
            Uint8List.sublistView(chunk, offset, offset + unitLength),
          );
        }
        response.add(
          Uint8List.sublistView(
            chunk,
            max(0, start - position),
            min(chunkLength, end - position + 1),
          ),
        );
        await response.flush();
        position += chunkLength;
      }
    } catch (_) {
      // A failed decode must terminate the byte stream, never serve ciphertext.
      try {
        final socket = await response.detachSocket(writeHeaders: false);
        socket.destroy();
      } catch (_) {
        // A disconnected consumer has already disposed the response socket.
      }
    } finally {
      await input?.close();
      try {
        await response.close();
      } catch (_) {
        // Expected after consumer cancellation or forced session shutdown.
      }
    }
  }

  static Future<Uint8List> _readExactly(
    RandomAccessFile input,
    int length,
  ) async {
    final bytes = Uint8List(length);
    var read = 0;
    while (read < length) {
      final count = await input.readInto(bytes, read);
      if (count == 0) {
        throw const FileSystemException('Truncated AACS stream');
      }
      read += count;
    }
    return bytes;
  }

  static (int, int)? _range(String? value, int length) {
    if (value == null) return (0, length - 1);
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(value.trim());
    if (match == null) return null;
    final first = match[1]!;
    final last = match[2]!;
    if (first.isEmpty) {
      final suffix = int.tryParse(last);
      if (suffix == null || suffix <= 0) return null;
      return (max(0, length - suffix), length - 1);
    }
    final start = int.tryParse(first);
    final end = last.isEmpty ? length - 1 : int.tryParse(last);
    if (start == null || end == null || start >= length || end < start) {
      return null;
    }
    return (start, min(end, length - 1));
  }
}

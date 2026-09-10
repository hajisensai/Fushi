import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

const int anidbEd2kChunkSize = 9728000;

class AnidbEd2kHash {
  const AnidbEd2kHash(
      {required this.ed2k,
      required this.size,
      required this.modifiedAt,
      required this.changedAt,
      this.alternativeEd2k});

  final String ed2k;
  final String? alternativeEd2k;
  final int size;
  final DateTime modifiedAt;
  final DateTime changedAt;
}

class AnidbHashCancelled implements Exception {
  const AnidbHashCancelled();
}

/// Reads a bounded buffer on a worker isolate; cancellation also stops its I/O.
/// Rejects files changed while reading, so callers must not cache partial hashes.
Future<AnidbEd2kHash> hashAnidbFile(
  String path, {
  bool Function()? isCancelled,
  void Function(int completedBytes, int totalBytes)? onProgress,
}) async {
  if (isCancelled?.call() ?? false) throw const AnidbHashCancelled();
  final ReceivePort port = ReceivePort();
  final Completer<AnidbEd2kHash> result = Completer<AnidbEd2kHash>();
  Isolate? worker;
  SendPort? cancellationPort;
  Object? pendingError;
  StackTrace? pendingStack;
  Timer? cancellationTimer;
  void cancel(Object error, [StackTrace? stack]) {
    pendingError ??= error;
    pendingStack ??= stack;
    cancellationPort?.send(true);
  }

  final StreamSubscription<dynamic> subscription =
      port.listen((dynamic message) {
    if (result.isCompleted) return;
    try {
      if (pendingError == null) {
        try {
          if (isCancelled?.call() ?? false) cancel(const AnidbHashCancelled());
        } catch (error, stack) {
          cancel(error, stack);
        }
      }
      if (message is SendPort) {
        cancellationPort = message;
        if (pendingError != null) message.send(true);
      } else if (message is AnidbEd2kHash) {
        if (pendingError != null) {
          result.completeError(pendingError!, pendingStack);
        } else {
          result.complete(message);
        }
      } else if (message is List<int>) {
        if (pendingError == null) onProgress?.call(message[0], message[1]);
      } else if (message is List && message.length == 2) {
        result.completeError(pendingError ?? message[0] as Object,
            pendingStack ?? StackTrace.fromString(message[1].toString()));
      } else if (message == null) {
        result.completeError(
            pendingError ?? StateError('ED2K worker exited without a result'),
            pendingStack);
      }
    } catch (error, stack) {
      cancel(error, stack);
    }
  });
  try {
    worker = await Isolate.spawn(_hashFileWorker, (path, port.sendPort),
        onError: port.sendPort, onExit: port.sendPort);
    if (isCancelled != null) {
      cancellationTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        if (result.isCompleted) return;
        try {
          if (isCancelled()) cancel(const AnidbHashCancelled());
        } catch (error, stack) {
          cancel(error, stack);
        }
      });
    }
    return await result.future;
  } finally {
    cancellationTimer?.cancel();
    worker?.kill(priority: Isolate.immediate);
    await subscription.cancel();
    port.close();
  }
}

Future<void> _hashFileWorker((String, SendPort) request) async {
  final (String path, SendPort port) = request;
  final ReceivePort cancellation = ReceivePort();
  bool cancelled = false;
  cancellation.listen((dynamic _) {
    cancelled = true;
  });
  port.send(cancellation.sendPort);
  try {
    final File file = File(path);
    final FileStat before = await file.stat();
    if (before.type != FileSystemEntityType.file) {
      throw FileSystemException('Not a regular file', path);
    }
    final AnidbEd2kAccumulator digest = AnidbEd2kAccumulator();
    int completed = 0;
    int reported = 0;
    port.send(<int>[0, before.size]);
    final RandomAccessFile input = await file.open();
    try {
      final Uint8List buffer = Uint8List(64 * 1024);
      while (true) {
        if (cancelled) throw const AnidbHashCancelled();
        final int count = await input.readInto(buffer);
        if (cancelled) throw const AnidbHashCancelled();
        if (count == 0) break;
        digest.add(Uint8List.sublistView(buffer, 0, count));
        completed += count;
        if (completed - reported >= 1024 * 1024) {
          reported = completed;
          port.send(<int>[completed, before.size]);
        }
      }
    } finally {
      // Cancellation is acknowledged only after the native handle is closed.
      // Isolate.kill alone may leave an outstanding OS read holding this file.
      await input.close();
    }
    final FileStat after = await file.stat();
    if (before.size != completed ||
        before.size != after.size ||
        before.modified != after.modified ||
        before.changed != after.changed ||
        after.type != FileSystemEntityType.file) {
      throw FileSystemException('File changed while calculating ED2K', path);
    }
    final (String hash, String? alternative) = digest.finish();
    port.send(<int>[completed, before.size]);
    port.send(AnidbEd2kHash(
        ed2k: hash,
        alternativeEd2k: alternative,
        size: completed,
        modifiedAt: before.modified,
        changedAt: before.changed));
  } catch (error, stack) {
    port.send(<Object>[error, stack.toString()]);
  } finally {
    cancellation.close();
  }
}

/// AniDB/AVDump3 red ED2K, plus the blue variant at exact chunk boundaries.
/// https://wiki.anidb.net/Ed2k-hash
/// Both aggregate contexts are incremental: memory is independent of file size.
class AnidbEd2kAccumulator {
  _Md4 _chunk = _Md4();
  final _Md4 _red = _Md4();
  final _Md4 _blue = _Md4();
  Uint8List? _firstHash;
  int _chunks = 0;
  int _chunkBytes = 0;
  bool _finished = false;

  void add(List<int> bytes) {
    if (_finished) throw StateError('ED2K already finalized');
    int offset = 0;
    while (offset < bytes.length) {
      final int count =
          (bytes.length - offset).clamp(0, anidbEd2kChunkSize - _chunkBytes);
      _chunk.add(bytes, offset, count);
      offset += count;
      _chunkBytes += count;
      if (_chunkBytes == anidbEd2kChunkSize) {
        final Uint8List hash = _chunk.finish();
        _firstHash ??= hash;
        _red.add(hash, 0, hash.length);
        _blue.add(hash, 0, hash.length);
        _chunks++;
        _chunkBytes = 0;
        _chunk = _Md4();
      }
    }
  }

  (String, String?) finish() {
    if (_finished) throw StateError('ED2K already finalized');
    _finished = true;
    final Uint8List tail = _chunk.finish();
    if (_chunks == 0) return (_hex(tail), null);
    _red.add(tail, 0, tail.length);
    final String red = _hex(_red.finish());
    if (_chunkBytes != 0) return (red, null);
    return (red, _hex(_chunks == 1 ? _firstHash! : _blue.finish()));
  }
}

String _hex(List<int> bytes) =>
    bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();

/// RFC 1320 MD4 compression; used only for AniDB identity, not authentication.
class _Md4 {
  final Uint8List _buffer = Uint8List(64);
  final Uint32List _words = Uint32List(16);
  final Uint32List _state = Uint32List.fromList(
      <int>[0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476]);
  int _used = 0;
  int _length = 0;

  void add(List<int> bytes, int offset, int count) {
    _length += count;
    final int end = offset + count;
    while (offset < end) {
      if (_used == 0 && end - offset >= 64) {
        _compress(bytes, offset);
        offset += 64;
      } else {
        final int take = (end - offset).clamp(0, 64 - _used);
        _buffer.setRange(_used, _used + take, bytes, offset);
        _used += take;
        offset += take;
        if (_used == 64) {
          _compress(_buffer, 0);
          _used = 0;
        }
      }
    }
  }

  Uint8List finish() {
    final int bitLength = _length * 8;
    final Uint8List padding = Uint8List(_used < 56 ? 64 - _used : 128 - _used);
    padding[0] = 0x80;
    for (int i = 0; i < 8; i++) {
      padding[padding.length - 8 + i] = (bitLength >> (8 * i)) & 255;
    }
    add(padding, 0, padding.length);
    final ByteData output = ByteData(16);
    for (int i = 0; i < 4; i++) {
      output.setUint32(i * 4, _state[i], Endian.little);
    }
    return output.buffer.asUint8List();
  }

  static const List<List<int>> _shifts = <List<int>>[
    <int>[3, 7, 11, 19],
    <int>[3, 5, 9, 13],
    <int>[3, 9, 11, 15]
  ];
  static const List<int> _round3 = <int>[
    0,
    8,
    4,
    12,
    2,
    10,
    6,
    14,
    1,
    9,
    5,
    13,
    3,
    11,
    7,
    15
  ];

  void _compress(List<int> bytes, int offset) {
    for (int i = 0; i < 16; i++) {
      final int p = offset + i * 4;
      _words[i] = bytes[p] |
          (bytes[p + 1] << 8) |
          (bytes[p + 2] << 16) |
          (bytes[p + 3] << 24);
    }
    int a = _state[0], b = _state[1], c = _state[2], d = _state[3];
    for (int round = 0; round < 3; round++) {
      for (int i = 0; i < 16; i++) {
        final int f = switch (round) {
          0 => (b & c) | (~b & d),
          1 => (b & c) | (b & d) | (c & d),
          _ => b ^ c ^ d,
        };
        final int k = switch (round) {
          0 => i,
          1 => (i % 4) * 4 + i ~/ 4,
          _ => _round3[i],
        };
        final int value = (a +
                f +
                _words[k] +
                (round == 0
                    ? 0
                    : round == 1
                        ? 0x5a827999
                        : 0x6ed9eba1)) &
            0xffffffff;
        final int shift = _shifts[round][i % 4];
        final int next =
            ((value << shift) | (value >> (32 - shift))) & 0xffffffff;
        a = d;
        d = c;
        c = b;
        b = next;
      }
    }
    _state[0] += a;
    _state[1] += b;
    _state[2] += c;
    _state[3] += d;
  }
}

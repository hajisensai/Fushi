import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';

/// ED2K chunk size (9500 KiB); hashing itself lives in native/fushi_compute
/// (`ffc_hash_ed2k_*`, red + blue boundary variants: https://wiki.anidb.net/Ed2k-hash).
const int anidbEd2kChunkSize = 9728000;

class AnidbEd2kHash {
  const AnidbEd2kHash({
    required this.ed2k,
    required this.size,
    required this.modifiedAt,
    required this.changedAt,
    this.alternativeEd2k,
  });

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

  final StreamSubscription<dynamic> subscription = port.listen((
    dynamic message,
  ) {
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
        result.completeError(
          pendingError ?? message[0] as Object,
          pendingStack ?? StackTrace.fromString(message[1].toString()),
        );
      } else if (message == null) {
        result.completeError(
          pendingError ?? StateError('ED2K worker exited without a result'),
          pendingStack,
        );
      }
    } catch (error, stack) {
      cancel(error, stack);
    }
  });
  try {
    worker = await Isolate.spawn(
      _hashFileWorker,
      (path, port.sendPort),
      onError: port.sendPort,
      onExit: port.sendPort,
    );
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
    // Native ED2K reads straight into its own buffer (no Dart-side copy).
    final FfcEd2kHasher digest = FfcEd2kHasher.create();
    try {
      int completed = 0;
      int reported = 0;
      port.send(<int>[0, before.size]);
      final RandomAccessFile input = await file.open();
      try {
        final Uint8List buffer = digest.buffer;
        while (true) {
          if (cancelled) throw const AnidbHashCancelled();
          final int count = await input.readInto(buffer);
          if (cancelled) throw const AnidbHashCancelled();
          if (count == 0) break;
          digest.update(count);
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
      port.send(
        AnidbEd2kHash(
          ed2k: hash,
          alternativeEd2k: alternative,
          size: completed,
          modifiedAt: before.modified,
          changedAt: before.changed,
        ),
      );
    } finally {
      digest.close();
    }
  } catch (error, stack) {
    port.send(<Object>[error, stack.toString()]);
  } finally {
    cancellation.close();
  }
}

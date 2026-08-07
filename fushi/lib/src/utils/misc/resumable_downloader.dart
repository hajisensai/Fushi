import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

typedef ResumableDownloadOpen = Future<ResumableDownloadResponse> Function(
  Uri uri,
  Map<String, String> headers,
);

typedef ResumableDownloadProgress = void Function(int received, int? total);

typedef ResumableDownloadMeta = void Function(ResumableDownloadMetaInfo info);

class ResumableDownloadResponse {
  const ResumableDownloadResponse({
    required this.statusCode,
    required this.headers,
    required this.stream,
  });

  factory ResumableDownloadResponse.bytes({
    required int statusCode,
    required List<int> body,
    Map<String, String> headers = const <String, String>{},
  }) {
    return ResumableDownloadResponse(
      statusCode: statusCode,
      headers: headers,
      stream: Stream<List<int>>.value(body),
    );
  }

  final int statusCode;
  final Map<String, String> headers;
  final Stream<List<int>> stream;

  String? header(String name) {
    final String lower = name.toLowerCase();
    for (final MapEntry<String, String> entry in headers.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return null;
  }
}

@immutable
class ResumableDownloadState {
  const ResumableDownloadState({this.etag, this.lastModified});

  final String? etag;
  final String? lastModified;

  String? get ifRange {
    final String? e = etag;
    if (e != null && e.isNotEmpty) return e;
    final String? lm = lastModified;
    if (lm != null && lm.isNotEmpty) return lm;
    return null;
  }
}

@immutable
class ResumableDownloadMetaInfo {
  const ResumableDownloadMetaInfo({
    required this.etag,
    required this.lastModified,
    required this.totalBytes,
    required this.resumed,
    required this.restartedFromZero,
    required this.writeOffset,
  });

  final String? etag;
  final String? lastModified;
  final int? totalBytes;

  /// 本次接受了 Range 续传（服务器返回 206 且起点匹配）。
  final bool resumed;

  /// 本次请求了 Range 但服务器忽略（返回 200 / 416），已丢弃旧 part 从 0 全量重写。
  final bool restartedFromZero;

  /// body 实际写入的起始偏移（续传 = resumeOffset；全量重写 = 0）。
  final int writeOffset;
}

class ResumableDownloadIntegrityException implements Exception {
  const ResumableDownloadIntegrityException(this.message);
  final String message;
  @override
  String toString() => 'ResumableDownloadIntegrityException: $message';
}

class ResumableDownloader {
  ResumableDownloader({
    required this.url,
    required this.destination,
    required this.partFile,
    required this.open,
    this.expectedSize,
    this.expectedSha256,
    this.resumeState,
    this.onProgress,
    this.onMeta,
    this.bodyTimeout,
    this.firstByteTimeout,
  });

  final String url;
  final File destination;
  final File partFile;
  final ResumableDownloadOpen open;
  final int? expectedSize;
  final String? expectedSha256;
  final ResumableDownloadState? resumeState;
  final ResumableDownloadProgress? onProgress;
  final ResumableDownloadMeta? onMeta;
  final Duration? bodyTimeout;
  final Duration? firstByteTimeout;

  Future<File> download() async {
    final int resumeOffset = await _currentPartLength();
    return _run(resumeOffset: resumeOffset, restarted: false);
  }

  Future<int> _currentPartLength() async {
    if (!await partFile.exists()) return 0;
    final int length = await partFile.length();
    if (length <= 0) return 0;
    final int? size = expectedSize;
    if (size != null && length >= size) {
      await _deleteFile(partFile);
      return 0;
    }
    return length;
  }

  Future<File> _run(
      {required int resumeOffset, required bool restarted}) async {
    final Uri uri = Uri.parse(url);
    final bool requestedRange = resumeOffset > 0;
    final Map<String, String> headers = <String, String>{};
    if (requestedRange) {
      headers[HttpHeaders.rangeHeader] = 'bytes=$resumeOffset-';
      final String? ifRange = resumeState?.ifRange;
      if (ifRange != null && ifRange.isNotEmpty) {
        headers[HttpHeaders.ifRangeHeader] = ifRange;
      }
    }

    Future<ResumableDownloadResponse> opened = open(uri, headers);
    if (firstByteTimeout != null) opened = opened.timeout(firstByteTimeout!);
    final ResumableDownloadResponse response = await opened;

    int writeOffset = resumeOffset;
    var resumed = false;
    var restartedFromZero = restarted;
    if (requestedRange &&
        response.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
        !restarted) {
      await response.stream.drain<void>();
      await _deleteFile(partFile);
      return _run(resumeOffset: 0, restarted: true);
    }

    if (requestedRange && response.statusCode == HttpStatus.partialContent) {
      final int? start =
          _contentRangeStart(response.header(HttpHeaders.contentRangeHeader));
      if (start != resumeOffset) {
        await response.stream.drain<void>();
        await _deleteFile(partFile);
        if (!restarted) return _run(resumeOffset: 0, restarted: true);
        throw HttpException('invalid content-range for resume: $url');
      }
      resumed = true;
    } else if (response.statusCode == HttpStatus.ok) {
      if (requestedRange) {
        await _deleteFile(partFile);
        writeOffset = 0;
        restartedFromZero = true;
      }
    } else if (response.statusCode != HttpStatus.partialContent) {
      await response.stream.drain<void>();
      throw HttpException('download failed (${response.statusCode}): $url');
    }

    final int? total = _responseTotalSize(response, writeOffset);
    onMeta?.call(ResumableDownloadMetaInfo(
      etag: response.header(HttpHeaders.etagHeader),
      lastModified: response.header(HttpHeaders.lastModifiedHeader),
      totalBytes: expectedSize ?? total,
      resumed: resumed,
      restartedFromZero: restartedFromZero,
      writeOffset: writeOffset,
    ));

    final int? knownTotal = expectedSize ?? total;
    await _streamToPart(
      response: response,
      writeOffset: writeOffset,
      total: knownTotal,
    );

    await _validateOrThrow();
    return _promote();
  }

  Future<void> _streamToPart({
    required ResumableDownloadResponse response,
    required int writeOffset,
    required int? total,
  }) async {
    final IOSink sink = partFile.openWrite(
      mode: writeOffset > 0 ? FileMode.append : FileMode.write,
    );
    int received = writeOffset;
    onProgress?.call(received, total);
    Object? bodyError;
    StackTrace? bodyStack;
    try {
      Stream<List<int>> body = response.stream;
      if (bodyTimeout != null) body = body.timeout(bodyTimeout!);
      await for (final List<int> chunk in body) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
    } catch (e, stack) {
      bodyError = e;
      bodyStack = stack;
    }

    Object? closeError;
    StackTrace? closeStack;
    try {
      await sink.close();
    } catch (e, stack) {
      closeError = e;
      closeStack = stack;
    }

    // openWrite / 落盘错误可能只在 done 上浮（不在 close 上）；await sink.done 把它们
    // 留在被 await 的 download Future 里，而非逃逸到 UncaughtZone。
    Object? doneError;
    StackTrace? doneStack;
    try {
      await sink.done;
    } catch (e, stack) {
      doneError = e;
      doneStack = stack;
    }

    if (bodyError != null) Error.throwWithStackTrace(bodyError, bodyStack!);
    if (closeError != null) Error.throwWithStackTrace(closeError, closeStack!);
    if (doneError != null) Error.throwWithStackTrace(doneError, doneStack!);
  }

  Future<void> _validateOrThrow() async {
    if (!await partFile.exists()) {
      throw const ResumableDownloadIntegrityException('part file missing');
    }
    final int length = await partFile.length();
    if (length <= 0) {
      await _deleteFile(partFile);
      throw const ResumableDownloadIntegrityException('empty download');
    }
    final int? size = expectedSize;
    if (size != null && length != size) {
      await _deleteFile(partFile);
      throw ResumableDownloadIntegrityException(
        'size mismatch: got $length want $size',
      );
    }
    final String? digest = expectedSha256;
    if (digest != null) {
      final String actual = await _sha256OfFile(partFile);
      if (actual != digest) {
        await _deleteFile(partFile);
        throw ResumableDownloadIntegrityException(
          'sha256 mismatch for ${destination.path}',
        );
      }
    }
  }

  Future<File> _promote() async {
    await destination.parent.create(recursive: true);
    if (await destination.exists()) await _deleteFile(destination);
    return partFile.rename(destination.path);
  }

  Future<String> _sha256OfFile(File file) async {
    final Digest digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  static int? _responseTotalSize(
    ResumableDownloadResponse response,
    int writeOffset,
  ) {
    final int? contentRangeTotal =
        _contentRangeTotal(response.header(HttpHeaders.contentRangeHeader));
    if (contentRangeTotal != null) return contentRangeTotal;
    final String? lengthText = response.header(HttpHeaders.contentLengthHeader);
    final int? contentLength = _parsePositiveInt(lengthText);
    if (contentLength == null) return null;
    return response.statusCode == HttpStatus.partialContent
        ? writeOffset + contentLength
        : contentLength;
  }

  static int? _contentRangeStart(String? value) {
    final RegExpMatch? match = _contentRangeMatch(value);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  static int? _contentRangeTotal(String? value) {
    final RegExpMatch? match = _contentRangeMatch(value);
    if (match == null) return null;
    final String total = match.group(3)!;
    return total == '*' ? null : int.tryParse(total);
  }

  static RegExpMatch? _contentRangeMatch(String? value) {
    if (value == null) return null;
    return RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$').firstMatch(value.trim());
  }

  static int? _parsePositiveInt(String? value) {
    if (value == null) return null;
    final int? parsed = int.tryParse(value.trim());
    return parsed != null && parsed >= 0 ? parsed : null;
  }

  static Future<void> _deleteFile(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // best-effort
    }
  }
}

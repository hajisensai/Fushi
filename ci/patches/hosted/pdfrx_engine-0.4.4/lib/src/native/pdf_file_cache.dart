import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:pdfium_dart/pdfium_dart.dart' as pdfium_bindings;
import 'package:synchronized/extension.dart';

import '../pdf_document.dart';
import '../pdf_exception.dart';
import '../pdfrx.dart';
import '../pdfrx_entry_functions.dart';
import '../pdfrx_initialize_dart.dart';
import 'http_cache_control.dart';
import 'native_utils.dart';

final _rafFinalizer = Finalizer<RandomAccessFile>((raf) {
  // Attempt to close the file if it hasn't been closed explicitly.
  // Use try-catch as close might fail or already be closed.
  try {
    raf.close();
    // Consider adding logging here if needed for debugging finalization.
    // print('PdfFileCache: Finalizer closed RandomAccessFile.');
  } catch (_) {
    // Ignore errors during finalization.
  }
});

/// PDF file cache backed by a file.
///
/// The cache directory used by this class is obtained using [Pdfrx.cacheDirectoryPath].
///
/// For Flutter, `pdfrxFlutterInitialize` should be called explicitly or implicitly before using this class.
/// For Dart only, call [pdfrxInitialize] or explicitly set [Pdfrx.cacheDirectoryPath].
class PdfFileCache {
  PdfFileCache(this.file);

  /// Default cache block size is 1MB.
  static const defaultBlockSize = 1024 * 1024;

  /// Cache file.
  final File file;

  late Uint8List _cacheState;
  int? _cacheBlockSize;
  int? _cacheBlockCount;
  int? _fileSize;
  int? _headerSize;
  int? _cacheStatePosition;
  HttpCacheControlState _cacheControlState = HttpCacheControlState.empty;
  bool _initialized = false;
  RandomAccessFile? _raf;

  int get blockSize => _cacheBlockSize!;

  int get totalBlocks => _cacheBlockCount!;

  int get fileSize => _fileSize!;

  String get filePath => file.path;

  HttpCacheControlState get cacheControlState => _cacheControlState;

  /// Number of bytes cached.
  int get cachedBytes {
    if (!isInitialized) return 0;
    var countCached = 0;
    for (var i = 0; i < totalBlocks; i++) {
      if (isCached(i)) {
        countCached++;
      }
    }
    return min(countCached * blockSize, fileSize);
  }

  bool get isInitialized => _initialized;

  Future<void> close() async {
    final raf = _raf;
    if (raf != null) {
      _rafFinalizer.detach(this); // Detach from finalizer since we are closing explicitly
      _raf = null;
      await raf.close();
    }
  }

  Future<void> deleteCacheFile() async {
    await close();
    try {
      await file.delete();
    } catch (_) {}
  }

  Future<void> _ensureFileOpen() async {
    if (_raf == null) {
      _raf = await file.open(mode: FileMode.append);
      // Attach the file handle to the finalizer, associated with 'this' cache instance.
      _rafFinalizer.attach(this, _raf!, detach: this);
    }
  }

  Future<void> _read(List<int> buffer, int bufferPosition, int position, int size) async {
    await _ensureFileOpen();
    await _raf!.setPosition(position);
    await _raf!.readInto(buffer, bufferPosition, bufferPosition + size);
  }

  Future<void> _write(int position, List<int> bytes) async {
    await _ensureFileOpen();
    await _raf!.setPosition(position);
    await _raf!.writeFrom(bytes, 0);
  }

  Future<int> _getSize() async {
    await _ensureFileOpen();
    return await _raf!.length();
  }

  Future<void> read(List<int> buffer, int bufferPosition, int position, int size) =>
      _read(buffer, bufferPosition, _headerSize! + position, size);

  Future<void> write(int position, List<int> bytes) => _write(_headerSize! + position, bytes);

  bool isCached(int block) => _cacheState[block >> 3] & (1 << (block & 7)) != 0;

  Future<void> setCached(int startBlock, {int? lastBlock}) async {
    lastBlock ??= startBlock;
    for (var i = startBlock; i <= lastBlock; i++) {
      _cacheState[i >> 3] |= 1 << (i & 7);
    }
    await _saveCacheState();
  }

  static const header1Size = 16;
  static const headerMagic = 34567;
  static const dataStrSizeMax = 128;

  Future<void> _saveCacheState() => _write(_cacheStatePosition!, _cacheState);

  static Future<PdfFileCache> fromFile(File file) async {
    final cache = PdfFileCache(file);
    await cache._reloadFile();
    return cache;
  }

  Future<void> _reloadFile() async {
    try {
      final header = Uint8List(header1Size);
      await _read(header, 0, 0, header.length);
      final headerInt = header.buffer.asInt32List();
      if (headerInt[0] != headerMagic) {
        throw const PdfException('Invalid cache file');
      }
      _fileSize = headerInt[1];
      _cacheBlockSize = headerInt[2];
      if (_fileSize != 0) {
        _cacheBlockCount = (_fileSize! + blockSize - 1) ~/ blockSize;
      } else {
        _cacheBlockCount = 1;
      }
      final dataStrSize = headerInt[3];
      if (dataStrSize > dataStrSizeMax) {
        throw const PdfException('Invalid cache file');
      }
      _cacheStatePosition = header1Size + dataStrSizeMax;

      if (dataStrSize != 0) {
        final dataStrBytes = Uint8List(dataStrSize);
        await _read(dataStrBytes, 0, header1Size, dataStrBytes.length);
        _cacheControlState = HttpCacheControlState.parseDataStr(utf8.decode(dataStrBytes));
      } else {
        _cacheControlState = HttpCacheControlState.empty;
      }

      final data = _cacheState = Uint8List((_cacheBlockCount! + 7) >> 3);
      _headerSize = _cacheStatePosition! + data.length;
      await _read(data, 0, _cacheStatePosition!, data.length);

      if (_fileSize == 0) {
        _fileSize = await _getSize() - _headerSize!;
      }
      _initialized = true;
    } catch (_) {
      _initialized = false;
    }
  }

  Future<void> invalidateCache() async {
    await _ensureFileOpen();
    await _raf!.truncate(0);
    _fileSize = 0;
    _cacheControlState = HttpCacheControlState.empty;
    _cacheBlockCount = 0;
    _cacheState = Uint8List(0);
    _cacheStatePosition = 0;
    _headerSize = 0;
    _initialized = false;
  }

  Future<void> resetAll() async {
    await invalidateCache();
    await _reloadFile();
  }

  bool setBlockSize(int cacheBlockSize) {
    if (_cacheBlockSize != null) return false;
    _cacheBlockSize = cacheBlockSize;
    return true;
  }

  Future<void> initializeWithFileSize(int fileSize, {required bool truncateExistingContent}) async {
    if (truncateExistingContent) {
      await invalidateCache();
    }

    _cacheBlockCount = max(1, (fileSize + blockSize - 1) ~/ blockSize);
    _fileSize = fileSize;

    _cacheState = Uint8List((_cacheBlockCount! + 7) >> 3);
    _cacheStatePosition = header1Size + dataStrSizeMax;
    _headerSize = _cacheStatePosition! + _cacheState.length;

    final header = Int32List(3);
    header[0] = headerMagic;
    header[1] = fileSize;
    header[2] = blockSize;

    await _write(0, header.buffer.asUint8List());
    await _saveCacheControlState();
    await _saveCacheState();
    _initialized = true;
  }

  Future<void> _saveCacheControlState() async {
    final dataStrEncoded = utf8.encode(_cacheControlState.dataStr);
    if (dataStrEncoded.length > dataStrSizeMax) {
      throw const PdfException('HTTP headers too large');
    }
    final sizeBuf = Int32List(1);
    sizeBuf[0] = dataStrEncoded.length;
    await _write(header1Size - 4, sizeBuf.buffer.asUint8List());
    await _write(header1Size, dataStrEncoded);
  }

  Future<void> setCacheControlState(HttpCacheControlState cacheControlState) async {
    _cacheControlState = cacheControlState;
    await _saveCacheControlState();
  }

  static Future<File> getCacheFilePathForUri(Uri uri) async {
    if (Pdfrx.cacheDirectoryPath == null) {
      throw StateError('Pdfrx.cacheDirectoryPath is not set. Please initialize pdfrx or set it explicitly.');
    }
    final fnHash = sha1
        .convert(utf8.encode(uri.toString()))
        .bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final dir1 = fnHash.substring(0, 2);
    final dir2 = fnHash.substring(2, 4);
    final body = fnHash.substring(4);
    final dir = await getCacheDirectory('pdfrx.cache', dir1, dir2);
    return File(path.join(dir.path, '$body.pdf'));
  }

  static Future<PdfFileCache> fromUri(Uri uri) async {
    return await fromFile(await getCacheFilePathForUri(uri));
  }
}

class _HttpClientWrapper {
  _HttpClientWrapper(this.createHttpClient);
  final http.Client Function() createHttpClient;

  http.Client? _client;
  http.Client get client => _client ??= createHttpClient();

  void reset() {
    _client?.close();
    _client = null;
  }
}

/// Open PDF file from [uri].
///
/// On web, unlike [PdfDocument.openUri], this function uses HTTP's range request to download the file and uses [PdfFileCache].
Future<PdfDocument> pdfDocumentFromUri(
  Uri uri, {
  PdfPasswordProvider? passwordProvider,
  bool firstAttemptByEmptyPassword = true,
  bool useProgressiveLoading = false,
  int? blockSize,
  PdfFileCache? cache,
  PdfDownloadProgressCallback? progressCallback,
  bool useRangeAccess = true,
  Map<String, String>? headers,
  Duration? timeout,
  PdfrxEntryFunctions? entryFunctions,
}) async {
  entryFunctions ??= PdfrxEntryFunctions.instance;
  progressCallback?.call(0);
  cache ??= await PdfFileCache.fromUri(uri);
  final httpClientWrapper = _HttpClientWrapper(Pdfrx.createHttpClient ?? () => http.Client());

  try {
    if (!cache.isInitialized) {
      cache.setBlockSize(blockSize ?? PdfFileCache.defaultBlockSize);
      final result = await _downloadBlock(
        httpClientWrapper,
        uri,
        cache,
        progressCallback,
        0,
        useRangeAccess: useRangeAccess,
        headers: headers,
        timeout: timeout,
      );
      if (result.isFullDownload) {
        return await entryFunctions.openFile(
          cache.filePath,
          passwordProvider: passwordProvider,
          firstAttemptByEmptyPassword: firstAttemptByEmptyPassword,
          useProgressiveLoading: useProgressiveLoading,
        );
      }
    } else {
      // Check if the file is fresh (no-need-to-reload).
      if (cache.cacheControlState.cacheControl.mustRevalidate && cache.cacheControlState.isFresh(now: DateTime.now())) {
        // cache is valid; no need to download.
      } else {
        final result = await _downloadBlock(
          httpClientWrapper,
          uri,
          cache,
          progressCallback,
          0,
          addCacheControlHeaders: true,
          useRangeAccess: useRangeAccess,
          headers: headers,
          timeout: timeout,
        );
        // cached file has expired
        // if the file has fully downloaded again or has not been modified
        if (result.isFullDownload || result.notModified) {
          cache.close(); // close the cache file before opening it.
          httpClientWrapper.reset();
          return await entryFunctions.openFile(
            cache.filePath,
            passwordProvider: passwordProvider,
            firstAttemptByEmptyPassword: firstAttemptByEmptyPassword,
            useProgressiveLoading: useProgressiveLoading,
          );
        }
      }
    }

    return await entryFunctions.openCustom(
      read: (buffer, position, size) async {
        final totalSize = size;
        final end = position + size;
        var bufferPosition = 0;
        for (var p = position; p < end;) {
          final blockId = p ~/ cache!.blockSize;
          final isAvailable = cache.isCached(blockId);
          if (!isAvailable) {
            await _downloadBlock(
              httpClientWrapper,
              uri,
              cache,
              progressCallback,
              blockId,
              headers: headers,
              timeout: timeout,
            );
          }
          final readEnd = min(p + size, (blockId + 1) * cache!.blockSize);
          final sizeToRead = readEnd - p;
          await cache!.read(buffer, bufferPosition, p, sizeToRead);
          p += sizeToRead;
          bufferPosition += sizeToRead;
          size -= sizeToRead;
        }
        return totalSize;
      },
      passwordProvider: passwordProvider,
      firstAttemptByEmptyPassword: firstAttemptByEmptyPassword,
      useProgressiveLoading: useProgressiveLoading,
      fileSize: cache.fileSize,
      sourceName: uri.toString(),
      onDispose: () {
        cache!.close();
        httpClientWrapper.reset();
      },
    );
  } catch (e) {
    if (e is PdfException && e.errorCode == pdfium_bindings.FPDF_ERR_FORMAT) {
      // the file seems broken; delete the cache file.
      // NOTE: the trick does not work on Windows :(
      await cache.deleteCacheFile();
    }
    cache.close();
    httpClientWrapper.reset();
    rethrow;
  }
}

extension MapExtension<K, V> on Map<K, V> {
  void copyFrom(Map<K, V> source, Iterable<K> keys, {bool override = true}) {
    for (final key in keys) {
      if (override || !containsKey(key)) {
        this[key] = source[key] as V;
      }
    }
  }
}

class _DownloadResult {
  _DownloadResult(this.fileSize, this.isFullDownload, this.notModified);
  final int fileSize;
  final bool isFullDownload;
  final bool notModified;
}

// Download blocks of the file and cache the data to file.
Future<_DownloadResult> _downloadBlock(
  _HttpClientWrapper httpClientWrapper,
  Uri uri,
  PdfFileCache cache,
  PdfDownloadProgressCallback? progressCallback,
  int blockId, {
  int blockCount = 1,
  bool addCacheControlHeaders = false,
  bool useRangeAccess = true,
  Map<String, String>? headers,
  Duration? timeout,
}) => httpClientWrapper.synchronized(() async {
  int? fileSize;
  final blockOffset = blockId * cache.blockSize;
  final end = blockOffset + cache.blockSize * blockCount;
  final request = http.Request('GET', uri)
    ..headers.addAll({
      if (useRangeAccess) 'Range': 'bytes=$blockOffset-${end - 1}',
      if (addCacheControlHeaders) ...cache.cacheControlState.getHeadersForFetch(),
      ...?headers,
    });
  late final http.StreamedResponse response;
  try {
    response = await httpClientWrapper.client.send(request).timeout(timeout ?? const Duration(seconds: 5));
  } on TimeoutException {
    httpClientWrapper.reset();
    rethrow;
  } catch (e) {
    httpClientWrapper.reset();
    throw PdfException('Failed to download PDF file: $e');
  }
  if (response.statusCode == 304) {
    return _DownloadResult(cache.fileSize, false, true);
  }

  if (response.statusCode != 200 && response.statusCode != 206) {
    throw PdfException('Failed to download PDF file: ${response.statusCode} ${response.reasonPhrase}');
  }

  if (addCacheControlHeaders) {
    await cache.invalidateCache();
  }

  final contentRange = response.headers['content-range'];
  var isFullDownload = false;
  if (contentRange != null) {
    final m = RegExp(r'bytes (\d+)-(\d+)/(\d+)').firstMatch(contentRange);
    fileSize = int.parse(m!.group(3)!);
  } else {
    // The server does not support range request and returns the whole file.
    fileSize = response.contentLength;
    isFullDownload = true;
  }
  if (!cache.isInitialized) {
    await cache.initializeWithFileSize(fileSize ?? 0, truncateExistingContent: true);
  }
  await cache.setCacheControlState(HttpCacheControlState.fromHeaders(response.headers));

  var offset = blockOffset;
  var cachedBytesSoFar = cache.cachedBytes;
  await for (final bytes in response.stream) {
    await cache.write(offset, bytes);
    offset += bytes.length;
    cachedBytesSoFar += bytes.length;
    progressCallback?.call(cachedBytesSoFar, fileSize);
  }

  if (isFullDownload) {
    if (fileSize != null) {
      if (fileSize != cache.fileSize) {
        throw PdfException('File size mismatch after full download: expected $fileSize, got ${cache.fileSize}');
      }
    } else {
      fileSize = cachedBytesSoFar;
    }
    await cache.initializeWithFileSize(fileSize, truncateExistingContent: false);
    await cache.setCached(0, lastBlock: cache.totalBlocks - 1);
  } else {
    await cache.setCached(blockId, lastBlock: blockId + blockCount - 1);
  }

  return _DownloadResult(fileSize!, isFullDownload, false);
});

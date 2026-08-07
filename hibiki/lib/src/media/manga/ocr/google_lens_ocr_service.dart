library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/mokuro_payload.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_protocol.dart';
import 'package:fushi/src/ocr/manga_ocr_folder_job.dart';
import 'package:fushi/src/ocr/manga_ocr_pipeline.dart';
import 'package:fushi/src/ocr/manga_ocr_service.dart';

final Uri kGoogleLensEndpoint =
    Uri.parse('https://lensfrontend-pa.googleapis.com/v1/crupload');
const String _kChromiumLensApiKey = 'AIzaSyDr2UxVnv_U85AbhhY8XSHSIavUW0DC-sY';
const String _kChromiumUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/120.0.0.0 Safari/537.36';

class GoogleLensOcrException implements Exception {
  const GoogleLensOcrException(this.code, [this.detail]);

  final String code;
  final String? detail;

  @override
  String toString() =>
      detail == null ? 'GoogleLensOcrException($code)' : '$code: $detail';
}

abstract interface class GoogleLensTransport {
  Future<Uint8List> post(Uint8List body);
}

class HttpGoogleLensTransport implements GoogleLensTransport {
  HttpGoogleLensTransport({
    Uri? endpoint,
    HttpClient? client,
    this.timeout = const Duration(seconds: 60),
  })  : endpoint = endpoint ?? kGoogleLensEndpoint,
        _client = client ?? HttpClient() {
    _client.connectionTimeout = timeout;
    _client.userAgent = _kChromiumUserAgent;
    _client.maxConnectionsPerHost = 2;
  }

  final Uri endpoint;
  final Duration timeout;
  final HttpClient _client;

  @override
  Future<Uint8List> post(Uint8List body) async {
    try {
      final HttpClientRequest request =
          await _client.postUrl(endpoint).timeout(timeout);
      request.headers.contentType =
          ContentType('application', 'x-protobuf', charset: null);
      request.headers.set('X-Goog-Api-Key', _kChromiumLensApiKey);
      request.headers.set(HttpHeaders.userAgentHeader, _kChromiumUserAgent);
      request.contentLength = body.length;
      request.add(body);
      final HttpClientResponse response =
          await request.close().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        throw GoogleLensOcrException(
          'service_unavailable',
          'HTTP ${response.statusCode}',
        );
      }
      if (response.contentLength > kGoogleLensMaximumResponseBytes) {
        await response.drain<void>();
        throw const GoogleLensOcrException('invalid_response', 'too large');
      }
      final BytesBuilder result = BytesBuilder(copy: false);
      int received = 0;
      await for (final List<int> chunk in response.timeout(timeout)) {
        received += chunk.length;
        if (received > kGoogleLensMaximumResponseBytes) {
          throw const GoogleLensOcrException('invalid_response', 'too large');
        }
        result.add(chunk);
      }
      return result.takeBytes();
    } on GoogleLensOcrException {
      rethrow;
    } on TimeoutException {
      throw const GoogleLensOcrException('request_failed', 'timeout');
    } on SocketException catch (error) {
      throw GoogleLensOcrException('request_failed', error.message);
    } on HttpException catch (error) {
      throw GoogleLensOcrException('request_failed', error.message);
    }
  }

  void close() => _client.close(force: true);
}

abstract interface class GoogleLensMangaOcrRunner {
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
    int startPage,
    bool onlyMissing,
  });

  Future<void> clearCache(String imageDirPath);
}

class GoogleLensMangaOcrService implements GoogleLensMangaOcrRunner {
  GoogleLensMangaOcrService({GoogleLensTransport? transport})
      : _transport = transport ?? HttpGoogleLensTransport();

  final GoogleLensTransport _transport;

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
    int startPage = 0,
    bool onlyMissing = true,
  }) {
    late final StreamController<MangaOcrVolumeEvent> controller;
    final OcrCancelToken cancelToken = OcrCancelToken();
    controller = StreamController<MangaOcrVolumeEvent>(
      onListen: () {
        unawaited(() async {
          try {
            final String output = await _runFolder(
              imageDirPath: imageDirPath,
              startPage: startPage,
              onlyMissing: onlyMissing,
              cancelToken: cancelToken,
              onProgress: (int done, int total) {
                if (!controller.isClosed) {
                  controller.add(
                    MangaOcrVolumeEvent.page(
                      pagesDone: done,
                      pagesTotal: total,
                    ),
                  );
                }
              },
            );
            if (!controller.isClosed) {
              final int pages =
                  enumerateMangaPages(Directory(imageDirPath)).length;
              controller.add(
                MangaOcrVolumeEvent.finished(
                  pagesTotal: pages,
                  mangaJsonPath: output,
                ),
              );
              await controller.close();
            }
          } catch (error, stackTrace) {
            if (!controller.isClosed) {
              controller.addError(error, stackTrace);
              await controller.close();
            }
          }
        }());
      },
      onCancel: () {
        cancelToken.cancel();
      },
    );
    return controller.stream;
  }

  Future<String> _runFolder({
    required String imageDirPath,
    required int startPage,
    required bool onlyMissing,
    required OcrCancelToken cancelToken,
    required void Function(int done, int total) onProgress,
  }) async {
    final Directory root = Directory(imageDirPath);
    final List<MangaOcrPageFile> pages = enumerateMangaPages(root);
    if (pages.isEmpty) {
      throw const GoogleLensOcrException('no_pages');
    }
    final Directory outputDirectory =
        Directory(p.join(root.path, kMangaOcrOutDirName));
    final Directory cacheDirectory = Directory(
      p.join(
        outputDirectory.path,
        kMangaOcrPagesCacheDirName,
        kGoogleLensEngineSignature,
      ),
    );
    final GoogleLensPageCache cache = GoogleLensPageCache(cacheDirectory);
    await cache.writeManifest(pages);
    final File output =
        File(p.join(outputDirectory.path, kMangaOcrOutputFileName));
    final Map<String, MokuroImage> existing = onlyMissing
        ? await _readExistingPages(output)
        : <String, MokuroImage>{};
    final List<MokuroImage?> results =
        List<MokuroImage?>.filled(pages.length, null);
    final int normalizedStart =
        pages.isEmpty ? 0 : startPage.clamp(0, pages.length - 1);
    final List<int> order = <int>[
      for (int i = normalizedStart; i < pages.length; i++) i,
      for (int i = 0; i < normalizedStart; i++) i,
    ];
    int done = 0;
    for (final int pageIndex in order) {
      cancelToken.throwIfCancelled();
      final MangaOcrPageFile page = pages[pageIndex];
      final MokuroImage? existingPage = existing[page.relativeUrl];
      if (existingPage != null && existingPage.blocks.isNotEmpty) {
        results[pageIndex] = existingPage;
      } else {
        final MokuroImage? cached = await cache.read(pageIndex, page);
        results[pageIndex] = cached ?? await _recognizePage(page);
        if (cached == null) {
          await cache.write(pageIndex, page, results[pageIndex]!);
        }
      }
      done += 1;
      onProgress(done, pages.length);
    }
    cancelToken.throwIfCancelled();
    final MokuroPayload payload = MokuroPayload(
      images: results.cast<MokuroImage>(),
      ocr: const MangaOcrMetadata(
        engine: 'google_lens',
        engineSignature: kGoogleLensEngineSignature,
        schemaVersion: 1,
      ),
    );
    await outputDirectory.create(recursive: true);
    await _writeJsonAtomically(output, mangaPayloadToJson(payload));
    return output.path;
  }

  Future<MokuroImage> _recognizePage(MangaOcrPageFile page) async {
    final Uint8List source = await page.file.readAsBytes();
    return recognizePageBytes(
      source,
      relativeUrl: page.relativeUrl,
    );
  }

  /// Recognize a single already-fetched page.
  ///
  /// Online Mihon chapters use this entry point so page download, Lens upload
  /// and per-page cache publication remain one serial current-page-first job.
  /// Image decoding/resizing stays off the Flutter UI isolate, matching
  /// Niratan's detached preparation task.
  Future<MokuroImage> recognizePageBytes(
    Uint8List source, {
    required String relativeUrl,
  }) async {
    final GoogleLensPreparedImage prepared =
        await Isolate.run<GoogleLensPreparedImage>(
      () => GoogleLensProtocol.prepareImage(source),
    );
    final Uint8List request = GoogleLensProtocol.makeRequest(
      imageData: prepared.data,
      width: prepared.width,
      height: prepared.height,
    );
    final Uint8List response = await _transport.post(request);
    final List<GoogleLensParagraph> paragraphs;
    try {
      // 归一化坐标与 rotation 都是相对**送检图**的，宽高比必须取 prepared 尺寸。
      paragraphs = GoogleLensProtocol.decodeResponse(
        response,
        imageWidth: prepared.width,
        imageHeight: prepared.height,
      );
    } on GoogleLensProtocolException catch (error) {
      throw GoogleLensOcrException('invalid_response', error.message);
    }
    final double width = prepared.originalWidth.toDouble();
    final double height = prepared.originalHeight.toDouble();
    final List<MokuroBlock> blocks = <MokuroBlock>[];
    for (int index = 0; index < paragraphs.length; index++) {
      final GoogleLensParagraph paragraph = paragraphs[index];
      final Rect blockRect = _toPixels(
        paragraph.normalizedBounds,
        width,
        height,
      );
      final int characterCount = math.max(1, paragraph.sentence.length);
      blocks.add(
        MokuroBlock(
          rectangle: blockRect,
          isVertical: paragraph.isVertical,
          fontSize:
              math.sqrt(blockRect.width * blockRect.height / characterCount),
          zIndex: index,
          lines: <String>[paragraph.sentence],
          regions: <MangaOcrTextRegion>[
            for (final GoogleLensTextRegion region in paragraph.regions)
              MangaOcrTextRegion(
                rectangle: _toPixels(region.normalizedBounds, width, height),
                utf16Start: region.utf16Start,
                utf16End: region.utf16End,
              ),
          ],
        ),
      );
    }
    return MokuroImage(
      url: relativeUrl,
      size: Size(width, height),
      blocks: blocks,
    );
  }

  @override
  Future<void> clearCache(String imageDirPath) async {
    final String path = p.join(
      imageDirPath,
      kMangaOcrOutDirName,
      kMangaOcrPagesCacheDirName,
      kGoogleLensEngineSignature,
    );
    final Directory directory = Directory(path);
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  }

  static Rect _toPixels(Rect normalized, double width, double height) =>
      Rect.fromLTRB(
        normalized.left * width,
        normalized.top * height,
        normalized.right * width,
        normalized.bottom * height,
      );
}

class GoogleLensPageCache {
  GoogleLensPageCache(this.directory);

  final Directory directory;
  final Map<String, MokuroImage> _memory = <String, MokuroImage>{};
  final List<String> _memoryOrder = <String>[];

  Future<void> writeManifest(List<MangaOcrPageFile> pages) async {
    await directory.create(recursive: true);
    final Map<String, Object?> manifest = <String, Object?>{
      'schema_version': 1,
      'engine_signature': kGoogleLensEngineSignature,
      'pages': <Map<String, Object?>>[
        for (final MangaOcrPageFile page in pages) _fingerprint(page),
      ],
    };
    await _writeJsonAtomically(
      File(p.join(directory.path, 'manifest.json')),
      manifest,
    );
  }

  Future<MokuroImage?> read(
    int pageIndex,
    MangaOcrPageFile page,
  ) async {
    final String memoryKey = jsonEncode(_fingerprint(page));
    final MokuroImage? memory = _memory[memoryKey];
    if (memory != null) {
      _touch(memoryKey);
      return memory;
    }
    final File file = _pageFile(pageIndex);
    if (!file.existsSync()) {
      return null;
    }
    try {
      if (await file.length() > kGoogleLensMaximumCachedPageBytes) {
        return null;
      }
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        return null;
      }
      if (!_sameFingerprint(decoded['fingerprint'], _fingerprint(page))) {
        return null;
      }
      final Object? rawPage = decoded['page'];
      if (rawPage is! Map) {
        return null;
      }
      final MokuroPayload parsed = parseMangaJson(
        jsonEncode(<String, Object?>{
          'pages': <Object?>[rawPage],
        }),
      );
      if (parsed.images.length != 1) {
        return null;
      }
      final int geometryVersion = switch (decoded['geometry_version']) {
        final num value => value.round(),
        _ => 1,
      };
      final MokuroImage result = geometryVersion >= 2
          ? parsed.images.single
          : _migrateLegacyCachedLensPage(parsed.images.single);
      _remember(memoryKey, result);
      return result;
    } catch (_) {
      return null;
    }
  }

  Future<void> write(
    int pageIndex,
    MangaOcrPageFile page,
    MokuroImage result,
  ) async {
    await directory.create(recursive: true);
    final Map<String, Object?> pageJson = (mangaPayloadToJson(
                MokuroPayload(images: <MokuroImage>[result]))['pages']
            as List<Object?>)
        .single as Map<String, Object?>;
    final Map<String, Object?> encoded = <String, Object?>{
      'fingerprint': _fingerprint(page),
      'geometry_version': 3,
      'page': pageJson,
    };
    _remember(jsonEncode(_fingerprint(page)), result);
    final String json = jsonEncode(encoded);
    if (utf8.encode(json).length > kGoogleLensMaximumCachedPageBytes) {
      throw const GoogleLensOcrException('invalid_response', 'cache too large');
    }
    await _writeTextAtomically(_pageFile(pageIndex), json);
  }

  File _pageFile(int pageIndex) => File(
      p.join(directory.path, '${pageIndex.toString().padLeft(6, '0')}.json'));

  static Map<String, Object?> _fingerprint(MangaOcrPageFile page) {
    final FileStat stat = page.file.statSync();
    return <String, Object?>{
      'path': page.relativeUrl,
      'size': stat.size,
      'modified_ms': stat.modified.millisecondsSinceEpoch,
    };
  }

  static bool _sameFingerprint(
    Object? raw,
    Map<String, Object?> expected,
  ) {
    if (raw is! Map) {
      return false;
    }
    return raw['path'] == expected['path'] &&
        raw['size'] == expected['size'] &&
        raw['modified_ms'] == expected['modified_ms'];
  }

  void _remember(String key, MokuroImage value) {
    _memory[key] = value;
    _touch(key);
    while (_memoryOrder.length > 24) {
      _memory.remove(_memoryOrder.removeAt(0));
    }
  }

  void _touch(String key) {
    _memoryOrder.remove(key);
    _memoryOrder.add(key);
  }
}

MokuroImage _migrateLegacyCachedLensPage(MokuroImage page) {
  final double pageHeight = page.size.height;
  final List<MokuroBlock> blocks = <MokuroBlock>[
    for (final MokuroBlock block in page.blocks)
      _normalizeCachedLensBlock(MokuroBlock(
        rectangle: _flipLegacyLensRect(block.rectangle, pageHeight),
        isVertical: block.isVertical,
        fontSize: block.fontSize,
        zIndex: block.zIndex,
        lines: block.lines,
        linesCoords: block.linesCoords,
        regions: block.regions
            ?.map((MangaOcrTextRegion region) => MangaOcrTextRegion(
                  rectangle: _flipLegacyLensRect(
                    region.rectangle,
                    pageHeight,
                  ),
                  utf16Start: region.utf16Start,
                  utf16End: region.utf16End,
                ))
            .toList(),
      )),
  ];
  return MokuroImage(url: page.url, size: page.size, blocks: blocks);
}

Rect _flipLegacyLensRect(Rect rect, double pageHeight) => Rect.fromLTRB(
      rect.left,
      pageHeight - rect.bottom,
      rect.right,
      pageHeight - rect.top,
    );

MokuroBlock _normalizeCachedLensBlock(MokuroBlock block) {
  final List<MangaOcrTextRegion>? regions = block.regions;
  final String original = block.lines.join();
  if (regions == null || regions.length < 2 || original.isEmpty) {
    return block;
  }
  final List<_CachedLensPiece> pieces = <_CachedLensPiece>[];
  for (final MangaOcrTextRegion region in regions) {
    final int start = region.utf16Start.clamp(0, original.length);
    final int end = region.utf16End.clamp(start, original.length);
    if (end <= start) continue;
    pieces.add(_CachedLensPiece(
      text: original.substring(start, end),
      rectangle: region.rectangle,
    ));
  }
  if (pieces.length < 2) return block;

  final List<List<_CachedLensPiece>> groups =
      _groupCachedLensPieces(pieces, vertical: block.isVertical);
  final List<_CachedLensPiece> ordered = <_CachedLensPiece>[
    for (final List<_CachedLensPiece> group in groups) ...group,
  ];
  final StringBuffer sentence = StringBuffer();
  final List<MangaOcrTextRegion> normalizedRegions = <MangaOcrTextRegion>[];
  int offset = 0;
  for (final _CachedLensPiece piece in ordered) {
    final int end = offset + piece.text.length;
    sentence.write(piece.text);
    normalizedRegions.add(MangaOcrTextRegion(
      rectangle: piece.rectangle,
      utf16Start: offset,
      utf16End: end,
    ));
    offset = end;
  }
  return MokuroBlock(
    rectangle: block.rectangle,
    isVertical: block.isVertical,
    fontSize: block.fontSize,
    zIndex: block.zIndex,
    lines: <String>[sentence.toString()],
    linesCoords: block.linesCoords,
    regions: normalizedRegions,
  );
}

List<List<_CachedLensPiece>> _groupCachedLensPieces(
  List<_CachedLensPiece> pieces, {
  required bool vertical,
}) {
  final List<_CachedLensPiece> remaining = List<_CachedLensPiece>.of(pieces)
    ..sort(vertical
        ? (_CachedLensPiece a, _CachedLensPiece b) =>
            b.rectangle.center.dx.compareTo(a.rectangle.center.dx)
        : (_CachedLensPiece a, _CachedLensPiece b) =>
            a.rectangle.center.dy.compareTo(b.rectangle.center.dy));
  final List<List<_CachedLensPiece>> groups = <List<_CachedLensPiece>>[];
  for (final _CachedLensPiece piece in remaining) {
    List<_CachedLensPiece>? match;
    for (final List<_CachedLensPiece> group in groups) {
      final Rect anchor = group.first.rectangle;
      final bool overlaps = vertical
          ? _axisOverlap(anchor.left, anchor.right, piece.rectangle.left,
                  piece.rectangle.right) >
              math.min(anchor.width, piece.rectangle.width) * 0.35
          : _axisOverlap(anchor.top, anchor.bottom, piece.rectangle.top,
                  piece.rectangle.bottom) >
              math.min(anchor.height, piece.rectangle.height) * 0.35;
      if (overlaps) {
        match = group;
        break;
      }
    }
    (match ?? (groups..add(<_CachedLensPiece>[])).last).add(piece);
  }
  groups.sort(vertical
      ? (List<_CachedLensPiece> a, List<_CachedLensPiece> b) =>
          b.first.rectangle.center.dx.compareTo(a.first.rectangle.center.dx)
      : (List<_CachedLensPiece> a, List<_CachedLensPiece> b) =>
          a.first.rectangle.center.dy.compareTo(b.first.rectangle.center.dy));
  for (final List<_CachedLensPiece> group in groups) {
    group.sort(vertical
        ? (_CachedLensPiece a, _CachedLensPiece b) =>
            a.rectangle.center.dy.compareTo(b.rectangle.center.dy)
        : (_CachedLensPiece a, _CachedLensPiece b) =>
            a.rectangle.center.dx.compareTo(b.rectangle.center.dx));
  }
  return groups;
}

double _axisOverlap(double a0, double a1, double b0, double b1) =>
    math.max(0, math.min(a1, b1) - math.max(a0, b0));

class _CachedLensPiece {
  const _CachedLensPiece({required this.text, required this.rectangle});

  final String text;
  final Rect rectangle;
}

Future<Map<String, MokuroImage>> _readExistingPages(File output) async {
  if (!output.existsSync()) {
    return <String, MokuroImage>{};
  }
  try {
    final MokuroPayload payload = parseMangaJson(await output.readAsString());
    return <String, MokuroImage>{
      for (final MokuroImage image in payload.images) image.url: image,
    };
  } catch (_) {
    return <String, MokuroImage>{};
  }
}

Future<void> _writeJsonAtomically(
  File target,
  Map<String, Object?> value,
) =>
    _writeTextAtomically(target, jsonEncode(value));

Future<void> _writeTextAtomically(File target, String value) async {
  await target.parent.create(recursive: true);
  final File temporary = File('${target.path}.tmp');
  await temporary.writeAsString(value, flush: true);
  if (target.existsSync()) {
    await target.delete();
  }
  await temporary.rename(target.path);
}

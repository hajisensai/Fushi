import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/manga/manga_ocr_background_job.dart';
import 'package:hibiki/src/media/manga/mihon/manga_page_provider.dart';
import 'package:hibiki/src/media/manga/mokuro_payload.dart';
import 'package:hibiki/src/media/manga/ocr/google_lens_ocr_service.dart';
import 'package:hibiki/src/media/manga/ocr/google_lens_protocol.dart';
import 'package:hibiki/src/ocr/manga_ocr_folder_job.dart';

const int kMihonOnlineOcrMemoryPages = 24;

/// Current-page-first online Google Lens job.
///
/// It mirrors Niratan's scheduling contract: pages are processed serially,
/// beginning at the visible page and wrapping to the start; image acquisition
/// is retried up to three times with 350/700 ms backoff; every completed page
/// is published and cached atomically before the next page begins.
class MihonOnlineMangaOcr {
  MihonOnlineMangaOcr({
    required this.session,
    required this.managedDirectory,
    required this.initialPayload,
    required this.startPage,
    GoogleLensMangaOcrService? lens,
  }) : _lens = lens ?? GoogleLensMangaOcrService();

  final MangaReaderSession session;
  final Directory managedDirectory;
  final MokuroPayload initialPayload;
  final int startPage;
  final GoogleLensMangaOcrService _lens;
  static final _MihonOnlineOcrMemoryCache _memoryCache =
      _MihonOnlineOcrMemoryCache(kMihonOnlineOcrMemoryPages);
  static final Map<String, Future<MokuroImage>> _pendingPages =
      <String, Future<MokuroImage>>{};

  Stream<MangaOcrBackgroundEvent> run() {
    late final StreamController<MangaOcrBackgroundEvent> controller;
    bool cancelled = false;
    controller = StreamController<MangaOcrBackgroundEvent>(
      onListen: () {
        unawaited(() async {
          try {
            await _run(
              isCancelled: () => cancelled || controller.isClosed,
              emit: (MangaOcrBackgroundEvent event) {
                if (!controller.isClosed) controller.add(event);
              },
            );
            if (!controller.isClosed) await controller.close();
          } on _MihonOnlineOcrCancelled {
            if (!controller.isClosed) await controller.close();
          } on Object catch (error, stack) {
            if (!controller.isClosed) {
              controller.addError(error, stack);
              await controller.close();
            }
          }
        }());
      },
      onCancel: () {
        cancelled = true;
      },
    );
    return controller.stream;
  }

  Future<void> _run({
    required bool Function() isCancelled,
    required void Function(MangaOcrBackgroundEvent event) emit,
  }) async {
    final int total = session.pageCount;
    if (total <= 0 || initialPayload.images.length != total) {
      throw const GoogleLensOcrException('no_pages');
    }
    final int normalizedStart = startPage.clamp(0, total - 1);
    final List<int> order = <int>[
      for (int index = normalizedStart; index < total; index++) index,
      for (int index = 0; index < normalizedStart; index++) index,
    ];
    final Directory imagesDirectory = Directory(
      p.join(managedDirectory.path, 'images'),
    );
    await imagesDirectory.create(recursive: true);
    final _OnlinePageIdentityManifest identities =
        await _OnlinePageIdentityManifest.open(
      File(p.join(imagesDirectory.path, '.mihon-pages.json')),
      <String>[
        for (int index = 0; index < total; index++)
          session.cacheIdentity(index),
      ],
    );
    final GoogleLensPageCache cache = GoogleLensPageCache(
      Directory(
        p.join(
          imagesDirectory.path,
          kMangaOcrOutDirName,
          kMangaOcrPagesCacheDirName,
          kGoogleLensEngineSignature,
        ),
      ),
    );
    final List<MokuroImage> results =
        List<MokuroImage>.of(initialPayload.images);
    int done = 0;
    int succeeded = 0;
    int failed = 0;

    for (final int pageIndex in order) {
      if (isCancelled()) throw const _MihonOnlineOcrCancelled();
      final MokuroImage previous = results[pageIndex];
      final String relativeUrl = previous.url;
      try {
        final String identity = session.cacheIdentity(pageIndex);
        final String memoryKey = <String>[
          p.canonicalize(managedDirectory.path),
          identity,
        ].join('\u001f');
        final MokuroImage recognized = await _recognizePageSingleflight(
          key: memoryKey,
          pageIndex: pageIndex,
          relativeUrl: relativeUrl,
          imagesDirectory: imagesDirectory,
          identities: identities,
          cache: cache,
          isCancelled: isCancelled,
        );
        results[pageIndex] = recognized;
        succeeded += 1;
      } on _MihonOnlineOcrCancelled {
        rethrow;
      } on Object {
        // Match Niratan: a failed page remains pending while the scan proceeds
        // and successfully cached pages stay immediately usable.
        failed += 1;
      }
      done += 1;
      emit(
        MangaOcrBackgroundEvent.progress(
          pagesDone: done,
          pagesTotal: total,
          pagesSucceeded: succeeded,
          pagesFailed: failed,
          pageIndex: pageIndex,
          page: results[pageIndex],
        ),
      );
    }
    if (isCancelled()) throw const _MihonOnlineOcrCancelled();
    if (succeeded == 0) {
      throw GoogleLensOcrException(
        'no_ocr_pages',
        'all $failed online manga pages failed',
      );
    }

    final MokuroPayload payload = MokuroPayload(
      images: results,
      ocr: const MangaOcrMetadata(
        engine: 'google_lens',
        engineSignature: kGoogleLensEngineSignature,
        schemaVersion: 1,
      ),
    );
    final File output = File(
      p.join(
        imagesDirectory.path,
        kMangaOcrOutDirName,
        kMangaOcrOutputFileName,
      ),
    );
    await _writeTextAtomically(
      output,
      jsonEncode(mangaPayloadToJson(payload)),
    );
    emit(
      MangaOcrBackgroundEvent.finished(
        pagesTotal: total,
        pagesSucceeded: succeeded,
        pagesFailed: failed,
        resultPath: output.path,
        external: false,
      ),
    );
  }

  Future<MokuroImage> _recognizePageSingleflight({
    required String key,
    required int pageIndex,
    required String relativeUrl,
    required Directory imagesDirectory,
    required _OnlinePageIdentityManifest identities,
    required GoogleLensPageCache cache,
    required bool Function() isCancelled,
  }) {
    final Future<MokuroImage>? current = _pendingPages[key];
    if (current != null) return current;
    final Future<MokuroImage> future = _recognizePage(
      key: key,
      pageIndex: pageIndex,
      relativeUrl: relativeUrl,
      imagesDirectory: imagesDirectory,
      identities: identities,
      cache: cache,
      isCancelled: isCancelled,
    );
    _pendingPages[key] = future;
    unawaited(
      future.then<void>(
        (_) {
          if (identical(_pendingPages[key], future)) {
            _pendingPages.remove(key);
          }
        },
        onError: (Object _, StackTrace __) {
          if (identical(_pendingPages[key], future)) {
            _pendingPages.remove(key);
          }
        },
      ),
    );
    return future;
  }

  Future<MokuroImage> _recognizePage({
    required String key,
    required int pageIndex,
    required String relativeUrl,
    required Directory imagesDirectory,
    required _OnlinePageIdentityManifest identities,
    required GoogleLensPageCache cache,
    required bool Function() isCancelled,
  }) async {
    final File file = await _materializePage(
      pageIndex: pageIndex,
      relativeUrl: relativeUrl,
      imagesDirectory: imagesDirectory,
      identities: identities,
      isCancelled: isCancelled,
    );
    final MangaOcrPageFile source = MangaOcrPageFile(
      file: file,
      relativeUrl: relativeUrl,
    );
    final MokuroImage? memoryCached = _memoryCache.get(key);
    final MokuroImage? cached =
        memoryCached ?? await cache.read(pageIndex, source);
    final MokuroImage recognized = cached ??
        await _lens.recognizePageBytes(
          await file.readAsBytes(),
          relativeUrl: relativeUrl,
        );
    if (cached == null) {
      await cache.write(pageIndex, source, recognized);
    }
    _memoryCache.put(key, recognized);
    return recognized;
  }

  Future<File> _materializePage({
    required int pageIndex,
    required String relativeUrl,
    required Directory imagesDirectory,
    required _OnlinePageIdentityManifest identities,
    required bool Function() isCancelled,
  }) async {
    final String root = p.canonicalize(imagesDirectory.path);
    final String targetPath = p.canonicalize(
      p.join(imagesDirectory.path, relativeUrl),
    );
    if (!p.isWithin(root, targetPath)) {
      throw const GoogleLensOcrException(
        'image_unavailable',
        'online page escaped the managed image directory',
      );
    }
    final File target = File(targetPath);
    if (identities.matches(pageIndex) &&
        await target.exists() &&
        await target.length() > 0) {
      return target;
    }

    Object? lastError;
    for (int attempt = 0; attempt < 3; attempt++) {
      if (isCancelled()) throw const _MihonOnlineOcrCancelled();
      try {
        final File? source = await session.localFile(pageIndex);
        if (source == null) {
          throw const GoogleLensOcrException('image_unavailable');
        }
        await target.parent.create(recursive: true);
        final File temporary = _uniqueTemporarySibling(target);
        try {
          await source.copy(temporary.path);
          await _withFilePromotionLock(target, () async {
            await _promoteTemporary(temporary, target);
            await identities.record(pageIndex);
          });
        } finally {
          if (await temporary.exists()) await temporary.delete();
        }
        return target;
      } on Object catch (error) {
        lastError = error;
        if (attempt >= 2) rethrow;
        await Future<void>.delayed(
          Duration(milliseconds: 350 * (attempt + 1)),
        );
      }
    }
    throw GoogleLensOcrException(
      'image_unavailable',
      lastError?.toString(),
    );
  }
}

class _MihonOnlineOcrMemoryCache {
  _MihonOnlineOcrMemoryCache(this.maximumPages);

  final int maximumPages;
  final Map<String, MokuroImage> _pages = <String, MokuroImage>{};

  MokuroImage? get(String key) {
    final MokuroImage? page = _pages.remove(key);
    if (page != null) _pages[key] = page;
    return page;
  }

  void put(String key, MokuroImage page) {
    _pages.remove(key);
    _pages[key] = page;
    while (_pages.length > maximumPages) {
      _pages.remove(_pages.keys.first);
    }
  }
}

class _OnlinePageIdentityManifest {
  _OnlinePageIdentityManifest({
    required this.file,
    required this.expected,
    required this.persisted,
  });

  final File file;
  final List<String> expected;
  final List<String?> persisted;

  static Future<_OnlinePageIdentityManifest> open(
    File file,
    List<String> expected,
  ) async {
    List<String?> persisted = List<String?>.filled(expected.length, null);
    try {
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is Map && decoded['pages'] is List) {
        final List<Object?> pages = (decoded['pages'] as List).cast<Object?>();
        persisted = <String?>[
          for (int index = 0; index < expected.length; index++)
            index < pages.length ? pages[index]?.toString() : null,
        ];
      }
    } on Object {
      // Missing or malformed manifests only invalidate materialized pages.
    }
    return _OnlinePageIdentityManifest(
      file: file,
      expected: expected,
      persisted: persisted,
    );
  }

  bool matches(int index) =>
      index >= 0 &&
      index < expected.length &&
      index < persisted.length &&
      persisted[index] == expected[index];

  Future<void> record(int index) async {
    persisted[index] = expected[index];
    await _writeTextAtomically(
      file,
      jsonEncode(<String, Object?>{
        'schema_version': 1,
        'pages': persisted,
      }),
    );
  }
}

class _MihonOnlineOcrCancelled implements Exception {
  const _MihonOnlineOcrCancelled();
}

int _temporarySequence = 0;
final Map<String, Future<void>> _filePromotionTails = <String, Future<void>>{};

File _uniqueTemporarySibling(File target) => File(
      '${target.path}.tmp-${DateTime.now().microsecondsSinceEpoch}-'
      '${_temporarySequence++}',
    );

Future<T> _withFilePromotionLock<T>(
  File target,
  Future<T> Function() action,
) async {
  final String key = p.canonicalize(target.path);
  final Future<void> previous =
      _filePromotionTails[key] ?? Future<void>.value();
  final Completer<void> release = Completer<void>();
  final Future<void> tail = release.future;
  _filePromotionTails[key] = tail;
  await previous;
  try {
    return await action();
  } finally {
    release.complete();
    if (identical(_filePromotionTails[key], tail)) {
      _filePromotionTails.remove(key);
    }
  }
}

Future<void> _promoteTemporary(File temporary, File target) async {
  final File previous = _uniqueTemporarySibling(
    File('${target.path}.previous'),
  );
  final bool hadTarget = await target.exists();
  if (hadTarget) await target.rename(previous.path);
  try {
    await temporary.rename(target.path);
  } on Object {
    if (await target.exists()) await target.delete();
    if (await previous.exists()) await previous.rename(target.path);
    rethrow;
  }
  if (await previous.exists()) await previous.delete();
}

Future<void> _writeTextAtomically(File target, String value) async {
  await target.parent.create(recursive: true);
  final File temporary = _uniqueTemporarySibling(target);
  try {
    await temporary.writeAsString(value, flush: true);
    await _withFilePromotionLock(target, () async {
      await _promoteTemporary(temporary, target);
    });
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}

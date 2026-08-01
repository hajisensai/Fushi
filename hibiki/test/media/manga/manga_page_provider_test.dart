import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/manga/mihon/manga_page_provider.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_manager.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_models.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_runtime.dart';
import 'package:image/image.dart' as img;

void main() {
  test('local reader session serves managed pages and blocks traversal',
      () async {
    final Directory root =
        await Directory.systemTemp.createTemp('hibiki-local-manga-reader-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final Directory images =
        Directory('${root.path}${Platform.pathSeparator}images');
    await images.create();
    await File('${images.path}${Platform.pathSeparator}page.png').writeAsBytes(
      <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
    );
    await File('${root.path}${Platform.pathSeparator}secret.jpg').writeAsBytes(
      <int>[0xff, 0xd8, 0xff],
    );

    final MangaReaderSession session = await LocalMangaPageProvider(
      imagesRoot: images,
      relativePaths: const <String>['page.png', '../secret.jpg'],
    ).open();
    expect(session.pageCount, 2);
    expect((await session.page(0)).contentType, 'image/png');
    expect((await session.localFile(0))?.path, endsWith('page.png'));
    await expectLater(
      session.page(1),
      throwsA(
        isA<MihonRuntimeException>().having(
          (MihonRuntimeException error) => error.code,
          'code',
          'PATH_TRAVERSAL',
        ),
      ),
    );

    await session.close();
    await expectLater(
      session.page(0),
      throwsA(
        isA<MihonRuntimeException>().having(
          (MihonRuntimeException error) => error.code,
          'code',
          'SESSION_CLOSED',
        ),
      ),
    );
  });

  test('online reader uses memory LRU and preserves the disk cache', () async {
    final Directory root =
        await Directory.systemTemp.createTemp('hibiki-mihon-reader-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final _ImageRuntime runtime = _ImageRuntime();
    final MihonMangaPageProvider provider = MihonMangaPageProvider(
      runtime: runtime,
      context: const MihonSourceContext(
        extension: MihonExtensionRef(
          packageName: 'org.example.fixture',
          apkPath: 'fixture.ext',
        ),
        source: MihonSource(
          extensionPackage: 'org.example.fixture',
          id: '9007199254740993',
          name: 'Fixture',
          language: 'en',
          baseUrl: 'https://source.example',
        ),
        preferences: <MihonPreference>[],
      ),
      pages: const <MihonPage>[
        MihonPage(index: 0, url: 'page-0'),
        MihonPage(index: 1, url: 'page-1'),
      ],
      cacheRoot: root,
      maxMemoryCacheBytes: 5,
    );

    final MangaReaderSession session = await provider.open();
    final Directory cacheDirectory =
        (session as MihonMangaReaderSession).directory;
    expect((await session.page(0)).contentType, 'image/jpeg');
    expect(await session.localFile(0), isNotNull);
    await session.page(1);
    expect(runtime.fetchCount, 2);

    await session.page(1);
    expect(runtime.fetchCount, 2, reason: 'the newest page remains cached');
    await session.page(0);
    expect(
      runtime.fetchCount,
      2,
      reason: 'a memory eviction falls back to the persistent disk cache',
    );

    await session.close();
    expect(await cacheDirectory.exists(), isTrue);
    expect(
      () => session.page(0),
      throwsA(
        isA<MihonRuntimeException>().having(
          (MihonRuntimeException e) => e.code,
          'code',
          'SESSION_CLOSED',
        ),
      ),
    );

    final MangaReaderSession reopened = await provider.open();
    await reopened.page(0);
    expect(runtime.fetchCount, 2, reason: 'the disk cache survives sessions');
    await reopened.close();
  });

  test('closing a chapter cancels unfinished runtime image requests', () async {
    final Directory root =
        await Directory.systemTemp.createTemp('hibiki-mihon-cancel-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final _CancellableImageRuntime runtime = _CancellableImageRuntime();
    final MangaReaderSession session = await MihonMangaPageProvider(
      runtime: runtime,
      context: _fixtureContext,
      pages: const <MihonPage>[MihonPage(index: 0, url: 'page-0')],
      cacheRoot: root,
    ).open();

    final Future<MangaPageBytes> pending = session.page(0);
    await runtime.started.future;
    final Future<void> cancellation = expectLater(
      pending,
      throwsA(isA<MihonRuntimeException>()),
    );
    await session.close();

    expect(runtime.cancelledIds, hasLength(1));
    await cancellation;
  });

  test('decodes the real landscape and portrait page dimensions', () async {
    final ({int width, int height})? landscape = await mangaImageDimensions(
      Uint8List.fromList(
        img.encodePng(img.Image(width: 1200, height: 700)),
      ),
    );
    final ({int width, int height})? portrait = await mangaImageDimensions(
      Uint8List.fromList(
        img.encodePng(img.Image(width: 720, height: 1280)),
      ),
    );

    expect(landscape, (width: 1200, height: 700));
    expect(portrait, (width: 720, height: 1280));
  });

  test('online image requests never exceed four concurrent fetches', () async {
    final Directory root =
        await Directory.systemTemp.createTemp('hibiki-mihon-concurrency-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final _ConcurrentImageRuntime runtime = _ConcurrentImageRuntime();
    final MangaReaderSession session = await MihonMangaPageProvider(
      runtime: runtime,
      context: _fixtureContext,
      pages: <MihonPage>[
        for (int index = 0; index < 8; index++)
          MihonPage(index: index, url: 'page-$index'),
      ],
      cacheRoot: root,
    ).open();

    await Future.wait<MangaPageBytes>(
      <Future<MangaPageBytes>>[
        for (int index = 0; index < 8; index++) session.page(index),
      ],
    );

    expect(runtime.maximumActive, 4);
    await session.close();
  });

  test('cache identities are stable for Unicode source URLs', () async {
    final Directory root =
        await Directory.systemTemp.createTemp('hibiki-mihon-unicode-cache-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final MangaReaderSession session = await MihonMangaPageProvider(
      runtime: _ImageRuntime(),
      context: const MihonSourceContext(
        extension: MihonExtensionRef(
          packageName: 'org.example.unicode',
          apkPath: 'unicode.ext',
        ),
        source: MihonSource(
          extensionPackage: 'org.example.unicode',
          id: '日本語-source',
          name: '日本語',
          language: 'ja',
          baseUrl: 'https://例え.test',
        ),
        preferences: <MihonPreference>[],
      ),
      pages: const <MihonPage>[
        MihonPage(
          index: 0,
          url: '/漫画/第一話',
          imageUrl: 'https://例え.test/画像/一.jpg',
        ),
      ],
      cacheRoot: root,
    ).open();

    final String identity = session.cacheIdentity(0);
    expect(identity, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(identity, session.cacheIdentity(0));
    expect(
      identity,
      mihonPageCacheIdentity(
        const MihonSourceContext(
          extension: MihonExtensionRef(
            packageName: 'org.example.unicode',
            apkPath: 'unicode.ext',
          ),
          source: MihonSource(
            extensionPackage: 'org.example.unicode',
            id: '日本語-source',
            name: '日本語',
            language: 'ja',
            baseUrl: 'https://例え.test',
          ),
          preferences: <MihonPreference>[],
        ),
        const MihonPage(
          index: 0,
          url: '/漫画/第一話',
          imageUrl: 'https://例え.test/画像/一.jpg',
        ),
      ),
    );
    await session.close();
  });
}

const MihonSourceContext _fixtureContext = MihonSourceContext(
  extension: MihonExtensionRef(
    packageName: 'org.example.fixture',
    apkPath: 'fixture.ext',
  ),
  source: MihonSource(
    extensionPackage: 'org.example.fixture',
    id: '9007199254740993',
    name: 'Fixture',
    language: 'en',
    baseUrl: 'https://source.example',
  ),
  preferences: <MihonPreference>[],
);

class _ImageRuntime extends Fake implements MihonRuntime {
  int fetchCount = 0;

  @override
  Future<Uint8List> fetchImage(
    MihonExtensionRef extension,
    MihonSource source,
    MihonPage page, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    fetchCount += 1;
    return Uint8List.fromList(<int>[0xff, 0xd8, 0xff, page.index]);
  }
}

class _CancellableImageRuntime extends Fake
    implements MihonRuntime, CancellableMihonRuntime {
  final Completer<void> started = Completer<void>();
  final Map<String, Completer<Uint8List>> requests =
      <String, Completer<Uint8List>>{};
  final List<String> cancelledIds = <String>[];

  @override
  Future<Uint8List> fetchImageRequest(
    MihonExtensionRef extension,
    MihonSource source,
    MihonPage page, {
    required String requestId,
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) {
    final Completer<Uint8List> request = Completer<Uint8List>();
    requests[requestId] = request;
    if (!started.isCompleted) started.complete();
    return request.future;
  }

  @override
  Future<void> cancelImageRequests(Iterable<String> requestIds) async {
    for (final String requestId in requestIds) {
      cancelledIds.add(requestId);
      requests.remove(requestId)?.completeError(
            const MihonRuntimeException(
              'REQUEST_CANCELLED',
              'Fixture request cancelled',
            ),
          );
    }
  }
}

class _ConcurrentImageRuntime extends Fake implements MihonRuntime {
  int active = 0;
  int maximumActive = 0;

  @override
  Future<Uint8List> fetchImage(
    MihonExtensionRef extension,
    MihonSource source,
    MihonPage page, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    active += 1;
    if (active > maximumActive) maximumActive = active;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    active -= 1;
    return Uint8List.fromList(<int>[0xff, 0xd8, 0xff, page.index]);
  }
}

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/manga/manga_ocr_background_job.dart';
import 'package:hibiki/src/media/manga/mihon/manga_page_provider.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_manager.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_models.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_online_ocr.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_runtime.dart';
import 'package:hibiki/src/media/manga/mokuro_payload.dart';
import 'package:hibiki/src/media/manga/ocr/google_lens_ocr_service.dart';
import 'package:image/image.dart' as img;

import 'ocr/google_lens_fixture.dart';

void main() {
  test('online OCR keeps the Niratan-sized 24-page memory cache', () {
    expect(kMihonOnlineOcrMemoryPages, 24);
  });

  test('online OCR starts at the visible page, retries images and reuses cache',
      () async {
    final Directory root =
        await Directory.systemTemp.createTemp('hibiki-mihon-online-ocr-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final _OnlineImageRuntime runtime = _OnlineImageRuntime(
      Uint8List.fromList(
        img.encodePng(img.Image(width: 1200, height: 1700)),
      ),
    );
    final MihonMangaPageProvider provider = MihonMangaPageProvider(
      runtime: runtime,
      context: _context,
      pages: const <MihonPage>[
        MihonPage(index: 0, url: 'page-0'),
        MihonPage(index: 1, url: 'page-1'),
        MihonPage(index: 2, url: 'page-2'),
      ],
      cacheRoot: Directory('${root.path}${Platform.pathSeparator}page-cache'),
    );
    final Directory managed =
        Directory('${root.path}${Platform.pathSeparator}managed');
    final MokuroPayload initial = MokuroPayload(
      images: <MokuroImage>[
        for (int index = 0; index < 3; index++)
          MokuroImage(
            url: 'page-${(index + 1).toString().padLeft(6, '0')}.jpg',
            size: const Size(1000, 1400),
            blocks: const <MokuroBlock>[],
          ),
      ],
    );
    final _LensTransport transport = _LensTransport();
    final MangaReaderSession firstSession = await provider.open();
    final List<MangaOcrBackgroundEvent> firstEvents = await MihonOnlineMangaOcr(
      session: firstSession,
      managedDirectory: managed,
      initialPayload: initial,
      startPage: 1,
      lens: GoogleLensMangaOcrService(transport: transport),
    ).run().toList();

    expect(
      firstEvents
          .where((MangaOcrBackgroundEvent event) => !event.finished)
          .map((MangaOcrBackgroundEvent event) => event.pageIndex),
      <int?>[1, 2, 0],
    );
    expect(firstEvents.last.finished, isTrue);
    expect(transport.requests, 3);
    expect(runtime.attempts[2], 3, reason: 'page fetch retries are 350/700 ms');
    expect(runtime.fetchCount, 5);
    expect(firstEvents[0].page?.size, const Size(1200, 1700));
    await firstSession.close();

    final MangaReaderSession reopened = await provider.open();
    final List<MangaOcrBackgroundEvent> cachedEvents =
        await MihonOnlineMangaOcr(
      session: reopened,
      managedDirectory: managed,
      initialPayload: initial,
      startPage: 2,
      lens: GoogleLensMangaOcrService(transport: transport),
    ).run().toList();

    expect(
      cachedEvents
          .where((MangaOcrBackgroundEvent event) => !event.finished)
          .map((MangaOcrBackgroundEvent event) => event.pageIndex),
      <int?>[2, 0, 1],
    );
    expect(
      transport.requests,
      3,
      reason: 'per-page OCR JSON is reused without another Lens upload',
    );
    expect(
      runtime.fetchCount,
      5,
      reason: 'materialized page identities and disk page cache survive reopen',
    );
    await reopened.close();
  });
}

const MihonSourceContext _context = MihonSourceContext(
  extension: MihonExtensionRef(
    packageName: 'org.example.fixture',
    apkPath: 'fixture.ext',
  ),
  source: MihonSource(
    extensionPackage: 'org.example.fixture',
    id: '9007199254740993',
    name: 'Fixture',
    language: 'ja',
    baseUrl: 'https://source.example',
  ),
  preferences: <MihonPreference>[],
);

class _OnlineImageRuntime extends Fake implements MihonRuntime {
  _OnlineImageRuntime(this.bytes);

  final Uint8List bytes;
  int fetchCount = 0;
  final Map<int, int> attempts = <int, int>{};

  @override
  Future<Uint8List> fetchImage(
    MihonExtensionRef extension,
    MihonSource source,
    MihonPage page, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    fetchCount += 1;
    final int attempt = (attempts[page.index] ?? 0) + 1;
    attempts[page.index] = attempt;
    if (page.index == 2 && attempt < 3) {
      throw const MihonRuntimeException(
        'FIXTURE_RETRY',
        'retry this fixture page',
      );
    }
    return bytes;
  }
}

class _LensTransport implements GoogleLensTransport {
  int requests = 0;

  @override
  Future<Uint8List> post(Uint8List body) async {
    requests += 1;
    return makeGoogleLensFixture();
  }
}

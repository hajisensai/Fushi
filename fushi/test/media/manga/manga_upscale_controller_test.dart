import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi/src/media/manga/reader/manga_upscale_controller.dart';
import 'package:fushi_asr_core/asr_core.dart' show DownloadableModelFile;
import 'package:fushi_compute/fushi_compute.dart';
import 'package:path/path.dart' as p;

/// 低清页 AI 超分的 Dart 侧纯逻辑：偏好、值不值得做的阈值、缓存键 / 标签、模型清单、页图 URL。
void main() {
  test('aiUpscale preference defaults off and only accepts known tiers', () {
    expect(const MangaReaderPreferences().aiUpscale, 'off');
    expect(
      MangaReaderPreferences.fromJson(<String, Object?>{
        'aiUpscale': 'high',
      }).aiUpscale,
      'high',
    );
    expect(
      MangaReaderPreferences.fromJson(<String, Object?>{
        'aiUpscale': 'ultra',
      }).aiUpscale,
      'off',
    );
    expect(MangaUpscaleTier.fromPreference('off').engineTier, isNull);
    expect(
      MangaUpscaleTier.fromPreference('light').engineTier,
      FfcUpscaleTier.light,
    );
    expect(
      MangaUpscaleTier.fromPreference('high').engineTier,
      FfcUpscaleTier.high,
    );
  });

  test('pages already sharp enough for the display are skipped', () {
    expect(mangaUpscaleWanted(fitWidth: 1000, sourceWidth: 1000), isFalse);
    expect(mangaUpscaleWanted(fitWidth: 1099, sourceWidth: 1000), isFalse);
    expect(mangaUpscaleWanted(fitWidth: 1100, sourceWidth: 1000), isTrue);
    expect(mangaUpscaleWanted(fitWidth: 2000, sourceWidth: 0), isFalse);
  });

  test('tag and key change with tier, text boxes and model version', () {
    final Float32List none = Float32List(0);
    final Float32List boxes = Float32List.fromList(<double>[
      0.1,
      0.1,
      0.3,
      0.4,
    ]);
    final String light = mangaUpscaleTag(FfcUpscaleTier.light, none);
    final String high = mangaUpscaleTag(FfcUpscaleTier.high, none);
    final String lightBoxes = mangaUpscaleTag(FfcUpscaleTier.light, boxes);
    expect(<String>{light, high, lightBoxes}, hasLength(3));
    expect(light, 'l0');
    final String key = mangaUpscaleKey('abcd1234|001.jpg', lightBoxes);
    expect(key, startsWith('$kMangaUpscaleModelsVersion|'));
    expect(key, contains('abcd1234|001.jpg'));
    expect(key, isNot(mangaUpscaleKey('abcd1234|002.jpg', lightBoxes)));
  });

  test('model manifest pins release URLs, sizes and sha256', () {
    final (MangaUpscaleModelFile? lightIn, MangaUpscaleModelFile lightOut) =
        mangaUpscaleModelsFor(FfcUpscaleTier.light);
    expect(lightIn, isNull);
    expect(lightOut.fileName, 'ArtCNN_C4F32.onnx');
    final (MangaUpscaleModelFile? highIn, MangaUpscaleModelFile highOut) =
        mangaUpscaleModelsFor(FfcUpscaleTier.high);
    expect(highIn!.fileName, 'swin_unet_art_scale2x.onnx');
    expect(highOut.fileName, 'swin_unet_art_noise1_scale2x.onnx');
    for (final MangaUpscaleModelFile f in <MangaUpscaleModelFile>[
      lightOut,
      highIn,
      highOut,
    ]) {
      expect(
        f.url,
        'https://github.com/hajisensai/Fushi/releases/download/'
        'upscale-models-v1/${f.fileName}',
      );
      expect(f.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(f.expectedBytes, greaterThan(100000));
    }
  });

  test('page image URL carries the upscale tag only when given', () {
    final String plain = MangaFushiPage.mangaImageUrl(
      'images/001.jpg',
      version: 3,
      scope: 'abcd',
    );
    expect(plain, isNot(contains('$kMangaUpscaleQueryParam=')));
    final String sr = MangaFushiPage.mangaImageUrl(
      'images/001.jpg',
      version: 3,
      scope: 'abcd',
      upscaleTag: 'h2-1f',
    );
    expect(Uri.parse(sr).queryParameters[kMangaUpscaleQueryParam], 'h2-1f');
    expect(Uri.parse(sr).queryParameters['v'], '3');
  });

  group('model download verifies size and sha256', () {
    late HttpServer server;
    late Directory dir;
    final List<int> body = List<int>.generate(4096, (int i) => i % 251);
    setUp(() async {
      dir = Directory.systemTemp.createTempSync('manga_upscale_models_');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) async {
        request.response.contentLength = body.length;
        request.response.add(body);
        await request.response.close();
      });
    });
    tearDown(() async {
      await server.close(force: true);
      dir.deleteSync(recursive: true);
    });

    List<String> local(DownloadableModelFile f) => <String>[
      'http://127.0.0.1:${server.port}/${f.fileName}',
    ];

    test('matching sha256 keeps the file', () async {
      final MangaUpscaleModelFile file = MangaUpscaleModelFile(
        fileName: 'm.onnx',
        expectedBytes: body.length,
        sha256: ffcSha256Bytes(body),
      );
      await downloadMangaUpscaleModels(dir, <MangaUpscaleModelFile>[
        file,
      ], urlCandidates: local).timeout(const Duration(seconds: 30));
      expect(File(p.join(dir.path, 'm.onnx')).lengthSync(), body.length);
    });

    test('mismatching sha256 deletes the file and throws', () async {
      final MangaUpscaleModelFile file = MangaUpscaleModelFile(
        fileName: 'm.onnx',
        expectedBytes: body.length,
        sha256: '0' * 64,
      );
      await expectLater(
        downloadMangaUpscaleModels(dir, <MangaUpscaleModelFile>[
          file,
        ], urlCandidates: local).timeout(const Duration(seconds: 30)),
        throwsStateError,
      );
      expect(File(p.join(dir.path, 'm.onnx')).existsSync(), isFalse);
    });
  });

  test(
    'ensureModels completes after the download and shares one in flight',
    () async {
      final Directory dir = Directory.systemTemp.createTempSync(
        'manga_upscale_ensure_',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      const MangaUpscaleModelFile file = MangaUpscaleModelFile(
        fileName: 'm.onnx',
        expectedBytes: 3,
        sha256: '',
      );
      int downloads = 0;
      int notices = 0;
      final MangaUpscaleService service = MangaUpscaleService.forTesting(
        download: (Directory d, List<MangaUpscaleModelFile> files) async {
          downloads++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          File(
            p.join(d.path, files.single.fileName),
          ).writeAsBytesSync(<int>[1, 2, 3]);
        },
      );
      // 回归：曾经 whenComplete 的回调返回被 await 的 Future 本身，下完也永远不返回。
      await Future.wait(<Future<void>>[
        service.ensureModels(dir, <MangaUpscaleModelFile>[
          file,
        ], onDownload: () => notices++),
        service.ensureModels(dir, <MangaUpscaleModelFile>[
          file,
        ], onDownload: () => notices++),
      ]).timeout(const Duration(seconds: 5));
      expect(downloads, 1);
      expect(notices, 2);
      // 已就绪：不再下载、不再提示。
      await service
          .ensureModels(dir, <MangaUpscaleModelFile>[
            file,
          ], onDownload: () => notices++)
          .timeout(const Duration(seconds: 5));
      expect(downloads, 1);
      expect(notices, 2);
    },
  );
}

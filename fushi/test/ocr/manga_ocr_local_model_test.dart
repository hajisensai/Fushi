import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_model_manifest.dart';
import 'package:path/path.dart' as p;

void main() {
  test('all model caches include the shared pipeline revision', () {
    final List<String> signatures = <String>[
      for (final MangaOcrLocalModel model in MangaOcrLocalModel.values)
        model.cacheSignature,
    ];
    expect(signatures.toSet(), hasLength(MangaOcrLocalModel.values.length));
    for (final String signature in signatures) {
      expect(signature, endsWith('-$kMangaOcrPipelineRevision'));
    }
    expect(
      MangaOcrLocalModel.baberu.cacheSignature,
      isNot('local-onnx-baberu-v1-bicubic'),
    );
  });

  test('Windows supports Baberu and unknown values retain the default', () {
    expect(
      MangaOcrLocalModel.forPlatform('baberu', operatingSystem: 'windows'),
      MangaOcrLocalModel.baberu,
    );
    expect(
      MangaOcrLocalModel.forPlatform('unknown', operatingSystem: 'windows'),
      MangaOcrLocalModel.mangaOcr,
    );
  });

  test('removed manga_ocr_cuda preference falls back to classic manga-ocr', () {
    // 2026-10 删除了 Windows 本地 Python + torch CUDA 档；旧偏好 / 备份 / 互联
    // 对端可能还带着这个 key，必须落回默认模型而不是选到不存在的引擎。
    expect(
      MangaOcrLocalModel.values.map((MangaOcrLocalModel m) => m.key),
      isNot(contains('manga_ocr_cuda')),
    );
    expect(
      MangaOcrLocalModel.fromKey('manga_ocr_cuda'),
      MangaOcrLocalModel.mangaOcr,
    );
    expect(
      MangaOcrLocalModel.forPlatform(
        'manga_ocr_cuda',
        operatingSystem: 'windows',
      ),
      MangaOcrLocalModel.mangaOcr,
    );
  });

  test(
    'leftover manga-cuda directory is deleted, live models untouched',
    () async {
      final Directory root = Directory.systemTemp.createTempSync(
        'ocr-removed-models',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final Directory cuda = Directory(p.join(root.path, 'manga-cuda'));
      Directory(p.join(cuda.path, 'python', 'Lib')).createSync(recursive: true);
      File(p.join(cuda.path, 'torch.whl')).writeAsBytesSync(<int>[1, 2, 3]);
      final List<Directory> live = <Directory>[
        for (final String name in <String>[
          'manga',
          'manga-ctc',
          'manga-baberu',
        ])
          Directory(p.join(root.path, name))..createSync(),
      ];

      expect(await deleteRemovedMangaOcrModelDirs(ocrModelsRoot: root), 1);
      expect(cuda.existsSync(), isFalse);
      for (final Directory dir in live) {
        expect(dir.existsSync(), isTrue, reason: dir.path);
      }
      // 幂等：再调一次什么都不删。
      expect(await deleteRemovedMangaOcrModelDirs(ocrModelsRoot: root), 0);
    },
  );

  test('removed directory names never collide with a live model', () async {
    final EnginePaths previous = enginePaths;
    final Directory root = Directory(
      p.join(Directory.systemTemp.path, 'ocr-removed-models-collision'),
    );
    enginePaths = FixedEnginePaths(documents: root, support: root, temp: root);
    addTearDown(() => enginePaths = previous);
    for (final MangaOcrLocalModel model in MangaOcrLocalModel.values) {
      expect(
        kRemovedMangaOcrModelDirNames,
        isNot(contains(p.basename((await model.modelsDirectory()).path))),
        reason: model.key,
      );
    }
  });

  group('per-column CTC (manga_ctc)', () {
    test('selectable on every platform, own directory and signature', () async {
      final EnginePaths previous = enginePaths;
      final Directory root = Directory(
        p.join(Directory.systemTemp.path, 'ocr-model-resolution-ctc'),
      );
      enginePaths = FixedEnginePaths(
        documents: root,
        support: root,
        temp: root,
      );
      addTearDown(() => enginePaths = previous);

      for (final String os in <String>[
        'windows',
        'android',
        'ios',
        'macos',
        'linux',
      ]) {
        expect(
          MangaOcrLocalModel.forPlatform('manga_ctc', operatingSystem: os),
          MangaOcrLocalModel.mangaCtc,
          reason: os,
        );
      }
      const MangaOcrLocalModel ctc = MangaOcrLocalModel.mangaCtc;
      expect(ctc.availableOnAllPlatforms, isTrue);
      expect(MangaOcrLocalModel.baberu.availableOnAllPlatforms, isFalse);
      expect(ctc.accelerator, isEmpty);
      expect(
        (await ctc.modelsDirectory()).path,
        p.join(root.path, 'ocr_models', 'manga-ctc'),
      );
    });

    test(
      'manifest: detector + PP det + dictionary + manga rec, no manga-ocr',
      () {
        final List<String> files = <String>[
          for (final MangaOcrModelFile file
              in MangaOcrLocalModel.mangaCtc.manifest)
            file.fileName,
        ];
        expect(files, <String>[
          'detector-v4-s_int8.onnx',
          kPpOcrDetFileName,
          kPpOcrRecDictFileName,
          kMangaCtcRecFileName,
        ]);
        final MangaOcrModelFile rec = MangaOcrLocalModel.mangaCtc.manifest.last;
        expect(rec.url, contains('/resolve/$kMangaCtcRecRevision/'));
        expect(rec.expectedBytes, 21167540);
        final int total = MangaOcrLocalModel.mangaCtc.manifest.fold<int>(
          0,
          (int sum, MangaOcrModelFile file) => sum + file.expectedBytes,
        );
        expect(total, lessThan(50 * 1024 * 1024));
      },
    );

    test('README credits the manga rec and its training data', () {
      // Manga109-s 的条款要求明确标注用到了它；AnimeText 是 CC BY-NC-SA 4.0，
      // 许可风险要让读者看得见（模型从作者的 HF 仓库直接下载，本仓不转发）。
      final String readme = File('../README.md').readAsStringSync();
      expect(readme, contains('Kellenok/PP-OCRv6_manga'));
      expect(readme, contains('AnimeText'));
      expect(readme, contains('CC BY-NC-SA 4.0'));
      expect(readme, contains('Manga109-s'));
    });

    test('cache signature can never adopt manga-ocr v4 caches as its own', () {
      final String signature =
          '${MangaOcrLocalModel.mangaCtc.cacheSignature}-36f475259340';
      expect(signature, isNot(startsWith(kLocalMangaOcrEngineSignature)));
      expect(relayoutableMangaOcrEngineSignatures(signature), isEmpty);
    });
  });

  for (final String os in <String>['android', 'ios', 'macos', 'linux']) {
    test(
      '$os restored Baberu preference imports into the classic model',
      () async {
        final EnginePaths previous = enginePaths;
        final Directory root = Directory(
          p.join(Directory.systemTemp.path, 'ocr-model-resolution'),
        );
        enginePaths = FixedEnginePaths(
          documents: root,
          support: root,
          temp: root,
        );
        addTearDown(() => enginePaths = previous);

        final MangaOcrLocalModel model = MangaOcrLocalModel.forPlatform(
          'baberu',
          operatingSystem: os,
        );
        expect(model, MangaOcrLocalModel.mangaOcr);
        expect(
          MangaOcrLocalModel.forPlatform('manga_ocr_cuda', operatingSystem: os),
          MangaOcrLocalModel.mangaOcr,
        );
        expect(model.manifest, same(kMangaOcrModelManifest));
        expect(
          (await model.modelsDirectory()).path,
          p.join(root.path, 'ocr_models', 'manga'),
        );
        expect(
          model.manifest.any(
            (MangaOcrModelFile file) => file.fileName == 'encoder_model.onnx',
          ),
          isTrue,
        );
        expect(
          model.manifest.any(
            (MangaOcrModelFile file) => file.fileName == 'vision_fp16.onnx',
          ),
          isFalse,
        );
      },
    );
  }
}

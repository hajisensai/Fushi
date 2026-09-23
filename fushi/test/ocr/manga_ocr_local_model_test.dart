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

  test(
    'Windows supports both models and unknown values retain the default',
    () {
      expect(
        MangaOcrLocalModel.forPlatform(
          'manga_ocr_cuda',
          operatingSystem: 'windows',
        ),
        MangaOcrLocalModel.mangaOcrCuda,
      );
      expect(
        MangaOcrLocalModel.forPlatform('baberu', operatingSystem: 'windows'),
        MangaOcrLocalModel.baberu,
      );
      expect(
        MangaOcrLocalModel.forPlatform('unknown', operatingSystem: 'windows'),
        MangaOcrLocalModel.mangaOcr,
      );
    },
  );

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

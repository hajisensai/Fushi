import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_model_manifest.dart';

void main() {
  group('local model manifests', () {
    for (final MangaOcrLocalModel model in MangaOcrLocalModel.values) {
      test('${model.key}: 落盘名唯一、字节数为正、带检测器', () {
        final List<MangaOcrModelFile> manifest = model.manifest;
        final Set<String> names = <String>{
          for (final MangaOcrModelFile m in manifest) m.fileName,
        };
        expect(names, hasLength(manifest.length));
        for (final MangaOcrModelFile m in manifest) {
          expect(m.expectedBytes, greaterThan(0), reason: m.fileName);
        }
        expect(
          manifest.where(
            (MangaOcrModelFile m) => m.role == MangaOcrModelRole.detector,
          ),
          hasLength(1),
        );
      });
    }

    test('已删除的 manga-ocr / Baberu 文件不在任何本地模型清单里', () {
      for (final MangaOcrLocalModel model in MangaOcrLocalModel.values) {
        final Set<String> names = <String>{
          for (final MangaOcrModelFile m in model.manifest) m.fileName,
        };
        for (final String removed in <String>[
          'encoder_model.onnx',
          'decoder_model.onnx',
          'vocab.txt',
          'cross_kv.onnx',
          'decoder_kv.onnx',
          // 2026-10 删除的 Baberu。
          'vision_fp16.onnx',
          'decoder_prefill_int8.onnx',
          'decoder_step_int8.onnx',
          'vocab.json',
        ]) {
          expect(names, isNot(contains(removed)), reason: model.key);
        }
      }
    });
  });

  group('CTC 清单里的 PP-OCRv6 文件', () {
    // 2026-10 删除 Baberu 时一并删了只有它引用的 kPpOcrLineModelManifest；
    // PP-OCRv6 det / 字典仍由逐列 CTC 清单下载，revision 钉死的约束照旧。
    final List<MangaOcrModelFile> pp = <MangaOcrModelFile>[
      for (final MangaOcrModelFile m in kMangaCtcOcrModelManifest)
        if (m.fileName == kPpOcrDetFileName ||
            m.fileName == kPpOcrRecDictFileName)
          m,
    ];

    test('PP-OCRv6 文件钉 HF revision sha，不用可变的 main', () {
      expect(pp, hasLength(2));
      for (final MangaOcrModelFile m in pp) {
        expect(m.url, isNot(contains('/resolve/main/')), reason: m.url);
        expect(
          RegExp(r'/resolve/[0-9a-f]{40}/').hasMatch(m.url),
          isTrue,
          reason: m.url,
        );
        expect(m.role, MangaOcrModelRole.recognizer);
      }
    });

    test('镜像候选只换 host，revision 路径原样保留', () {
      final MangaOcrModelFile det = pp.firstWhere(
        (MangaOcrModelFile m) => m.fileName == kPpOcrDetFileName,
      );
      final List<String> urls = mangaOcrModelUrlCandidates(det);
      expect(urls.first, det.url);
      for (final String u in urls) {
        expect(u, contains('/resolve/$kPpOcrDetRevision/inference.onnx'));
      }
    });
  });
}

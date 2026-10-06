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

    test('已删除的 manga-ocr 文件不在任何本地模型清单里', () {
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
        ]) {
          expect(names, isNot(contains(removed)), reason: model.key);
        }
      }
    });
  });

  group('kPpOcrLineModelManifest', () {
    test('PP-OCRv6 三文件钉 HF revision sha，不用可变的 main', () {
      const List<MangaOcrModelFile> pp = kPpOcrLineModelManifest;
      expect(pp, hasLength(3));
      for (final MangaOcrModelFile m in pp) {
        expect(m.url, isNot(contains('/resolve/main/')), reason: m.url);
        expect(
          RegExp(r'/resolve/[0-9a-f]{40}/').hasMatch(m.url),
          isTrue,
          reason: m.url,
        );
        expect(m.role, MangaOcrModelRole.recognizer);
      }
      expect(
        pp.map((MangaOcrModelFile m) => m.fileName),
        containsAll(<String>[
          kPpOcrDetFileName,
          kPpOcrRecFileName,
          kPpOcrRecDictFileName,
        ]),
      );
    });

    test('镜像候选只换 host，revision 路径原样保留', () {
      final MangaOcrModelFile det = kPpOcrLineModelManifest.firstWhere(
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

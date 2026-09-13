import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ocr/manga_ocr_model_manifest.dart';

void main() {
  group('kMangaOcrModelManifest', () {
    test('七个文件、落盘名唯一、字节数为正', () {
      expect(kMangaOcrModelManifest, hasLength(7));
      final Set<String> names = <String>{
        for (final MangaOcrModelFile m in kMangaOcrModelManifest) m.fileName,
      };
      expect(names, hasLength(7));
      for (final MangaOcrModelFile m in kMangaOcrModelManifest) {
        expect(m.expectedBytes, greaterThan(0), reason: m.fileName);
      }
    });

    test('PP-OCRv6 三文件钉 HF revision sha，不用可变的 main', () {
      final List<MangaOcrModelFile> pp = <MangaOcrModelFile>[
        for (final MangaOcrModelFile m in kMangaOcrModelManifest)
          if (m.fileName.startsWith('ppocrv6_')) m,
      ];
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
      final MangaOcrModelFile det = kMangaOcrModelManifest.firstWhere(
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

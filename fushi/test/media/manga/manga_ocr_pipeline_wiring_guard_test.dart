// 漫画 OCR 管线三处接线的源码守卫。
//
// 这三处的行为各有单元测试（探测并行 / 短路、后台解析、原子写 helper），但
// 「调用方有没有接上」只落在一两行里，撤掉以后那些测试都不会红：
//   · 四个排任务的入口把显式偏好 / 本次点名的引擎传给探测（只探一个）；
//     向导与 ctl 路由要列全部选项，不得传。
//   · 整卷收尾在注册表里解析几 MB 的产物，走后台 isolate。
//   · fushi 侧两处落盘走共用的原子写 helper，不各自手写「先删再改名」。
import 'dart:io';

import 'package:test/test.dart';

String _source(String path) => File(path).readAsStringSync();

void main() {
  test('显式偏好 / 本次点名的四个入口只探一个引擎', () {
    const List<String> shortCircuitCallers = <String>[
      'lib/src/media/manga/download/manga_download_auto_ocr.dart',
      'lib/src/media/manga/library/manga_book_ocr.dart',
      'lib/src/media/manga/reader/manga_reader_auto_ocr.dart',
      'lib/src/media/manga/reader/manga_reader_stream_ocr.dart',
    ];
    final RegExp probeWithTarget = RegExp(
      r'probeMangaOcrEngines\(\s*engines,\s*only: mangaOcrProbeTargetFor\(',
    );
    for (final String path in shortCircuitCallers) {
      final String source = _source(path);
      expect(
        'probeMangaOcrEngines('.allMatches(source),
        hasLength(1),
        reason: '$path 应只有一处探测',
      );
      expect(
        probeWithTarget.hasMatch(source),
        isTrue,
        reason: '$path 的探测必须带 only: mangaOcrProbeTargetFor(...)',
      );
    }
  });

  test('向导与 ctl 路由要完整能力表，探测不带 only', () {
    const List<String> fullProbeCallers = <String>[
      'lib/src/media/manga/manga_ocr_wizard_dialog.dart',
      'lib/src/ops/ctl_manga_ocr_routes.dart',
    ];
    for (final String path in fullProbeCallers) {
      final String source = _source(path);
      expect(source, contains('probeMangaOcrEngines('), reason: path);
      expect(source, isNot(contains('mangaOcrProbeTargetFor(')), reason: path);
      expect(
        RegExp(r'probeMangaOcrEngines\([^;]*\bonly:').hasMatch(source),
        isFalse,
        reason: '$path 不得只探一个引擎',
      );
    }
  });

  test('注册表整卷收尾的解析走后台 isolate', () {
    final String registry = _source(
      'lib/src/media/manga/ocr/manga_ocr_job_registry.dart',
    );
    expect(registry, contains('await parseMangaJsonOffUi(source)'));
    expect(registry, contains('await parseMokuroOffUi(source)'));
    expect(
      RegExp(r'\bparse(MangaJson|Mokuro)\(').hasMatch(registry),
      isFalse,
      reason: '整卷产物几 MB，不得在 UI isolate 上同步解析',
    );
  });

  test('fushi 侧的逐页缓存与整卷中间产物走共用原子写 helper', () {
    const List<String> writers = <String>[
      'lib/src/media/manga/ocr/google_lens_ocr_service.dart',
      'lib/src/media/manga/manga_ocr_job_stream.dart',
    ];
    for (final String path in writers) {
      final String source = _source(path);
      expect(source, contains('writeTextFileAtomically('), reason: path);
      expect(source, isNot(contains('.rename(')), reason: path);
      expect(source, isNot(contains(".tmp'")), reason: path);
    }
  });

  // Windows 上读者把缓存文件打开着的那一刻，写者的 rename 会「拒绝访问」
  // （BUG-4801）；与原子写配套的读 helper 和替换互斥。行为测试在引擎包的
  // atomic_text_file_concurrent_test.dart，这里只钉 Lens 逐页缓存接上了它。
  test('Lens 逐页缓存的读走与原子写配套的读 helper', () {
    final String source = _source(
      'lib/src/media/manga/ocr/google_lens_ocr_service.dart',
    );
    final int readStart = source.indexOf('Future<MokuroImage?> read(');
    final int readEnd = source.indexOf('Future<void> write(', readStart);
    expect(readStart, greaterThanOrEqualTo(0));
    expect(readEnd, greaterThan(readStart));
    final String readBody = source.substring(readStart, readEnd);
    expect(readBody, contains('readAtomicallyWrittenTextFile(file)'));
    expect(readBody, isNot(contains('.readAsString(')));
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/manga_ocr_job_stream.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';

/// 只当占位：本测试不跑任何识别（事件流由 buildEvents 注入）。
class _NoopOcrService implements MangaOcrService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 反馈 iuv4-jWC8S：暂停 = 真停执行器，继续必须重建一个同目录的新任务。
/// 重建口由唯一装配点 [mangaOcrBackgroundJob] 给出，这里钉住它的语义。
void main() {
  test('mangaOcrBackgroundJob 带显示名；继续重建的任务只补缺页、换新改道通道', () {
    final List<MangaOcrJobSpec> built = <MangaOcrJobSpec>[];
    final MangaOcrPageFocus focus = MangaOcrPageFocus();
    final MangaOcrJobSpec spec = MangaOcrJobSpec(
      engine: MangaOcrEngineId.googleLens,
      engines: MangaOcrWizardEngines(service: _NoopOcrService()),
      imageDirPath: '/m/book/ch1',
      lensLanguage: 'ja',
      startPage: 3,
      onlyMissing: false,
      volumeTitle: 'Book Ch 1',
      focus: focus,
    );

    final MangaOcrBackgroundJob job = mangaOcrBackgroundJob(
      bookKey: 'book',
      spec: spec,
      buildEvents: (MangaOcrJobSpec s) {
        built.add(s);
        return const Stream<MangaOcrBackgroundEvent>.empty();
      },
    );
    expect(job.bookKey, 'book');
    expect(job.managedDirectory, '/m/book/ch1');
    expect(job.engine, MangaOcrEngineId.googleLens);
    expect(job.title, 'Book Ch 1');
    expect(job.focus, same(focus));
    expect(job.resume, isNotNull);
    expect(built.single.onlyMissing, isFalse);

    final MangaOcrBackgroundJob resumed = job.resume!();
    expect(built, hasLength(2));
    final MangaOcrJobSpec again = built.last;
    expect(again.onlyMissing, isTrue, reason: '重新识别开跑时已丢过旧缓存，续跑必须复用本轮已识别的页');
    expect(again.imageDirPath, spec.imageDirPath);
    expect(again.engine, spec.engine);
    expect(again.lensLanguage, spec.lensLanguage);
    expect(again.startPage, spec.startPage);
    expect(again.focus, isNotNull);
    expect(again.focus, isNot(same(focus)), reason: '旧通道随旧任务结束');
    expect(resumed.focus, same(again.focus));
    expect(resumed.managedDirectory, job.managedDirectory);
    expect(resumed.title, job.title);
    expect(resumed.resume, isNotNull, reason: '继续后的任务还能再暂停');
  });

  test('原任务不带改道通道时，重建的也不带', () {
    final MangaOcrJobSpec spec = MangaOcrJobSpec(
      engine: MangaOcrEngineId.externalMokuro,
      engines: MangaOcrWizardEngines(service: _NoopOcrService()),
      imageDirPath: '/m/book/vol',
      lensLanguage: 'ja',
    );
    final MangaOcrBackgroundJob job = mangaOcrBackgroundJob(
      bookKey: 'book',
      spec: spec,
      buildEvents: (_) => const Stream<MangaOcrBackgroundEvent>.empty(),
    );
    expect(job.resume!().focus, isNull);
  });
}

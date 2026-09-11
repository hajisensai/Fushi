/// 下载完成钩子：`auto_ocr` 为真的章下载完后自动起整卷 OCR（设计稿 2026-09-12 §4）。
///
/// 与向导共用同一份引擎探测 / 解析（`manga_ocr_engine_probe.dart`），差别只有
/// 「没有用户在场」：解析不到可用引擎就跳过并记日志；Google Lens 需要用户逐次
/// 同意上传，后台不能替用户点，偏好显式选了它也跳过。任务一律经
/// `MangaOcrJobRegistry.enqueue`（BUG-2449 的所有权规则）：同书上一章还在识别时
/// 本章排在它后面，不会被 `start` 的「同书已有任务则返回旧的」静默吞掉。
library;

import 'dart:async';

import 'package:fushi/src/media/manga/download/manga_download_service.dart';
import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/manga_ocr_engine_probe.dart';
import 'package:fushi/src/media/manga/manga_ocr_job_stream.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_job_registry.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 事件流构造口（测试注入；生产是 [mangaOcrBackgroundEvents]）。
typedef MangaOcrEventsBuilder = Stream<MangaOcrBackgroundEvent> Function(
  MangaOcrJobSpec spec,
);

/// 为刚下载完的一章排一个整卷 OCR 任务。返回排上的任务；跳过返回 null。
///
/// [imageDirPath] 取**章目录**（含 `manga.json` + `images/`）而不是 `images/`
/// 本身：执行器按目录递归枚举页图并以相对路径写 url，从章目录起算得到的正是
/// `images/page-000001.jpg`，与下载服务写进章 `manga.json` 的 url 逐字一致；从
/// `images/` 起算会得到裸文件名，OCR 落盘后阅读器就对不上页了。已入库本地卷的
/// 整卷 OCR（`existingBook.extractDir`）走的也是这个约定。
Future<MangaOcrRunningJob?> runAutoMangaOcrForDownloadedChapter({
  required MangaDownloadedChapter chapter,
  required MangaOcrWizardEngines engines,
  required MangaOcrJobRegistry registry,
  required MangaOcrEnginePreference preference,
  required String lensLanguage,
  MangaOcrEventsBuilder buildEvents = mangaOcrBackgroundEvents,
}) async {
  final MangaOcrEngineAvailability availability =
      await probeMangaOcrEngines(engines);
  final MangaOcrEngineId? engine = resolveBackgroundMangaOcrEngine(
    preference: preference,
    availability: availability,
  );
  if (engine == null) {
    ErrorLogService.instance.log(
      'MangaDownloadAutoOcr.skip ${chapter.bookKey}/${chapter.chapterKey}',
      StateError(
        'No background-capable OCR engine for preference ${preference.key}',
      ),
      StackTrace.current,
    );
    return null;
  }
  final MangaOcrJobSpec spec = MangaOcrJobSpec(
    engine: engine,
    engines: engines,
    imageDirPath: chapter.chapterDirectory.path,
    lensLanguage: lensLanguage,
    volumeTitle: chapter.chapterTitle.isEmpty
        ? chapter.title
        : '${chapter.title} ${chapter.chapterTitle}',
    remoteTarget: availability.remoteTarget,
  );
  final MangaOcrBackgroundJob job = MangaOcrBackgroundJob(
    bookKey: chapter.bookKey,
    managedDirectory: chapter.chapterDirectory.path,
    engine: engine,
    events: buildEvents(spec),
  );
  return registry.enqueue(job: job, mangaJsonPath: chapter.mangaJsonPath);
}

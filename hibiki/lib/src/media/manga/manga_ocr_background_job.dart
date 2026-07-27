import 'package:hibiki/src/media/manga/mokuro_payload.dart';
import 'package:hibiki/src/media/manga/ocr/manga_ocr_engine.dart';

/// 阅读器持有的非模态整卷 OCR 任务。订阅 [events] 才真正启动底层识别；
/// 取消订阅会沿用各执行器既有的取消语义，在页边界停止并保留逐页缓存。
class MangaOcrBackgroundJob {
  const MangaOcrBackgroundJob({
    required this.bookKey,
    required this.managedDirectory,
    required this.engine,
    required this.events,
  });

  final String bookKey;
  final String managedDirectory;
  final MangaOcrEngineId engine;
  final Stream<MangaOcrBackgroundEvent> events;
}

/// 后台 OCR 的统一事件。支持增量引擎时 [pageIndex]/[page] 随进度事件返回，
/// 阅读器可立即替换该页的透明文字层；不支持增量的执行器在最终事件一次性刷新。
class MangaOcrBackgroundEvent {
  const MangaOcrBackgroundEvent.progress({
    required this.pagesDone,
    required this.pagesTotal,
    this.pageIndex,
    this.page,
  })  : resultPath = null,
        external = false,
        finished = false;

  const MangaOcrBackgroundEvent.finished({
    required this.pagesTotal,
    required String this.resultPath,
    required this.external,
  })  : pagesDone = pagesTotal,
        pageIndex = null,
        page = null,
        finished = true;

  final int pagesDone;
  final int pagesTotal;
  final int? pageIndex;
  final MokuroImage? page;
  final String? resultPath;
  final bool external;
  final bool finished;
}

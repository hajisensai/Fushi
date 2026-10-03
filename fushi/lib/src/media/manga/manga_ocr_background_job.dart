import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';

/// 阅读器持有的非模态整卷 OCR 任务。订阅 [events] 才真正启动底层识别；
/// 取消订阅会沿用各执行器既有的取消语义，在页边界停止并保留逐页缓存。
class MangaOcrBackgroundJob {
  const MangaOcrBackgroundJob({
    required this.bookKey,
    required this.managedDirectory,
    required this.engine,
    required this.events,
    this.focus,
    this.follower,
  });

  final String bookKey;
  final String managedDirectory;
  final MangaOcrEngineId engine;
  final Stream<MangaOcrBackgroundEvent> events;

  /// 读者当前页的改道通道（与构造 [events] 的 `MangaOcrJobSpec.focus` 是同一个
  /// 实例）；null = 这个任务不跟读者走（远端 / 外部 CLI / 旧入口）。
  final MangaOcrPageFocus? focus;

  /// 任务之外的收尾步骤（目前只有大模型识别）；null = 没有。由注册表驱动，见
  /// [MangaOcrJobFollower]。
  final MangaOcrJobFollower? follower;
}

/// 跟随步骤改好的一页：[pageIndex] 是该页在整卷结果里的序号。
typedef MangaOcrPageUpdate = ({int pageIndex, MokuroImage page});

/// 跟着整卷任务走、但**不占任务寿命**的后处理步骤（大模型重读）。
///
/// 为什么不做成事件流包装：包装在流里，任务的 finished 就得等它清空、全局 OCR
/// 名额也被它一直占着；而外部 mokuro / 配对主机的进度事件不带页内容，所有工作
/// 都被推到 finished 之后串行。拆出来以后由注册表按这个契约驱动：
/// - 任务进行中每个带页的进度交给 [onProgress]，改好的页从 [updates] 回来；
/// - finished 落盘前 [mergeInto] 把已改好的页同步并进整卷结果（不等任何请求）；
/// - 落盘后 [onPersisted] 交出书根 manga.json：剩下的页在任务**结束之后**继续
///   处理，每改好一页经 manga.json 写锁读改写落盘，再从 [updates] 发出；
/// - [cancel] 中止一切（任务取消、删书、同目录起了新任务），之后不再写盘。
abstract interface class MangaOcrJobFollower {
  void onProgress(MangaOcrBackgroundEvent event);

  MokuroPayload mergeInto(MokuroPayload payload);

  void onPersisted(String mangaJsonPath, MokuroPayload payload);

  Stream<MangaOcrPageUpdate> get updates;

  /// 所有工作做完（或被取消）时完成，不带错误。
  Future<void> get done;

  Future<void> cancel();
}

/// 后台 OCR 的统一事件。支持增量引擎时 [pageIndex]/[page] 随进度事件返回，
/// 阅读器可立即替换该页的透明文字层；不支持增量的执行器在最终事件一次性刷新。
class MangaOcrBackgroundEvent {
  const MangaOcrBackgroundEvent.progress({
    required this.pagesDone,
    required this.pagesTotal,
    this.pageIndex,
    this.page,
    this.acceleration,
  }) : resultPath = null,
       external = false,
       finished = false;

  const MangaOcrBackgroundEvent.finished({
    required this.pagesTotal,
    required String this.resultPath,
    required this.external,
    this.acceleration,
  }) : pagesDone = pagesTotal,
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

  /// 本地 ONNX 引擎实际生效的推理加速状态；其它引擎为 null（BUG-1163）。
  final MangaOcrAcceleration? acceleration;
}

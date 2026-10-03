/// 阅读器「进入即整卷识别」：打开一卷 / 一章后，尚未识别的就自动排一个整卷 OCR
/// 任务，进度在页面右上角浮标里显示（对齐 Mangatan / Chimahon 的开书即识别）。
///
/// 任务本体与作品页「识别本章」、下载完成钩子是同一种：经
/// `MangaOcrJobRegistry.enqueue` 交给 app 级注册表（BUG-2449 所有权 + 同书 FIFO），
/// 阅读器只观察进度、逐页热替换、提供取消。与下载钩子的差别只有「用户在场」：
/// 引擎解析沿用作品页的有人值守口径，Google Lens 可以用，但要先过一次上传同意
/// 闸门（文案同意的正是「识别本漫画会上传尚无 OCR 文本的页面」）。
library;

import 'package:fushi/src/media/manga/download/manga_download_auto_ocr.dart'
    show MangaOcrEventsBuilder;
import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/manga_ocr_engine_probe.dart';
import 'package:fushi/src/media/manga/manga_ocr_job_stream.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart' show MangaOcrPageFocus;
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_job_registry.dart';
import 'package:path/path.dart' as p;

/// [startMangaReaderVolumeOcr] 的结局。
sealed class MangaReaderVolumeOcrOutcome {
  const MangaReaderVolumeOcrOutcome();
}

/// 已排进注册表；[started] 在任务真正开跑时完成（同书上一章还在识别时要等它），
/// 排队期间被取消则以 null 完成。
final class MangaReaderVolumeOcrQueued extends MangaReaderVolumeOcrOutcome {
  const MangaReaderVolumeOcrQueued(this.started);

  final Future<MangaOcrRunningJob?> started;
}

/// 这个目录已经在跑或已在排队：不重复排，调用方按目录接回即可。
final class MangaReaderVolumeOcrAlreadyScheduled
    extends MangaReaderVolumeOcrOutcome {
  const MangaReaderVolumeOcrAlreadyScheduled();
}

/// 没有可用引擎（没下本地模型、系统 OCR 不可用且偏好没选别的）。
final class MangaReaderVolumeOcrNoEngine extends MangaReaderVolumeOcrOutcome {
  const MangaReaderVolumeOcrNoEngine();
}

/// 解析到 Google Lens，但用户没同意上传。
final class MangaReaderVolumeOcrLensDeclined
    extends MangaReaderVolumeOcrOutcome {
  const MangaReaderVolumeOcrLensDeclined();
}

/// 调用方限定了引擎（[startMangaReaderVolumeOcr] 的 `requiredEngine`），而当前
/// 偏好解析出的不是它：什么都没排，也不算「没有引擎」。
final class MangaReaderVolumeOcrNotApplicable
    extends MangaReaderVolumeOcrOutcome {
  const MangaReaderVolumeOcrNotApplicable();
}

/// 这个目录是否已有整卷任务在跑或在排队（按规范化路径比较）。
bool isMangaVolumeOcrScheduled({
  required MangaOcrJobRegistry registry,
  required String bookKey,
  required String imageDirPath,
}) {
  final MangaOcrRunningJob? running = registry.running(bookKey);
  if (running != null && p.equals(running.job.managedDirectory, imageDirPath)) {
    return true;
  }
  return registry
      .queuedDirectories(bookKey)
      .any((String directory) => p.equals(directory, imageDirPath));
}

/// 为阅读器当前打开的卷 / 章排一个整卷 OCR 任务（只补尚无结果的页）。
///
/// [imageDirPath] 与作品页、下载钩子同一约定：本地卷是 `extractDir`，在线章是章
/// 目录（含 `manga.json` + `images/`）。[startPage] 是当前页：执行器从它开始、
/// 再绕回开头补齐，读者眼前这页最先出结果。
///
/// [requiredEngine] 非 null 时只在偏好解析到它时才排（否则
/// [MangaReaderVolumeOcrNotApplicable]，不弹任何同意框）——已识别本地卷的行几何
/// 升级只能交给本地引擎（BUG-2813）。
Future<MangaReaderVolumeOcrOutcome> startMangaReaderVolumeOcr({
  required String bookKey,
  required String imageDirPath,
  required String mangaJsonPath,
  required String volumeTitle,
  required int startPage,
  required MangaOcrWizardEngines engines,
  required MangaOcrJobRegistry registry,
  required MangaOcrEnginePreference preference,
  required String lensLanguage,
  required Future<bool> Function() confirmLensUpload,
  MangaOcrEngineId? requiredEngine,
  MangaOcrEventsBuilder buildEvents = mangaOcrBackgroundEvents,
}) async {
  bool scheduled() => isMangaVolumeOcrScheduled(
    registry: registry,
    bookKey: bookKey,
    imageDirPath: imageDirPath,
  );
  if (scheduled()) return const MangaReaderVolumeOcrAlreadyScheduled();
  final MangaOcrEngineAvailability availability = await probeMangaOcrEngines(
    engines,
  );
  final MangaOcrEngineId? engine = resolveMangaOcrEngine(
    preference: preference,
    hasExistingMetadata: false,
    capabilities: availability.capabilities,
  );
  if (requiredEngine != null && engine != requiredEngine) {
    return const MangaReaderVolumeOcrNotApplicable();
  }
  if (engine == null || !availability.isUsable(engine)) {
    return const MangaReaderVolumeOcrNoEngine();
  }
  if (engine == MangaOcrEngineId.googleLens && !await confirmLensUpload()) {
    return const MangaReaderVolumeOcrLensDeclined();
  }
  // 探测 / 同意框期间别处（作品页、下载钩子、另一个阅读器实例）可能已排上。
  if (scheduled()) return const MangaReaderVolumeOcrAlreadyScheduled();
  // 起点只定一次不够：手机上一页识别几十秒，读者翻得比它快。阅读器每翻一页
  // 经 MangaOcrRunningJob.focusPage 改道，翻到的页下一个就识别。
  final MangaOcrPageFocus focus = MangaOcrPageFocus();
  final MangaOcrJobSpec spec = MangaOcrJobSpec(
    engine: engine,
    engines: engines,
    imageDirPath: imageDirPath,
    lensLanguage: lensLanguage,
    startPage: startPage,
    volumeTitle: volumeTitle,
    remoteTarget: availability.remoteTarget,
    focus: focus,
  );
  return MangaReaderVolumeOcrQueued(
    registry.enqueue(
      job: MangaOcrBackgroundJob(
        bookKey: bookKey,
        managedDirectory: imageDirPath,
        engine: engine,
        events: buildEvents(spec),
        focus: focus,
        follower: mangaOcrJobFollower(spec),
      ),
      mangaJsonPath: mangaJsonPath,
    ),
  );
}

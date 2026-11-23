/// 有声漫画一卷「现在忙不忙」的唯一判据：标注在跑、生成在排队 / 在跑、导出包正在导入
/// 这一卷，三者任一都算忙。标注 / 生成 / 导出 / 导入 / 撤销导入的入口（工作台、控制通道、
/// CLI）都从这里取结论，不各自拼判据——各拼各的就会漏掉一类（导入落库时还能标注 /
/// 生成同一卷的缺口就是这么来的）。
///
/// 标注与生成的任务表本身也在开始时过「正在导入」这一道（[MangaAnnotateTasks] 的
/// `blocker`、[TtsRenderQueue] 的 `admission`，装配在 [mangaAnnotateTasksFor] /
/// [ttsRenderQueueFor]），入口漏查也写不进正在导入的卷。
library;

import 'package:fushi_engine/tts/render/tts_render_queue.dart';

import 'package:fushi/src/media/audiobook/tts/studio/audio_production_host.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_service.dart'
    show ttsRenderQueueFor;
import 'package:fushi/src/media/manga/audio/manga_audio_annotate_tasks.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_package_tasks.dart';

/// 一卷忙在什么上。
enum MangaVolumeBusy {
  /// 看图标注在跑。
  annotating,

  /// 生成任务在排队 / 在跑。
  rendering,

  /// 导出包的导入任务占住了这一卷（解包到落库结束）。
  importing,
}

/// 标注 / 生成因为这一卷忙而没能开始。
class MangaVolumeBusyException implements Exception {
  const MangaVolumeBusyException(this.bookKey, this.busy);

  final String bookKey;
  final MangaVolumeBusy busy;

  @override
  String toString() => 'MangaVolumeBusyException($bookKey, ${busy.name})';
}

/// 生成队列拒收「正在导入」的卷时的原因码（[TtsRenderRejected.reason]）。
const String kMangaPackageImportingCode = 'manga_package_importing';

/// [bookKey] 这一卷忙在什么上；不忙为 null。[except] = 不把这个导入任务自己算进去
/// （导入落库时逐卷复查用）。
MangaVolumeBusy? mangaVolumeBusy(
  String bookKey, {
  required MangaAnnotateTasks annotate,
  required TtsRenderQueue renderQueue,
  required MangaAudioPackageTasks packages,
  MangaAudioPackageTask? except,
}) {
  if (annotate.isRunning(bookKey)) return MangaVolumeBusy.annotating;
  final TtsRenderJob? job = renderQueue.latestFor(bookKey);
  if (job != null && !job.isTerminal) return MangaVolumeBusy.rendering;
  if (packages.importingVolume(bookKey, except: except) != null) {
    return MangaVolumeBusy.importing;
  }
  return null;
}

/// 应用里的装配：这个应用的标注任务表、全应用的生成队列、[packages]（默认进程级任务表）。
MangaVolumeBusy? mangaVolumeBusyFor(
  AudioProductionHost host,
  String bookKey, {
  MangaAudioPackageTasks? packages,
  MangaAudioPackageTask? except,
}) => mangaVolumeBusy(
  bookKey,
  annotate: mangaAnnotateTasksFor(host),
  renderQueue: ttsRenderQueueFor(host),
  packages: packages ?? MangaAudioPackageTasks.instance,
  except: except,
);

/// 标注 / 生成任务表开始前的那一道：只看「正在导入」（标注与生成彼此的互斥由各自入口管）。
MangaVolumeBusy? mangaVolumeImportBlocker(
  String bookKey, {
  MangaAudioPackageTasks? packages,
}) =>
    (packages ?? MangaAudioPackageTasks.instance).importingVolume(bookKey) ==
        null
    ? null
    : MangaVolumeBusy.importing;

/// 「在阅读器外给漫画排 OCR」的共享路径：作品页「识别本章 / 识别全部已下载」、
/// 库页卡菜单「识别文字」与多选「识别文字」（BUG-3341）都走这里。
///
/// 一本漫画书在磁盘上有两种形态，识别目标随之不同：
/// - **在线作品**（`sourceMetadata` 能解析成 [OnlineMangaLibraryEntry]）：每章一个
///   受管目录，目标是「已下载且还没识别」的章；
/// - **本地卷**：整卷一个目录（`extractDir`，`manga.json` 在 `epubPath`），目标是
///   还没识别的卷本身。
///
/// 引擎解析与作品页此前那份逐字相同（用户在场：Lens 可以选，但要先过上传同意
/// 闸门）；任务一律经 [MangaOcrJobRegistry.enqueue] 按 bookKey 排队（BUG-2449
/// 所有权 + 同书 FIFO），阅读器按 bookKey + 目录接回进度。
library;

import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/manga/library/manga_chapter_storage.dart';
import 'package:fushi/src/media/manga/library/online_manga_chapter_updates.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/manga_ocr_engine_probe.dart';
import 'package:fushi/src/media/manga/manga_ocr_job_stream.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_disclosure.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_job_registry.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart' show MangaOcrPageFocus;
import 'package:path/path.dart' as p;

/// 一个 OCR 任务的目标目录（章目录或本地卷目录）。
@immutable
class MangaOcrTarget {
  const MangaOcrTarget({
    required this.bookKey,
    required this.directory,
    required this.mangaJsonPath,
    required this.title,
    this.onlyMissing = true,
  });

  final String bookKey;

  /// 识别目录（含 `manga.json` 与页图），页图 url 相对它解析。
  final String directory;

  /// 识别结果落盘的 `manga.json`。
  final String mangaJsonPath;

  /// 任务显示名（进度横幅 / 通知）。
  final String title;

  /// false = 丢掉逐页缓存重新识别（见 [MangaOcrJobSpec.onlyMissing]）。
  final bool onlyMissing;
}

/// 一份 `manga.json` 的识别状态：一个 block 都没有 = 还没识别过（[empty]）；
/// 读不出来单独一态（[unreadable]）——坏文件既不排进批量识别，也不当作「已有
/// 结果」去丢缓存重跑。
enum MangaOcrResultState { empty, hasResult, unreadable }

/// 读 [mangaJson] 的识别状态（见 [MangaOcrResultState]）。
Future<MangaOcrResultState> readMangaOcrResultState(File mangaJson) async {
  try {
    final MokuroPayload payload = parseMangaJson(
      await mangaJson.readAsString(),
    );
    final bool empty =
        payload.images.isNotEmpty &&
        payload.images.every((MokuroImage image) => image.blocks.isEmpty);
    return empty ? MangaOcrResultState.empty : MangaOcrResultState.hasResult;
  } on Object {
    return MangaOcrResultState.unreadable;
  }
}

/// 在线作品某一章的识别目标（章目录约定见 `manga_download_auto_ocr.dart`）。
MangaOcrTarget mangaChapterOcrTarget({
  required String bookKey,
  required String bookDir,
  required OnlineMangaLibraryEntry entry,
  required OnlineMangaChapter chapter,
  bool onlyMissing = true,
}) {
  final Directory chapterDir = mangaChapterDirectory(bookDir, chapter.key);
  return MangaOcrTarget(
    bookKey: bookKey,
    directory: chapterDir.path,
    mangaJsonPath: mangaChapterJsonFile(chapterDir).path,
    title: '${entry.series.title} ${mangaChapterDisplayName(chapter)}',
    onlyMissing: onlyMissing,
  );
}

/// [row] 这本漫画里**还没识别**的目标：在线作品 = 已下载且未识别的章（旧到新），
/// 本地卷 = 未识别的卷本身。已识别 / 未下载 / 读不出的都不在内。
Future<List<MangaOcrTarget>> pendingMangaOcrTargets(EpubBookRow row) =>
    mangaOcrTargetsForBook(row);

/// [pendingMangaOcrTargets] 的一般形态：[force] 为真时连已识别的部分也算进来，
/// 且目标带 `onlyMissing: false`（丢掉逐页缓存整卷重跑，阅读器「重新识别本卷」
/// 同一语义）；读不出的 manga.json 两种模式都跳过。未下载的章永远不在内。
Future<List<MangaOcrTarget>> mangaOcrTargetsForBook(
  EpubBookRow row, {
  bool force = false,
}) async {
  Future<bool> wanted(File json) async {
    final MangaOcrResultState state = await readMangaOcrResultState(json);
    return force
        ? state != MangaOcrResultState.unreadable
        : state == MangaOcrResultState.empty;
  }

  final OnlineMangaLibraryEntry? entry = OnlineMangaLibraryEntry.tryParse(
    row.sourceMetadata,
  );
  if (entry == null) {
    final File json = File(p.join(row.extractDir, row.epubPath));
    if (!await wanted(json)) return const <MangaOcrTarget>[];
    return <MangaOcrTarget>[
      MangaOcrTarget(
        bookKey: row.bookKey,
        directory: row.extractDir,
        mangaJsonPath: json.path,
        title: row.title,
        onlyMissing: !force,
      ),
    ];
  }
  final String bookDir = await MangaStorage.bookPath(row.bookKey);
  final List<MangaOcrTarget> targets = <MangaOcrTarget>[];
  for (final OnlineMangaChapter chapter in entry.chapters.reversed) {
    if (!await isChapterDownloaded(bookDir, chapter.key)) continue;
    final MangaOcrTarget target = mangaChapterOcrTarget(
      bookKey: row.bookKey,
      bookDir: bookDir,
      entry: entry,
      chapter: chapter,
      onlyMissing: !force,
    );
    if (await wanted(File(target.mangaJsonPath))) targets.add(target);
  }
  return targets;
}

/// 解析引擎（一次）、逐个目标排任务。返回排上的任务数；解析不到可用引擎 /
/// 用户拒绝 Lens 上传 → 0（前者提示「没有可用的识别引擎」）。
///
/// [enginesOverride] / [lensGate] 只是测试缝，生产传 null。
Future<int> enqueueMangaOcrTargets({
  required BuildContext context,
  required AppModel appModel,
  required MangaOcrJobRegistry registry,
  required List<MangaOcrTarget> targets,
  MangaOcrWizardEngines? enginesOverride,
  GoogleLensDisclosureGate? lensGate,
  MangaOcrEngineId? engineChoice,
}) async {
  if (targets.isEmpty) return 0;
  final MangaOcrWizardEngines engines =
      enginesOverride ??
      MangaOcrWizardEngines.resolve(context: context, db: appModel.database);
  final MangaOcrEngineAvailability availability = await probeMangaOcrEngines(
    engines,
  );
  final MangaOcrEnginePreference preference =
      MangaOcrEnginePreferenceKey.fromKey(appModel.mangaOcrEnginePreference);
  // [engineChoice]：调用方为**本次**点名的引擎（整卷 OCR 向导选引擎同一语义，
  // 不写偏好）；null = 按用户偏好解析。可用性判据两条路一样（isUsable）。
  final MangaOcrEngineId? engine =
      engineChoice ??
      resolveMangaOcrEngine(
        preference: preference,
        hasExistingMetadata: false,
        capabilities: availability.capabilities,
      );
  if (!context.mounted) return 0;
  if (engine == null || !availability.isUsable(engine)) {
    FushiToast.show(
      msg: t.manga_series_ocr_no_engine,
      severity: ToastSeverity.error,
    );
    return 0;
  }
  if (engine == MangaOcrEngineId.googleLens) {
    final GoogleLensDisclosureGate gate =
        lensGate ?? ensureGoogleLensDisclosure;
    if (!await gate(context)) return 0;
    if (!context.mounted) return 0;
  }
  for (final MangaOcrTarget target in targets) {
    final MangaOcrPageFocus focus = MangaOcrPageFocus();
    final MangaOcrJobSpec spec = MangaOcrJobSpec(
      engine: engine,
      engines: engines,
      imageDirPath: target.directory,
      lensLanguage: appModel.mangaOcrLensLanguage,
      onlyMissing: target.onlyMissing,
      volumeTitle: target.title,
      remoteTarget: availability.remoteTarget,
      focus: focus,
    );
    // 刻意不 await 启动：同书上一章还在识别时 enqueue 要等它结束。
    unawaited(
      registry.enqueue(
        job: MangaOcrBackgroundJob(
          bookKey: target.bookKey,
          managedDirectory: target.directory,
          engine: engine,
          events: mangaOcrBackgroundEvents(spec),
          focus: focus,
          follower: mangaOcrJobFollower(spec),
        ),
        mangaJsonPath: target.mangaJsonPath,
      ),
    );
  }
  return targets.length;
}

/// 库页入口（卡菜单「识别文字」/ 多选「识别文字」）：把 [bookKeys] 里每本漫画
/// 还没识别的部分排上，并给出结果提示。返回排上的任务数。
Future<int> enqueuePendingMangaOcrForBooks({
  required BuildContext context,
  required AppModel appModel,
  required MangaOcrJobRegistry registry,
  required Iterable<String> bookKeys,
}) async {
  final List<MangaOcrTarget> targets = <MangaOcrTarget>[];
  for (final String bookKey in bookKeys.toSet()) {
    final EpubBookRow? row = await appModel.database.getEpubBook(bookKey);
    if (row == null || row.format != BookFormat.manga.dbValue) continue;
    targets.addAll(await pendingMangaOcrTargets(row));
  }
  if (!context.mounted) return 0;
  if (targets.isEmpty) {
    FushiToast.show(msg: t.manga_library_ocr_none);
    return 0;
  }
  final int queued = await enqueueMangaOcrTargets(
    context: context,
    appModel: appModel,
    registry: registry,
    targets: targets,
  );
  if (queued > 0) FushiToast.show(msg: t.manga_series_ocr_queued);
  return queued;
}

/// 「跑一卷漫画 OCR」的事件流，与任何 UI 无关。
///
/// 这段编排以前住在 `MangaOcrWizardDialog` 的 State 里，于是「想跑 OCR」在结构上
/// 等价于「先弹一个对话框」。导入向导是这样，阅读器的整卷按钮也是这样——而阅读器
/// 里「点一下气泡就查词」的按需路径根本不该弹任何东西。把编排搬到这里之后，
/// 对话框只剩下「选参数」这一件事，跑任务的能力谁都能直接调。
///
/// 四个引擎（本地 ONNX / Google Lens / 外部 mokuro CLI / 已配对主机）在这里各占
/// 一个分支，输出统一成 [MangaOcrBackgroundEvent]：逐页 progress（带该页的
/// [MokuroImage] 供 UI 热替换文字层）+ 末尾 finished（带 manga.json 路径）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/external_mokuro_runner.dart';
import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/mokuro_payload.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_ocr_service.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_protocol.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/ocr/manga_ocr_folder_job.dart';
import 'package:fushi/src/ocr/manga_ocr_model_fingerprint.dart';
import 'package:fushi/src/ocr/manga_ocr_service.dart';
import 'package:fushi/src/ocr/ocr_types.dart';
import 'package:fushi/src/sync/interconnect_manga_ocr_client.dart';
import 'package:fushi/utils.dart';

/// 一次 OCR 任务的全部输入。
///
/// 刻意做成值对象而不是一串位置参数：四个引擎分支需要的东西不同（Lens 要语言、
/// 远程要 target、本地一个都不要），散成参数表就会重演「某个入口抄漏一项」那类
/// 编译期无痕的遗漏（[MangaOcrWizardEngines] 的文档里记着同形的 BUG-1418）。
class MangaOcrJobSpec {
  const MangaOcrJobSpec({
    required this.engine,
    required this.engines,
    required this.imageDirPath,
    required this.lensLanguage,
    this.startPage = 0,
    this.onlyMissing = true,
    this.volumeTitle,
    this.remoteTarget,
  });

  final MangaOcrEngineId engine;

  /// 四个引擎的 runner 集合（唯一装配点：[MangaOcrWizardEngines.resolve]）。
  final MangaOcrWizardEngines engines;

  /// 待识别的图片目录（已入库漫画就是它的 extractDir）。
  final String imageDirPath;

  /// Lens 识别语言；其他引擎忽略。
  final String lensLanguage;

  /// 从哪一页开始跑。Lens 会绕回开头补齐前面的页，「当前页优先」正是靠它。
  final int startPage;

  /// 跳过已有结果的页。
  final bool onlyMissing;

  final String? volumeTitle;

  /// 已配对主机目标；`pairedHost` 引擎必填（由 `remoteRunner.probe()` 得到）。
  final MangaOcrRemoteTarget? remoteTarget;
}

/// 按引擎分发，产出统一的后台事件流。
Stream<MangaOcrBackgroundEvent> mangaOcrBackgroundEvents(
  MangaOcrJobSpec spec,
) {
  switch (spec.engine) {
    case MangaOcrEngineId.localOnnx:
      return mangaOcrLocalEvents(spec);
    case MangaOcrEngineId.googleLens:
      return mangaOcrLensEvents(spec);
    case MangaOcrEngineId.externalMokuro:
      return mangaOcrExternalEvents(spec);
    case MangaOcrEngineId.pairedHost:
      return mangaOcrRemoteEvents(spec);
  }
}

Stream<MangaOcrBackgroundEvent> mangaOcrLocalEvents(
  MangaOcrJobSpec spec,
) async* {
  final String dir = spec.imageDirPath;
  final List<MangaOcrPageFile> pages = enumerateMangaPages(Directory(dir));
  // 「整卷已缓存 → 直接产出、跳过 OCR」的探测必须与真实任务用同一个签名，
  // 否则换模型后会拿旧模型的缓存冒充新结果（BUG-1173）。
  final String engineSignature =
      await resolveInstalledLocalMangaOcrEngineSignature();
  final MangaOcrFilePageCache cache = MangaOcrFilePageCache(
    cacheDir: Directory(p.join(
      dir,
      kMangaOcrOutDirName,
      kMangaOcrPagesCacheDirName,
      engineSignature,
    )),
    pageNames: <String>[
      for (final MangaOcrPageFile page in pages) page.relativeUrl
    ],
    pageFiles: <File>[for (final MangaOcrPageFile page in pages) page.file],
  );
  final List<OcrPageResult> cachedResults = <OcrPageResult>[];
  for (int pageIndex = 0; pageIndex < pages.length; pageIndex++) {
    final OcrPageResult? cached = await cache.read('manga_ocr', pageIndex);
    if (cached == null) {
      cachedResults.clear();
      break;
    }
    cachedResults.add(cached);
  }
  if (cachedResults.length == pages.length && pages.isNotEmpty) {
    final MokuroPayload generated =
        buildMangaPayloadFromResults(pages, cachedResults);
    final MokuroPayload payload = MokuroPayload(
      images: generated.images,
      ocr: MangaOcrMetadata(
        engine: 'local_onnx',
        engineSignature: engineSignature,
        schemaVersion: 1,
      ),
    );
    final String output = await writeMangaOcrCachedOutput(dir, payload);
    for (int pageIndex = 0; pageIndex < payload.images.length; pageIndex++) {
      yield MangaOcrBackgroundEvent.progress(
        pagesDone: pageIndex + 1,
        pagesTotal: pages.length,
        pageIndex: pageIndex,
        page: payload.images[pageIndex],
      );
    }
    yield MangaOcrBackgroundEvent.finished(
      pagesTotal: pages.length,
      resultPath: output,
      external: false,
    );
    return;
  }
  await for (final MangaOcrVolumeEvent event in spec.engines.service
      .ocrFolder(imageDirPath: dir, volumeTitle: spec.volumeTitle)) {
    if (event.finished) {
      yield MangaOcrBackgroundEvent.finished(
        pagesTotal: event.pagesTotal,
        resultPath: event.mangaJsonPath!,
        external: false,
        acceleration: event.acceleration,
      );
      continue;
    }
    final int pageIndex = event.pagesDone - 1;
    MokuroImage? page;
    if (pageIndex >= 0 && pageIndex < pages.length) {
      final OcrPageResult? result = await cache.read('manga_ocr', pageIndex);
      if (result != null) {
        page = buildMangaPayloadFromResults(
          <MangaOcrPageFile>[pages[pageIndex]],
          <OcrPageResult>[result],
        ).images.single;
      }
    }
    yield MangaOcrBackgroundEvent.progress(
      pagesDone: event.pagesDone,
      pagesTotal: event.pagesTotal,
      pageIndex: pageIndex,
      page: page,
      acceleration: event.acceleration,
    );
  }
}

Stream<MangaOcrBackgroundEvent> mangaOcrLensEvents(
  MangaOcrJobSpec spec,
) async* {
  final String dir = spec.imageDirPath;
  final List<MangaOcrPageFile> pages = enumerateMangaPages(Directory(dir));
  final int start =
      pages.isEmpty ? 0 : spec.startPage.clamp(0, pages.length - 1);
  final List<int> order = <int>[
    for (int index = start; index < pages.length; index++) index,
    for (int index = 0; index < start; index++) index,
  ];
  final GoogleLensPageCache cache = GoogleLensPageCache(
    Directory(p.join(
      dir,
      kMangaOcrOutDirName,
      kMangaOcrPagesCacheDirName,
      googleLensEngineSignature(spec.lensLanguage),
    )),
  );
  final List<MokuroImage> cachedPages = <MokuroImage>[];
  for (int pageIndex = 0; pageIndex < pages.length; pageIndex++) {
    final MokuroImage? cached = await cache.read(pageIndex, pages[pageIndex]);
    if (cached == null) {
      cachedPages.clear();
      break;
    }
    cachedPages.add(cached);
  }
  if (cachedPages.length == pages.length && pages.isNotEmpty) {
    final MokuroPayload payload = MokuroPayload(
      images: cachedPages,
      ocr: MangaOcrMetadata(
        engine: 'google_lens',
        engineSignature: googleLensEngineSignature(spec.lensLanguage),
        schemaVersion: 1,
      ),
    );
    final String output = await writeMangaOcrCachedOutput(dir, payload);
    for (int orderIndex = 0; orderIndex < order.length; orderIndex++) {
      final int pageIndex = order[orderIndex];
      yield MangaOcrBackgroundEvent.progress(
        pagesDone: orderIndex + 1,
        pagesTotal: pages.length,
        pageIndex: pageIndex,
        page: cachedPages[pageIndex],
      );
    }
    yield MangaOcrBackgroundEvent.finished(
      pagesTotal: pages.length,
      resultPath: output,
      external: false,
    );
    return;
  }
  await for (final MangaOcrVolumeEvent event
      in spec.engines.lensRunner!.ocrFolder(
    imageDirPath: dir,
    volumeTitle: spec.volumeTitle,
    startPage: spec.startPage,
    onlyMissing: spec.onlyMissing,
    language: spec.lensLanguage,
  )) {
    if (event.finished) {
      yield MangaOcrBackgroundEvent.finished(
        pagesTotal: event.pagesTotal,
        resultPath: event.mangaJsonPath!,
        external: false,
      );
      continue;
    }
    final int orderIndex = event.pagesDone - 1;
    final int? pageIndex =
        orderIndex >= 0 && orderIndex < order.length ? order[orderIndex] : null;
    final MokuroImage? page = pageIndex == null
        ? null
        : await cache.read(pageIndex, pages[pageIndex]);
    yield MangaOcrBackgroundEvent.progress(
      pagesDone: event.pagesDone,
      pagesTotal: event.pagesTotal,
      pageIndex: pageIndex,
      page: page,
    );
  }
}

Stream<MangaOcrBackgroundEvent> mangaOcrExternalEvents(
  MangaOcrJobSpec spec,
) async* {
  await for (final MokuroRunEvent event
      in spec.engines.externalRunner!.run(spec.imageDirPath)) {
    if (event.finished) {
      yield MangaOcrBackgroundEvent.finished(
        pagesTotal: event.total,
        resultPath: event.mokuroPath!,
        external: true,
      );
    } else {
      yield MangaOcrBackgroundEvent.progress(
        pagesDone: event.done,
        pagesTotal: event.total,
      );
    }
  }
}

Stream<MangaOcrBackgroundEvent> mangaOcrRemoteEvents(
  MangaOcrJobSpec spec,
) async* {
  final MangaOcrRemoteTarget? target = spec.remoteTarget;
  if (target == null) {
    throw StateError(t.manga_remote_ocr_no_host);
  }
  await for (final MangaOcrRemoteEvent event in spec.engines.remoteRunner!.run(
    target: target,
    imageDirPath: spec.imageDirPath,
    volumeTitle: spec.volumeTitle,
  )) {
    if (event.finished) {
      yield MangaOcrBackgroundEvent.finished(
        pagesTotal: event.total,
        resultPath: event.mangaJsonPath!,
        external: false,
      );
    } else {
      yield MangaOcrBackgroundEvent.progress(
        pagesDone: event.done,
        pagesTotal: event.total,
      );
    }
  }
}

/// 把「整卷已缓存」这条快路径的结果落成 manga.json（原子写）。
Future<String> writeMangaOcrCachedOutput(
  String dir,
  MokuroPayload payload,
) async {
  final File output = File(p.join(
    dir,
    kMangaOcrOutDirName,
    kMangaOcrOutputFileName,
  ));
  await output.parent.create(recursive: true);
  final File temporary = File('${output.path}.tmp');
  await temporary.writeAsString(
    jsonEncode(mangaPayloadToJson(payload)),
    flush: true,
  );
  if (output.existsSync()) {
    await output.delete();
  }
  await temporary.rename(output.path);
  return output.path;
}

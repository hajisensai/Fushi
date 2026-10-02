/// 把任意引擎的整卷 OCR 事件流接上大模型识别（[MangaAiOcrRefiner]）。
///
/// 做成事件流包装而不是改各引擎：五个引擎各有一条产出路径，而「框里的字交给
/// 大模型重读」与谁检测的框无关。注册表 / 落盘 / 阅读器都只认事件，这一层对它们
/// 透明：
/// - progress 先原样转发（读者立刻看到本地结果），再在一条**顺序**队列里送大模型，
///   读完补发同一页的 progress——阅读器按页号替换覆盖层，同页事件来两次是常态；
/// - finished 先等队列清空，再把整卷结果按重读过的页改写后落回 manga.json，交出
///   新的 `resultPath`。
///
/// 任何失败（网络、鉴权、回复不合格、读图失败）都保留本地结果，只记一条日志。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/manga_ocr_job_stream.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/manga_ai_ocr_refiner.dart';
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart';

/// [source] 接上 [refiner]。[imageDirPath] 是本卷图片目录（页按
/// `MokuroImage.url` = 相对路径对回原图）。
Stream<MangaOcrBackgroundEvent> refineMangaOcrEventsWithAi(
  Stream<MangaOcrBackgroundEvent> source, {
  required String imageDirPath,
  required MangaAiOcrRefiner refiner,
  MangaAiOcrCache? cache,
}) {
  final MangaAiOcrCache effectiveCache =
      cache ?? MangaAiOcrCache.forVolume(imageDirPath, refiner.provider);
  final Map<String, File> pageFiles = <String, File>{
    for (final MangaOcrPageFile page in enumerateMangaPages(
      Directory(imageDirPath),
    ))
      page.relativeUrl: page.file,
  };
  final Map<String, MokuroImage> refined = <String, MokuroImage>{};
  // 每页只送一次：finished 改写整卷时不为「上次没换成」的页再付一次钱。
  final Set<String> attempted = <String>{};
  bool loggedFailure = false;
  bool cancelled = false;

  Future<MokuroImage?> refineOne(MokuroImage page) async {
    if (!attempted.add(page.url)) return refined[page.url];
    final File? file = pageFiles[page.url];
    if (file == null || cancelled) return null;
    try {
      final Uint8List bytes = await file.readAsBytes();
      final ({MokuroImage page, MangaAiOcrPageStats stats}) result =
          await refiner.refinePage(page, bytes, cache: effectiveCache);
      final String? failure = result.stats.failure;
      if (failure != null && !loggedFailure) {
        loggedFailure = true;
        ErrorLogService.instance.log(
          'MangaAiOcr.refinePage',
          AiChatFailure(failure),
          StackTrace.current,
        );
      }
      if (result.stats.replaced == 0) return null;
      refined[page.url] = result.page;
      return result.page;
    } on Object catch (error, stack) {
      if (!loggedFailure) {
        loggedFailure = true;
        ErrorLogService.instance.log('MangaAiOcr.refinePage', error, stack);
      }
      return null;
    }
  }

  late final StreamController<MangaOcrBackgroundEvent> controller;
  StreamSubscription<MangaOcrBackgroundEvent>? subscription;
  // 顺序队列：同一时刻只有一页在等大模型（限流友好，也让缓存写入不交叠）。
  Future<void> queue = Future<void>.value();

  void enqueueProgress(MangaOcrBackgroundEvent event) {
    final MokuroImage? page = event.page;
    if (page == null) return;
    queue = queue.then((_) async {
      final MokuroImage? better = await refineOne(page);
      if (better == null || cancelled || controller.isClosed) return;
      controller.add(
        MangaOcrBackgroundEvent.progress(
          pagesDone: event.pagesDone,
          pagesTotal: event.pagesTotal,
          pageIndex: event.pageIndex,
          page: better,
          acceleration: event.acceleration,
        ),
      );
    });
  }

  Future<void> finish(MangaOcrBackgroundEvent event) async {
    await queue;
    if (cancelled) return;
    final MangaOcrBackgroundEvent result = await _rewriteResult(
      event,
      imageDirPath: imageDirPath,
      refineOne: refineOne,
    );
    if (!controller.isClosed) controller.add(result);
  }

  controller = StreamController<MangaOcrBackgroundEvent>(
    onListen: () {
      subscription = source.listen(
        (MangaOcrBackgroundEvent event) {
          if (!event.finished) {
            controller.add(event);
            enqueueProgress(event);
            return;
          }
          subscription?.pause();
          finish(event).then(
            (_) => subscription?.resume(),
            onError: (Object error, StackTrace stack) {
              // 改写失败：退回原结果，绝不让 AI 层把一卷本地 OCR 弄丢。
              ErrorLogService.instance.log(
                'MangaAiOcr.rewriteResult',
                error,
                stack,
              );
              if (!controller.isClosed) controller.add(event);
              subscription?.resume();
            },
          );
        },
        onError: controller.addError,
        onDone: () async {
          await queue;
          await controller.close();
        },
      );
    },
    onPause: () => subscription?.pause(),
    onResume: () => subscription?.resume(),
    onCancel: () async {
      cancelled = true;
      await subscription?.cancel();
    },
  );
  return controller.stream;
}

/// 把 finished 的整卷结果按重读过的页改写并落成 manga.json（本仓格式）。
/// 一页都没改写时原样返回，不多写一次文件。
Future<MangaOcrBackgroundEvent> _rewriteResult(
  MangaOcrBackgroundEvent event, {
  required String imageDirPath,
  required Future<MokuroImage?> Function(MokuroImage page) refineOne,
}) async {
  final String path = event.resultPath!;
  final String source = await File(path).readAsString();
  final MokuroPayload payload = event.external
      ? parseMokuro(source)
      : parseMangaJson(source);
  bool changed = false;
  final List<MokuroImage> images = <MokuroImage>[];
  for (final MokuroImage page in payload.images) {
    final MokuroImage? better = await refineOne(page);
    if (better != null) changed = true;
    images.add(better ?? page);
  }
  if (!changed) return event;
  final String output = await writeMangaOcrCachedOutput(
    imageDirPath,
    MokuroPayload(images: images, ocr: payload.ocr),
  );
  return MangaOcrBackgroundEvent.finished(
    pagesTotal: event.pagesTotal,
    resultPath: output,
    external: false,
    acceleration: event.acceleration,
  );
}

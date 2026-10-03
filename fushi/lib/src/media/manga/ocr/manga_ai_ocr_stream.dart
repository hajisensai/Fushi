/// 把任意引擎的整卷 OCR 任务接上大模型识别（[MangaAiOcrRefiner]）。
///
/// 做成任务的**跟随步骤**（[MangaOcrJobFollower]，由注册表驱动）而不是改各引擎、
/// 也不是包在事件流里：五个引擎各有一条产出路径，而「框里的字交给大模型重读」
/// 与谁检测的框无关；包在事件流里则任务的 finished 必须等大模型清空、全局 OCR
/// 名额被大模型请求一直占着，外部 mokuro / 配对主机（进度不带页内容）更是把全部
/// 重读推到卷尾串行。现在的形状：
/// - 任务进行中，带页的进度进一条**顺序**队列送大模型（读者先看到本地结果），
///   读完从 [MangaOcrJobFollower.updates] 补发同一页；
/// - finished 立即落盘（注册表只同步并入已改好的页），名额随任务结束释放；
/// - 落盘后剩下的页在任务之外继续送，每改好一页经 `runExclusiveOnMangaJson`
///   读改写书根 manga.json——只在盘上那页仍是我们重读的那份本地结果时才替换
///   （期间整卷被重新识别过就放弃，不拿旧页的重读覆盖新结果），再补发该页。
///
/// 任何失败（网络、鉴权、回复不合格、读图失败）都保留本地结果，只记一条日志。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi/src/media/manga/manga_json_writeback.dart';
import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/manga_ai_ocr_refiner.dart';
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart';

/// 一页的处理记录：[base] 是送去重读的那份本地页的签名，[result] 是重读后的
/// 签名（没换成任何块时为 null）。
typedef _PageRecord = ({String base, String? result, MokuroImage? better});

/// 整卷任务的大模型跟随步骤。一个任务一个实例。
class MangaAiOcrJobFollower implements MangaOcrJobFollower {
  MangaAiOcrJobFollower({
    required this.imageDirPath,
    required MangaAiOcrRefiner refiner,
    MangaAiOcrCache? cache,
    this.discardCache = false,
  }) : _refiner = refiner,
       _cache =
           cache ?? MangaAiOcrCache.forVolume(imageDirPath, refiner.provider);

  /// 本卷图片目录（页按 `MokuroImage.url` = 相对路径对回原图）。
  final String imageDirPath;

  /// 整卷「重新识别」：开工前清掉本提供商的大模型缓存，让模型真的重读一遍。
  final bool discardCache;

  final MangaAiOcrRefiner _refiner;
  final MangaAiOcrCache _cache;

  final StreamController<MangaOcrPageUpdate> _updates =
      StreamController<MangaOcrPageUpdate>.broadcast();
  final Completer<void> _done = Completer<void>();

  /// 按页 url 记处理过什么：每份本地页只送一次（不为「上次没换成」的页重复付费）。
  final Map<String, _PageRecord> _records = <String, _PageRecord>{};

  /// 顺序队列：同一时刻只有一页在等大模型（限流友好，也让缓存写入不交叠）。
  Future<void> _queue = Future<void>.value();
  Map<String, File>? _pageFiles;

  /// [mergeInto] 已被调用：此后改好的页不会再随 finished 落盘，得自己读改写。
  bool _mergeTaken = false;

  /// [onPersisted] 交来的书根 manga.json；取消时以 null 完成。
  final Completer<String?> _persistedPath = Completer<String?>();
  bool _prepared = false;
  bool _cancelled = false;
  bool _loggedFailure = false;

  @override
  Stream<MangaOcrPageUpdate> get updates => _updates.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void onProgress(MangaOcrBackgroundEvent event) {
    final MokuroImage? page = event.page;
    final int? pageIndex = event.pageIndex;
    if (page == null || pageIndex == null || _cancelled) return;
    _enqueue(() => _refineAndPublish(page, pageIndex: pageIndex));
  }

  @override
  MokuroPayload mergeInto(MokuroPayload payload) {
    _mergeTaken = true;
    bool changed = false;
    final List<MokuroImage> images = <MokuroImage>[];
    for (final MokuroImage page in payload.images) {
      final MokuroImage? better = _betterFor(page);
      changed |= better != null;
      images.add(better ?? page);
    }
    return changed ? MokuroPayload(images: images, ocr: payload.ocr) : payload;
  }

  @override
  void onPersisted(String mangaJsonPath, MokuroPayload payload) {
    if (_cancelled) return;
    _mergeTaken = true;
    if (!_persistedPath.isCompleted) _persistedPath.complete(mangaJsonPath);
    for (final MokuroImage page in payload.images) {
      _enqueue(() => _refineAndPublish(page));
    }
    _enqueue(() async => _finish());
  }

  @override
  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    _refiner.cancel();
    _finish();
  }

  void _finish() {
    if (!_persistedPath.isCompleted) _persistedPath.complete(null);
    if (!_done.isCompleted) _done.complete();
    if (!_updates.isClosed) unawaited(_updates.close());
  }

  void _emit(int pageIndex, MokuroImage page) {
    if (_cancelled || _updates.isClosed) return;
    _updates.add((pageIndex: pageIndex, page: page));
  }

  void _enqueue(Future<void> Function() step) {
    _queue = _queue.then((_) async {
      if (_cancelled) return;
      try {
        await _prepare();
        if (_cancelled) return;
        await step();
      } on Object catch (error, stack) {
        _logOnce(error, stack);
      }
    });
  }

  Future<void> _prepare() async {
    if (_prepared) return;
    _prepared = true;
    if (discardCache) await _cache.clear();
  }

  /// 已重读过、且仍对应 [page] 这份本地结果的改写页；没有则 null。
  MokuroImage? _betterFor(MokuroImage page) {
    final _PageRecord? record = _records[page.url];
    if (record == null || record.better == null) return null;
    return record.base == _signature(page) ? record.better : null;
  }

  /// [page] 已处理过：它就是送去重读的那份本地页，或就是重读后的结果。
  bool _handled(MokuroImage page) {
    final _PageRecord? record = _records[page.url];
    if (record == null) return false;
    final String signature = _signature(page);
    return record.base == signature || record.result == signature;
  }

  /// 送一页去重读；没换成任何块返回 null。
  Future<MokuroImage?> _refine(MokuroImage page) async {
    if (_handled(page)) return null;
    final File? file = (_pageFiles ??= <String, File>{
      for (final MangaOcrPageFile entry in enumerateMangaPages(
        Directory(imageDirPath),
      ))
        entry.relativeUrl: entry.file,
    })[page.url];
    if (file == null) return null;
    final Uint8List bytes = await file.readAsBytes();
    if (_cancelled) return null;
    final ({MokuroImage page, MangaAiOcrPageStats stats}) result =
        await _refiner.refinePage(page, bytes, cache: _cache);
    final String? failure = result.stats.failure;
    if (failure != null) {
      _logOnce(AiChatFailure(failure), StackTrace.current);
    }
    final MokuroImage? better = result.stats.replaced == 0 || _cancelled
        ? null
        : result.page;
    _records[page.url] = (
      base: _signature(page),
      result: better == null ? null : _signature(better),
      better: better,
    );
    return better;
  }

  /// 重读一页并交出去：finished 落盘前改好的直接补发（[mergeInto] 会把它并进
  /// 整卷结果）；落盘之后改好的先在写锁里核对盘上仍是这份本地页、替换落盘，再
  /// 按它在盘上的序号补发。[pageIndex] 是任务进度给的页号（落盘后的页为 null）。
  Future<void> _refineAndPublish(MokuroImage page, {int? pageIndex}) async {
    final MokuroImage? better = await _refine(page);
    if (better == null || _cancelled) return;
    if (!_mergeTaken) {
      if (pageIndex != null) _emit(pageIndex, better);
      return;
    }
    final String? mangaJsonPath = await _persistedPath.future;
    if (mangaJsonPath == null || _cancelled) return;
    final int? index = await _writeIfUnchanged(mangaJsonPath, page, better);
    if (index != null) _emit(index, better);
  }

  /// 读改写书根 manga.json：盘上 [local] 那页没变才换成 [better]，返回它的序号。
  Future<int?> _writeIfUnchanged(
    String mangaJsonPath,
    MokuroImage local,
    MokuroImage better,
  ) {
    final String base = _signature(local);
    return runExclusiveOnMangaJson<int?>(mangaJsonPath, () async {
      if (_cancelled) return null;
      final File file = File(mangaJsonPath);
      if (!await file.exists()) return null;
      final MokuroPayload current = parseMangaJson(await file.readAsString());
      final int index = current.images.indexWhere(
        (MokuroImage image) => image.url == local.url,
      );
      if (index < 0 || _signature(current.images[index]) != base) return null;
      final List<MokuroImage> images = List<MokuroImage>.of(current.images);
      images[index] = better;
      await writeMangaJsonAtomically(
        mangaJsonPath,
        MokuroPayload(images: images, ocr: current.ocr),
      );
      return index;
    });
  }

  void _logOnce(Object error, StackTrace stack) {
    if (_loggedFailure) return;
    _loggedFailure = true;
    ErrorLogService.instance.log('MangaAiOcr.refinePage', error, stack);
  }
}

/// 一页的内容签名（url + 尺寸 + 全部块）：判断「盘上这页是不是我们重读的那份」。
String _signature(MokuroImage page) =>
    jsonEncode(mangaPayloadToJson(MokuroPayload(images: <MokuroImage>[page])));

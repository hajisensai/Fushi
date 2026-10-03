/// 在线直读章的「边看边识别」：从读者当前页起逐页识别，识别完一页就热替换一页。
///
/// 整卷任务（`startMangaReaderVolumeOcr`）要一个章目录来读页图、写 manga.json，
/// 直读章没有——页图只在直读会话的临时目录里按需落盘，章读完会话一关就删。以前
/// 这里干脆什么都不做（设计稿 2026-09-12 §1.2），而在线源正是手机上的主要读法，
/// 于是手机上看在线漫画只能「先下载、再等整章识别完」。
///
/// 这里改走页级入口：本地 ONNX 用常驻页会话（[MangaOcrPageService.openPageSession]，
/// 推理会话只建一次），Lens / 系统 OCR 直接识别单页字节。只识别读者眼前这页与
/// 后面 [kMangaStreamOcrLookahead] 页，不替读者把整章都传上去 / 算一遍；结果
/// 只活在本次会话里（和直读页图同生命周期），想留住就下载这一章。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/manga_ocr_engine_probe.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_ocr_service.dart'
    show GoogleLensMangaOcrRunner;
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/system_ocr_manga_service.dart'
    show SystemOcrMangaRunner;
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/manga_ai_ocr_refiner.dart';
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';

/// 读者当前页之后还要预先识别几页（双页展开时第二页也在眼前）。
const int kMangaStreamOcrLookahead = 2;

/// 识别一张已落盘的直读页图。
abstract interface class MangaStreamPageRecognizer {
  Future<MokuroImage> recognize(File pageFile);

  /// 释放常驻资源（本地 ONNX 的页会话 isolate）；幂等。
  Future<void> close();
}

/// [prepareMangaStreamOcr] 的结局。
sealed class MangaStreamOcrSetup {
  const MangaStreamOcrSetup();
}

final class MangaStreamOcrReady extends MangaStreamOcrSetup {
  const MangaStreamOcrReady(this.engine, this.recognizer, {this.ai});

  final MangaOcrEngineId engine;
  final MangaStreamPageRecognizer recognizer;

  /// 设置里开了大模型识别时的第二段（[MangaStreamPageOcr.ai]）；null = 不经大模型。
  final MangaStreamAiRefinement? ai;
}

/// 没有可用引擎（与整卷路径同一判据）。
final class MangaStreamOcrNoEngine extends MangaStreamOcrSetup {
  const MangaStreamOcrNoEngine();
}

/// 解析到 Google Lens，但用户没同意上传。
final class MangaStreamOcrLensDeclined extends MangaStreamOcrSetup {
  const MangaStreamOcrLensDeclined();
}

/// 解析到的引擎只会整卷跑（外部 mokuro CLI / 已配对主机）：直读章不识别，
/// 下载后照常由整卷任务处理。
final class MangaStreamOcrUnsupported extends MangaStreamOcrSetup {
  const MangaStreamOcrUnsupported();
}

/// 为一个直读会话解析引擎并建好单页识别器。
///
/// 引擎解析与整卷路径（`startMangaReaderVolumeOcr`）同一口径：用户在场，Lens
/// 可用但先过上传同意闸门。[imageDirPath] 是直读会话的页图目录，本地 ONNX 的
/// 页会话在它下面写逐页缓存（随会话目录一起删）。
Future<MangaStreamOcrSetup> prepareMangaStreamOcr({
  required String imageDirPath,
  required MangaOcrWizardEngines engines,
  required MangaOcrEnginePreference preference,
  required String lensLanguage,
  required Future<bool> Function() confirmLensUpload,
}) async {
  final MangaOcrEngineAvailability availability = await probeMangaOcrEngines(
    engines,
  );
  final MangaOcrEngineId? engine = resolveMangaOcrEngine(
    preference: preference,
    hasExistingMetadata: false,
    capabilities: availability.capabilities,
  );
  if (engine == null || !availability.isUsable(engine)) {
    return const MangaStreamOcrNoEngine();
  }
  final MangaStreamOcrSetup setup = await _prepareEngine(
    engine,
    imageDirPath: imageDirPath,
    engines: engines,
    lensLanguage: lensLanguage,
    confirmLensUpload: confirmLensUpload,
  );
  if (setup is! MangaStreamOcrReady) return setup;
  final MangaAiOcrRefiner? refiner = engines.aiRefinerFactory?.call();
  if (refiner == null) return setup;
  return MangaStreamOcrReady(
    setup.engine,
    setup.recognizer,
    ai: MangaStreamAiRefinement(
      refiner: refiner,
      cache: MangaAiOcrCache.forVolume(imageDirPath, refiner.provider),
    ),
  );
}

Future<MangaStreamOcrSetup> _prepareEngine(
  MangaOcrEngineId engine, {
  required String imageDirPath,
  required MangaOcrWizardEngines engines,
  required String lensLanguage,
  required Future<bool> Function() confirmLensUpload,
}) async {
  switch (engine) {
    case MangaOcrEngineId.localOnnx:
      final MangaOcrService service = engines.service;
      if (service is! MangaOcrPageService) {
        return const MangaStreamOcrUnsupported();
      }
      return MangaStreamOcrReady(
        engine,
        LocalMangaStreamPageRecognizer(
          service: service as MangaOcrPageService,
          imageDirPath: imageDirPath,
        ),
      );
    case MangaOcrEngineId.googleLens:
      final GoogleLensMangaOcrRunner? lens = engines.lensRunner;
      if (lens == null) return const MangaStreamOcrNoEngine();
      if (!await confirmLensUpload()) return const MangaStreamOcrLensDeclined();
      return MangaStreamOcrReady(
        engine,
        BytesMangaStreamPageRecognizer(
          (Uint8List bytes, String relativeUrl) => lens.recognizePageBytes(
            bytes,
            relativeUrl: relativeUrl,
            language: lensLanguage,
          ),
        ),
      );
    case MangaOcrEngineId.systemOcr:
      final SystemOcrMangaRunner? system = engines.systemOcrRunner;
      if (system == null) return const MangaStreamOcrNoEngine();
      return MangaStreamOcrReady(
        engine,
        BytesMangaStreamPageRecognizer(
          (Uint8List bytes, String relativeUrl) => system.recognizePageBytes(
            bytes,
            relativeUrl: relativeUrl,
            language: lensLanguage,
          ),
        ),
      );
    case MangaOcrEngineId.externalMokuro:
    case MangaOcrEngineId.pairedHost:
      return const MangaStreamOcrUnsupported();
  }
}

/// 本地 ONNX：首次识别时开一个常驻页会话（几百 MB 模型只加载一次），之后逐页
/// 复用；结果从会话写好的逐页缓存读回。
class LocalMangaStreamPageRecognizer implements MangaStreamPageRecognizer {
  LocalMangaStreamPageRecognizer({
    required MangaOcrPageService service,
    required this.imageDirPath,
  }) : _service = service;

  final MangaOcrPageService _service;
  final String imageDirPath;
  Future<MangaOcrPageSession>? _session;
  bool _closed = false;

  @override
  Future<MokuroImage> recognize(File pageFile) async {
    if (_closed) throw StateError('stream OCR recognizer is closed');
    final MangaOcrPageSession session = await (_session ??= _service
        .openPageSession(imageDirPath: imageDirPath));
    final String relativeUrl = normalizeMangaUrl(
      p.relative(pageFile.path, from: imageDirPath),
    );
    final String cacheDir = await session.ocrPage(relativeUrl);
    final OcrPageResult? result = await MangaOcrFilePageCache(
      cacheDir: Directory(cacheDir),
      pageNames: <String>[relativeUrl],
      pageFiles: <File>[pageFile],
    ).read('manga_ocr', 0);
    if (result == null) {
      throw StateError('OCR page cache missing for $relativeUrl');
    }
    return buildMangaPayloadFromResults(
      <MangaOcrPageFile>[
        MangaOcrPageFile(file: pageFile, relativeUrl: relativeUrl),
      ],
      <OcrPageResult>[result],
    ).images.single;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final Future<MangaOcrPageSession>? session = _session;
    _session = null;
    if (session == null) return;
    try {
      await (await session).close();
    } on Object {
      // 会话根本没建起来（模型缺失等）：没有资源要放。
    }
  }
}

/// 直读章的大模型第二段：本地结果已经交给读者之后，再把该页的块交给
/// [MangaAiOcrRefiner] 重读。
///
/// 不套在识别器里：那样本地结果要等大模型全部批次（每批最长 90 秒、可重试错误
/// 还会继续下一批）才交出，读者眼前这页长时间没有文字层，后面的页也一起排队。
class MangaStreamAiRefinement {
  MangaStreamAiRefinement({
    required MangaAiOcrRefiner refiner,
    MangaAiOcrCache? cache,
  }) : _refiner = refiner,
       _cache = cache;

  final MangaAiOcrRefiner _refiner;
  final MangaAiOcrCache? _cache;

  /// 重读 [local]；没换成任何块（含失败、已取消）返回 null，读者保留本地结果。
  Future<MokuroImage?> refine(MokuroImage local, File pageFile) async {
    final Uint8List bytes = await pageFile.readAsBytes();
    final ({MokuroImage page, MangaAiOcrPageStats stats}) result =
        await _refiner.refinePage(local, bytes, cache: _cache);
    return result.stats.replaced == 0 ? null : result.page;
  }

  /// 中止在途请求，此后不再发请求。
  void cancel() => _refiner.cancel();
}

/// Lens / 系统 OCR：读出页图字节直接识别，没有常驻资源。
class BytesMangaStreamPageRecognizer implements MangaStreamPageRecognizer {
  BytesMangaStreamPageRecognizer(this._recognize);

  final Future<MokuroImage> Function(Uint8List bytes, String relativeUrl)
  _recognize;

  @override
  Future<MokuroImage> recognize(File pageFile) async =>
      _recognize(await pageFile.readAsBytes(), p.basename(pageFile.path));

  @override
  Future<void> close() async {}
}

/// 直读章的逐页识别调度：串行、只看读者眼前这一段。
///
/// 每次 [focus] 把窗口挪到读者当前页 `[page, page + lookahead]`；空闲时取窗口里
/// 第一个还没识别的页，取页图（[pageFile]，直读会话按需前台取）→ 识别 → 交给
/// [onPage]。一次只跑一页：手机上识别本身就是瓶颈，并发只会拖慢眼前这页。读者
/// 翻走后窗口跟着走，旧窗口里没轮到的页不再识别（翻回来时再补）。
///
/// 有 [ai] 时是两段式（与整卷任务的跟随步骤同形）：本地结果照常立刻 [onPage]，
/// 同时把该页排进一条**页级顺序**的大模型队列；重读回来后对同一页再 [onPage]
/// 一次。大模型队列与本地识别互不阻塞——慢的是网络，不该拖住下一页的本地识别。
/// [close] 丢弃队列里没轮到的页并中止在途请求，之后不再回调。
class MangaStreamPageOcr {
  MangaStreamPageOcr({
    required this.pageCount,
    required this.pageFile,
    required MangaStreamPageRecognizer recognizer,
    required this.onPage,
    this.onBusyChanged,
    this.onError,
    this.onAiError,
    this.lookahead = kMangaStreamOcrLookahead,
    this.ai,
  }) : _recognizer = recognizer;

  final int pageCount;
  final Future<File?> Function(int pageIndex) pageFile;
  final MangaStreamPageRecognizer _recognizer;
  final void Function(int pageIndex, MokuroImage page) onPage;
  final void Function(bool busy)? onBusyChanged;
  final void Function(Object error, StackTrace stack)? onError;

  /// 大模型第二段的失败（只用于记日志；本地结果不受影响）。
  final void Function(Object error, StackTrace stack)? onAiError;
  final int lookahead;

  /// 大模型第二段；null = 只用本地结果。
  final MangaStreamAiRefinement? ai;

  final Set<int> _done = <int>{};

  /// 大模型的页级顺序队列（链尾）。
  Future<void> _aiQueue = Future<void>.value();

  /// 这一轮窗口里失败过的页：不在原地反复重试（离线 / 源坏了会刷满日志），
  /// 读者重新翻到它时再给一次机会。
  final Set<int> _failed = <int>{};
  int _focus = -1;
  bool _running = false;
  bool _closed = false;

  bool get isBusy => _running;

  /// 读者翻到了 [pageIndex]。
  void focus(int pageIndex) {
    if (_closed || pageCount <= 0) return;
    final int page = pageIndex.clamp(0, pageCount - 1);
    if (page != _focus) _failed.remove(page);
    _focus = page;
    _pump();
  }

  /// 停止调度并释放识别器。在跑的那页结果会被丢弃；大模型队列里没轮到的页
  /// 不再送，在途请求被中止。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    ai?.cancel();
    await _recognizer.close();
  }

  /// 本地结果已交出：把该页排进大模型队列，读完对同一页再交一次。
  void _enqueueAi(int pageIndex, MokuroImage local, File file) {
    final MangaStreamAiRefinement? stage = ai;
    if (stage == null) return;
    _aiQueue = _aiQueue.then((_) async {
      if (_closed) return;
      try {
        final MokuroImage? better = await stage.refine(local, file);
        if (better == null || _closed) return;
        onPage(pageIndex, better);
      } on Object catch (error, stack) {
        // 大模型失败只是少了一次改进，读者手里的本地结果照常可用；不打扰读者，
        // 只记日志（与整卷任务的跟随步骤同一口径）。
        if (!_closed) onAiError?.call(error, stack);
      }
    });
  }

  int? _nextPage() {
    if (_focus < 0) return null;
    final int last = (_focus + lookahead).clamp(0, pageCount - 1);
    for (int page = _focus; page <= last; page++) {
      if (!_done.contains(page) && !_failed.contains(page)) return page;
    }
    return null;
  }

  void _pump() {
    if (_running || _closed) return;
    final int? page = _nextPage();
    if (page == null) return;
    _running = true;
    onBusyChanged?.call(true);
    unawaited(_run(page));
  }

  Future<void> _run(int pageIndex) async {
    try {
      final File? file = await pageFile(pageIndex);
      if (_closed) return;
      if (file == null) {
        _failed.add(pageIndex);
        return;
      }
      final MokuroImage page = await _recognizer.recognize(file);
      if (_closed) return;
      _done.add(pageIndex);
      onPage(pageIndex, page);
      _enqueueAi(pageIndex, page, file);
    } on Object catch (error, stack) {
      if (_closed) return;
      _failed.add(pageIndex);
      onError?.call(error, stack);
    } finally {
      _running = false;
      if (!_closed) {
        final bool more = _nextPage() != null;
        if (!more) onBusyChanged?.call(false);
        _pump();
      }
    }
  }
}

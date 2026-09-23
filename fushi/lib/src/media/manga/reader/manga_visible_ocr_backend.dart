import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi/src/media/manga/mihon/manga_page_provider.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_ocr_service.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_protocol.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/system_ocr_manga_service.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';

/// 没有任何可用的页级 OCR 引擎（本地模型未就绪、系统 OCR 不可用，且用户未
/// 显式选择引擎）。页面据此提示用户去下载模型或换引擎，而不是当成运行时故障。
class MangaVisibleOcrEngineUnavailable implements Exception {
  const MangaVisibleOcrEngineUnavailable();

  @override
  String toString() =>
      'MangaVisibleOcrEngineUnavailable: no page OCR engine is ready';
}

/// A reader-owned adapter over the existing engines and their atomic caches.
/// Folder enumeration fixes the cache index identity to match explicit jobs;
/// page bytes are read only through the reader session's validated local file.
class MangaVisibleOcrBackend {
  MangaVisibleOcrBackend({
    required this.directory,
    required this.session,
    required this.service,
    required this.engine,
    required this.language,
    required this.onAcceleration,
  }) : _pages = enumerateMangaPages(Directory(directory));

  final String directory;
  final MangaReaderSession session;
  final MangaOcrService service;
  final MangaOcrEngineId engine;
  final String language;
  final void Function(MangaOcrAcceleration acceleration) onAcceleration;
  final List<MangaOcrPageFile> _pages;
  final HttpGoogleLensTransport _transport = HttpGoogleLensTransport();

  /// 本地 ONNX 常驻页级会话：首个缓存未命中的本地页请求时懒打开，之后所有页
  /// 复用同一个会话（ORT 会话只建一次）；并发请求共用同一个 Future。
  Future<MangaOcrPageSession>? _localSession;

  /// 本地逐页缓存目录。与会话同源（[MangaOcrPageService.resolvePageCacheDirPath]
  /// 与会话 isolate 用的是服务按同一模型目录解析出的同一个签名），所以打开会话
  /// 前就能用它查缓存命中，命中的页完全不用加载模型。
  Future<String>? _localCacheDirPath;
  bool _closed = false;

  /// 解析边看边识别用哪个引擎。
  ///
  /// [userInitiated] 为 false 是自动触发（翻页 / 滚动）。两条边界在这里一次判掉：
  /// - 只支持整卷任务的引擎（外部 mokuro / 已配对主机）没有页级能力，判为不可用
  ///   —— 否则 [recognize] 每个新可见页都抛一次、挂失败胶囊、写一条错误日志。
  /// - 云端引擎（Google Lens）不许自动触发：授权文案同意的是「识别本漫画」这个
  ///   用户动作，翻到哪页就静默上传哪页超出了那份同意；而 Lens 恰是出厂默认引擎，
  ///   不挡的话自动模式开书就弹授权框（拒绝不记忆，每本书每章都弹），同意过整卷
  ///   OCR 的存量用户则翻一页传一页。用户点「识别当前页」才走授权 + 上传。
  static Future<MangaOcrEngineId> resolveEngine(
    MangaOcrEnginePreference preference,
    MangaOcrService service, {
    required bool userInitiated,
  }) async {
    final MangaOcrEngineId? explicit = preference.explicitEngine;
    if (explicit != null) {
      if (explicit == MangaOcrEngineId.externalMokuro ||
          explicit == MangaOcrEngineId.pairedHost) {
        throw const MangaVisibleOcrEngineUnavailable();
      }
      if (explicit == MangaOcrEngineId.googleLens && !userInitiated) {
        throw const MangaVisibleOcrEngineUnavailable();
      }
      return explicit;
    }
    if (service is MangaOcrPageService &&
        service.isSupportedPlatform &&
        (await service.modelStatus()).allReady) {
      return MangaOcrEngineId.localOnnx;
    }
    if (await const MethodChannelSystemOcr().isAvailable()) {
      return MangaOcrEngineId.systemOcr;
    }
    throw const MangaVisibleOcrEngineUnavailable();
  }

  Future<MokuroImage> recognize(int pageIndex) async {
    if (_closed) throw StateError('Reader OCR closed');
    final File? file = await session.localFile(pageIndex);
    if (file == null) throw StateError('Page image unavailable');
    final String url = normalizeMangaUrl(
      p.relative(file.path, from: directory),
    );
    final int cacheIndex = _pages.indexWhere(
      (MangaOcrPageFile page) => page.relativeUrl == url,
    );
    if (cacheIndex < 0) throw StateError('Page is outside OCR source manifest');
    final MangaOcrPageFile pageFile = _pages[cacheIndex];
    if (engine == MangaOcrEngineId.localOnnx) {
      final MangaOcrService local = service;
      if (local is! MangaOcrPageService) {
        throw UnsupportedError('Local engine has no page OCR capability');
      }
      final MangaOcrPageService pageService = local as MangaOcrPageService;
      OcrPageResult? result = await _localCache(
        await _resolveLocalCacheDirPath(pageService),
      ).read('manga_ocr', cacheIndex);
      if (result == null) {
        if (_closed) throw StateError('Reader OCR closed');
        final MangaOcrPageSession pageSession = await _openLocalSession(
          pageService,
        );
        if (_closed) throw StateError('Reader OCR closed');
        // 会话返回的就是它实际写入的目录；以它为准读回，天然不会与写入分叉。
        final String cacheDirPath = await pageSession.ocrPage(url);
        result = await _localCache(cacheDirPath).read('manga_ocr', cacheIndex);
      }
      if (result == null) throw StateError('OCR produced no page cache');
      return buildMangaPayloadFromResults(
        <MangaOcrPageFile>[pageFile],
        <OcrPageResult>[result],
      ).images.single;
    }
    if (engine != MangaOcrEngineId.googleLens &&
        engine != MangaOcrEngineId.systemOcr) {
      throw UnsupportedError('This engine only supports explicit volume OCR');
    }
    final String signature = engine == MangaOcrEngineId.googleLens
        ? googleLensEngineSignature(language)
        : systemOcrEngineSignature(language);
    final GoogleLensPageCache cache = GoogleLensPageCache(
      Directory(
        p.join(
          directory,
          kMangaOcrOutDirName,
          kMangaOcrPagesCacheDirName,
          signature,
        ),
      ),
    );
    final MokuroImage? cached = await cache.read(cacheIndex, pageFile);
    if (cached != null) return cached;
    if (_closed) throw StateError('Reader OCR closed');
    final MokuroImage result;
    if (engine == MangaOcrEngineId.googleLens) {
      result = await GoogleLensMangaOcrService(transport: _transport)
          .recognizePageBytes(
            await file.readAsBytes(),
            relativeUrl: url,
            language: language,
          );
    } else {
      final SystemOcrPageResult system = await const MethodChannelSystemOcr()
          .recognize(await file.readAsBytes(), language: language)
          .timeout(kSystemOcrPageTimeout);
      result = buildSystemOcrPage(url, system);
    }
    // A completed page remains reusable even if the user turned it meanwhile.
    await cache.write(cacheIndex, pageFile, result);
    return result;
  }

  MangaOcrFilePageCache _localCache(String cacheDirPath) =>
      MangaOcrFilePageCache(
        cacheDir: Directory(cacheDirPath),
        pageNames: _pages
            .map((MangaOcrPageFile page) => page.relativeUrl)
            .toList(),
        pageFiles: _pages.map((MangaOcrPageFile page) => page.file).toList(),
      );

  Future<String> _resolveLocalCacheDirPath(MangaOcrPageService pageService) {
    final Future<String>? existing = _localCacheDirPath;
    if (existing != null) return existing;
    final Future<String> resolving = pageService.resolvePageCacheDirPath(
      imageDirPath: directory,
    );
    _localCacheDirPath = resolving;
    // 解析失败不记忆：下一页请求重新解析。
    resolving.then<void>(
      (String _) {},
      onError: (Object _) {
        if (identical(_localCacheDirPath, resolving)) {
          _localCacheDirPath = null;
        }
      },
    );
    return resolving;
  }

  Future<MangaOcrPageSession> _openLocalSession(
    MangaOcrPageService pageService,
  ) {
    final Future<MangaOcrPageSession>? existing = _localSession;
    if (existing != null) return existing;
    final Future<MangaOcrPageSession> opening = pageService.openPageSession(
      imageDirPath: directory,
      onAcceleration: (MangaOcrAcceleration acceleration) {
        if (!_closed) onAcceleration(acceleration);
      },
    );
    _localSession = opening;
    // 打开失败（模型被删 / 平台闸门）不记忆：下一页请求重新尝试打开。
    opening.then<void>(
      (MangaOcrPageSession _) {},
      onError: (Object _) {
        if (identical(_localSession, opening)) _localSession = null;
      },
    );
    return opening;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _transport.close();
    final Future<MangaOcrPageSession>? session = _localSession;
    _localSession = null;
    if (session != null) {
      // 会话可能还在打开中：等它到手再关；关闭会让在跑/挂起的页以错误结束，
      // 并释放 isolate 与 ORT 会话。打开失败时无物可关。
      unawaited(
        session.then<void>(
          (MangaOcrPageSession opened) => opened.close(),
          onError: (Object _) {},
        ),
      );
    }
  }
}

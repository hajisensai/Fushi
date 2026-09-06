/// 漫画 OCR 模型下载器：共享 [ModelFileDownloader] 的薄适配。
///
/// `.part` 临时名 + 原子 rename、HTTP Range 断点续传、主源失败换镜像、系统代理、
/// 进度节流——全部住在 `lib/src/onnx/model_file_downloader.dart`（OCR / ASR 共用）；
/// 本文件只做两件事：把清单里的 [MangaOcrModelFile] 交给共享下载器、把共享的
/// `ModelDownloadEvent` 转成 OCR 接口面上的 [MangaOcrDownloadEvent]。构造签名与
/// `downloadAll` 契约原样保留，`MangaOcrServiceImpl` 与既有测试零改动。
library;

import 'dart:io';

import 'package:fushi/src/ocr/manga_ocr_model_manifest.dart';
import 'package:fushi/src/ocr/manga_ocr_service.dart';
import 'package:fushi/src/onnx/model_file_downloader.dart';

/// 默认进度事件的字节间隔（与共享下载器同值）。
const int kMangaOcrDownloadProgressInterval = kModelDownloadProgressInterval;

/// 模型下载器。[createClient] 可注入（测试指向本地 HttpServer）。
class MangaOcrModelDownloader {
  MangaOcrModelDownloader({
    HttpClient Function()? createClient,
    List<String> Function(MangaOcrModelFile file)? urlCandidates,
    int progressByteInterval = kMangaOcrDownloadProgressInterval,
  }) : _inner = ModelFileDownloader(
          createClient: createClient,
          urlCandidates: _adaptUrlCandidates(urlCandidates),
          progressByteInterval: progressByteInterval,
        );

  final ModelFileDownloader _inner;

  /// 两次进度事件之间至少累积的字节数（首尾事件恒发）。
  int get progressByteInterval => _inner.progressByteInterval;

  /// 把 OCR 类型的候选函数适配成共享层签名。传入的 [MangaOcrModelFile] 经
  /// `downloadAll` 的 `List<MangaOcrModelFile>` 进来，所以这里的向下转型是
  /// 结构上保证成立的，不是猜。不注入时用清单默认的
  /// [mangaOcrModelUrlCandidates]（主源 + hf-mirror）。
  static List<String> Function(DownloadableModelFile file) _adaptUrlCandidates(
    List<String> Function(MangaOcrModelFile file)? urlCandidates,
  ) {
    final List<String> Function(MangaOcrModelFile file) candidates =
        urlCandidates ?? mangaOcrModelUrlCandidates;
    return (DownloadableModelFile file) =>
        candidates(file as MangaOcrModelFile);
  }

  /// 下载清单里所有未就绪文件到 [targetDir]（契约见共享层
  /// [ModelFileDownloader.downloadAll]；就绪判定用 [isMangaOcrModelFileReady]）。
  Stream<MangaOcrDownloadEvent> downloadAll({
    required List<MangaOcrModelFile> files,
    required Directory targetDir,
  }) {
    return _inner
        .downloadAll(
          files: files,
          targetDir: targetDir,
          isReady: isMangaOcrModelFileReady,
        )
        .map(
          (ModelDownloadEvent event) => MangaOcrDownloadEvent(
            fileName: event.fileName,
            receivedBytes: event.receivedBytes,
            totalBytes: event.totalBytes,
            done: event.done,
          ),
        );
  }
}

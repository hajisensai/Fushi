import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/download/manga_download_service.dart';
import 'package:fushi/src/utils/misc/fushi_byte_format.dart';

/// 漫画下载任务进度的展示文案（下载中心任务行 / mokuro.moe 卷列表共用）。
///
/// 按 [MangaDownloadProgress] 的单位选文案：字节 →「下载中 4.5 MB/29.9 MB」，
/// 页 →「第 3 / 10 页」。页总数还不知道（0）时返回 null，由调用方给占位。
String? mangaDownloadProgressLabel(MangaDownloadProgress progress) =>
    switch (progress) {
      MangaDownloadByteProgress(:final int received, :final int? total) =>
        t.manga_chapter_download_status_downloading(
          done: FushiByteFormat.bytes(received),
          total: FushiByteFormat.bytes(total),
        ),
      MangaDownloadPageProgress(:final int done, :final int total) =>
        total > 0
            ? t.manga_ocr_wizard_page_progress(done: done, total: total)
            : null,
    };

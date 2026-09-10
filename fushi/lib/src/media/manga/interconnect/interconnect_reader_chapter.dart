import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/mihon/manga_page_provider.dart';
import 'package:fushi/src/media/manga/mihon/mihon_reader_chapter.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 对端一卷漫画，交给本仓共享的漫画阅读器。
///
/// 因为走的是同一个 [OnlineMangaReaderChapter] 契约，在线读对端漫画与读 Mihon /
/// Aidoku 源共用 OCR、查词制卡、跨页/条漫版式、缩放、快捷键、统计与进度——本类
/// 不含任何阅读 UI。
class InterconnectReaderChapter extends OnlineMangaReaderChapter {
  const InterconnectReaderChapter({
    required this.backend,
    required this.bookKey,
    required this.title,
    required this.pages,
    required this.managedDirectory,
    required this.persistProgress,
    this.initialPage,
  });

  final InterconnectSyncBackend backend;

  /// 对端 `epub_books.bookKey`，也是页图端点的路径段。
  final String bookKey;

  @override
  final String title;

  final List<RemoteMangaPageInfo> pages;

  @override
  final Directory managedDirectory;

  @override
  final bool persistProgress;

  @override
  final int? initialPage;

  /// 对端库里的漫画没有「源语言」这一维（那是扩展源 manifest 的概念），返回 null 让
  /// 消费方回退用户偏好——Lens OCR 本来就这么兜底。
  @override
  String? get sourceLanguage => null;

  @override
  String? get author => null;

  @override
  int get pageCount => pages.length;

  /// 页缓存身份。
  ///
  /// 掺进 [InterconnectSyncBackend.coverCacheNamespace]（配对凭据哈希）而不是对端
  /// 地址：换 IP 不该让整卷缓存作废，换对端则必须——两台机器上同名同页序的书不是
  /// 同一份内容，共用缓存会让另一台的页图串味显示。
  @override
  List<String> get pageIdentities => <String>[
        for (final RemoteMangaPageInfo page in pages)
          sha256
              .convert(
                utf8.encode(
                  <String>[
                    backend.coverCacheNamespace,
                    bookKey,
                    '${page.index}',
                    page.name,
                  ].join(''),
                ),
              )
              .toString(),
      ];

  @override
  String get identityFileName => '.interconnect-chapter.json';

  @override
  Future<MangaReaderSession> openPageSession() => InterconnectMangaPageProvider(
        backend: backend,
        bookKey: bookKey,
        pages: pages,
        identities: pageIdentities,
        cacheRoot: Directory(p.join(managedDirectory.path, 'page-cache')),
      ).open();
}

/// 逐页向对端要图，落一份磁盘缓存。
///
/// 与 Aidoku 那条 HTTP 取图路径同构，但**不自己造 HTTP client**：互联对端可能是自签
/// 证书 + TOFU 指纹钉扎，只有 [InterconnectSyncBackend] 手上那条会话带得动
/// `badCertificateCallback` 与 Basic 凭据。裸 `http.Client` 在钉扎对端上必然握手失败。
class InterconnectMangaPageProvider implements MangaPageProvider {
  const InterconnectMangaPageProvider({
    required this.backend,
    required this.bookKey,
    required this.pages,
    required this.identities,
    required this.cacheRoot,
  });

  final InterconnectSyncBackend backend;
  final String bookKey;
  final List<RemoteMangaPageInfo> pages;
  final List<String> identities;
  final Directory cacheRoot;

  @override
  Future<MangaReaderSession> open() async {
    await cacheRoot.create(recursive: true);
    return _InterconnectMangaReaderSession(
      backend: backend,
      bookKey: bookKey,
      pages: pages,
      identities: identities,
      cacheRoot: cacheRoot,
    );
  }
}

class _InterconnectMangaReaderSession implements MangaReaderSession {
  _InterconnectMangaReaderSession({
    required this.backend,
    required this.bookKey,
    required this.pages,
    required this.identities,
    required this.cacheRoot,
  });

  final InterconnectSyncBackend backend;
  final String bookKey;
  final List<RemoteMangaPageInfo> pages;
  final List<String> identities;
  final Directory cacheRoot;

  /// 同一页的并发请求合并成一次下载（翻页 + 预取会同时点到同一页）。
  final Map<int, Future<File>> _inFlight = <int, Future<File>>{};
  bool _closed = false;

  @override
  int get pageCount => pages.length;

  @override
  Future<MangaPageBytes> page(int index) async {
    final File file = await _file(index);
    final Uint8List bytes = await file.readAsBytes();
    final ({int width, int height})? dimensions = await mangaImageDimensions(
      bytes,
    );
    return MangaPageBytes(
      bytes: bytes,
      contentType: mangaImageContentType(bytes),
      // 尺寸以**真实字节**为准，页表里对端报的尺寸只在解不出来时兜底：mokuro 的
      // 尺寸是 OCR 生产者报告的，与磁盘上的图未必逐像素一致，而 OCR 命中区判定
      // 用的就是这个尺寸，取错会让整页文本框整体偏移。
      width: dimensions?.width ?? _page(index).width,
      height: dimensions?.height ?? _page(index).height,
    );
  }

  @override
  Future<File?> localFile(int index) => _file(index);

  @override
  String cacheIdentity(int index) => identities[index];

  @override
  Future<void> prefetchAround(int index) async {
    final List<Future<File>> work = <Future<File>>[];
    for (int candidate = index - 2; candidate <= index + 2; candidate++) {
      if (candidate >= 0 && candidate < pages.length && candidate != index) {
        work.add(_file(candidate));
      }
    }
    // 预取失败绝不能冒泡：它是后台预热，把它变成异常等于让相邻页的网络抖动打断
    // 当前这一页的正常阅读。
    await Future.wait<void>(
      work.map(
        (Future<File> future) => future.then<void>((File _) {},
            onError: (
              Object error,
              StackTrace stack,
            ) {}),
      ),
    );
  }

  RemoteMangaPageInfo _page(int index) {
    if (_closed) {
      throw StateError('The interconnect manga reader session is closed');
    }
    if (index < 0 || index >= pages.length) {
      throw RangeError.index(index, pages, 'index');
    }
    return pages[index];
  }

  Future<File> _file(int index) {
    _page(index);
    return _inFlight.putIfAbsent(index, () async {
      try {
        final File target = File(
          p.join(cacheRoot.path, '${identities[index]}.img'),
        );
        if (await target.exists() && await target.length() > 0) return target;
        final Uint8List bytes = await backend.fetchRemoteMangaPage(
          bookKey,
          pages[index].index,
        );
        if (bytes.isEmpty) {
          throw StateError(
              'Peer returned an empty manga page: $bookKey#$index');
        }
        // 先写 .tmp 再 rename：半截文件被下一次 `exists && length > 0` 当成有效缓存
        // 就是一页永久坏图（与 Mihon / Aidoku 两条缓存路径同一纪律）。
        final File staged = File('${target.path}.tmp');
        await staged.writeAsBytes(bytes, flush: true);
        await staged.rename(target.path);
        return target;
      } on Object catch (error, stack) {
        ErrorLogService.instance.log(
          'InterconnectReader.page[$index] $bookKey',
          error,
          stack,
        );
        rethrow;
      } finally {
        _inFlight.remove(index);
      }
    });
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}

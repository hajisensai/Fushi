import 'dart:io';

import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/mihon/mihon_reader_chapter.dart';
import 'package:fushi/src/media/manga/interconnect/interconnect_reader_chapter.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';

/// 互联漫画源里的一部「作品」。
///
/// 对端的漫画在本仓是 `EpubBooks` 里 `format=='manga'` 的一行，**一本 = 一卷**、卷内
/// 无章节结构。所以这里一部作品 = 对端的一本，其唯一一章就是整卷；这与 mokuro 那套
/// 「一卷一个 `.mokuro`」的现实一致，不为了凑「多章」去猜卷号。
///
/// 清单不新开端点：漫画本来就在 `/api/library/books` 里带 `format=='manga'` +
/// `hasMangaContent` 出现（那两个 additive 字段是互联漫画包批次留下的）。
class InterconnectMangaCatalog {
  const InterconnectMangaCatalog(this.backend);

  final InterconnectSyncBackend backend;

  /// 对端库里**有内容可读**的漫画。
  ///
  /// `hasMangaContent` 是 host 侧 `hasExportableMangaContent` 的结论（非空页表 + 每页
  /// 图都在），与页表端点的准入判据同源——所以列出来的每一本都翻得开，不会出现
  /// BUG-2400 那种「清单说有、点开说没有」的占位空合集。
  Future<List<RemoteBookInfo>> listSeries() async {
    final List<RemoteBookInfo> books = await backend.listRemoteBooks();
    return <RemoteBookInfo>[
      for (final RemoteBookInfo book in books)
        if (BookFormat.parseOrEpub(book.format) == BookFormat.manga &&
            book.hasMangaContent)
          book,
    ];
  }

  /// 把一条对端漫画做成书架条目（加入书架 / 直接开读共用同一份身份推导）。
  static OnlineMangaLibraryEntry entryFor(RemoteBookInfo book) {
    // downloadId = bookKey 优先、title 兜底，与 books 端点的路径段取值逐字同源。
    final String seriesKey = book.downloadId;
    return OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.interconnect,
      extensionPackage: kInterconnectMangaPackage,
      sourceId: kInterconnectMangaSourceId,
      series: OnlineMangaSeries(
        key: seriesKey,
        // 身份用 title、展示用 displayName：对端用户改过的名字随清单下发，但永不参与
        // 键推导（BUG-1488 定的身份红线）。
        title: book.displayName,
        coverUrl: book.coverUrl,
        raw: <String, Object?>{
          'bookKey': seriesKey,
          'title': book.title,
          if (book.mangaReadingMode != null)
            'readingMode': book.mangaReadingMode,
        },
      ),
      chapters: <OnlineMangaChapter>[chapterFor(seriesKey)],
    );
  }

  /// 整卷那一章。
  ///
  /// [key] 用对端 bookKey 而不是常量 `'volume'`：`manga_chapter_states` 的主键是
  /// (bookUid, chapterKey)，用书自己的键能保证同一本在任何时候都定位到同一行，也
  /// 免得将来对端真的分出章节时与旧行撞键。
  static OnlineMangaChapter chapterFor(String seriesKey) => OnlineMangaChapter(
        key: seriesKey,
        name: '',
        raw: <String, Object?>{'bookKey': seriesKey},
      );
}

/// 把已配对的互联对端接进书架 / 作品页 / 阅读器的那条契约实现。
///
/// 这是本仓第三个在线漫画运行时（Mihon / Aidoku 之后）。契约本身一行没动——
/// `OnlineMangaRuntimeAdapter` 的类文档说的就是「加第三个运行时不需要动书架、作品页
/// 和阅读器任何一行」，这次兑现了它。
class InterconnectLibraryAdapter implements OnlineMangaRuntimeAdapter {
  const InterconnectLibraryAdapter({InterconnectSyncBackend? backend})
      : _backend = backend;

  final InterconnectSyncBackend? _backend;

  InterconnectSyncBackend get backend =>
      _backend ?? InterconnectSyncBackend.instance;

  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.interconnect;

  /// 五端都可用：互联客户端是纯 Dart HTTP，没有 Mihon 那样的原生宿主门槛，也没有
  /// Aidoku 那样的 Apple 限制。对端在不在线是**运行时**问题（[refresh] 会如实报错），
  /// 不是平台支持问题——把它编码成「本平台不支持」会给出完全错误的出路。
  @override
  bool get isSupportedOnThisPlatform => true;

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async => null;

  @override
  Future<OnlineMangaRefreshResult> refresh(
    OnlineMangaLibraryEntry entry,
  ) async {
    final RemoteMangaManifest manifest = await _manifest(entry, 'details');
    return OnlineMangaRefreshResult(
      series: OnlineMangaSeries(
        key: entry.series.key,
        // 标题以对端**当前**清单为准会多要一次 listRemoteBooks；页表里已经带了
        // 书名，直接用它，空则保留书架上已有的。
        title: manifest.title.isEmpty ? entry.series.title : manifest.title,
        coverUrl: entry.series.coverUrl,
        raw: <String, Object?>{
          ...entry.series.raw,
          if (manifest.readingMode != null) 'readingMode': manifest.readingMode,
        },
      ),
      chapters: <OnlineMangaChapter>[
        InterconnectMangaCatalog.chapterFor(entry.series.key),
      ],
    );
  }

  @override
  Future<OnlineMangaReaderChapter> openChapter({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
    required Directory managedDirectory,
    required bool persistProgress,
    int? initialPage,
  }) async {
    final RemoteMangaManifest manifest = await _manifest(entry, 'pages');
    if (manifest.pages.isEmpty) {
      throw const OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        'The peer returned a manga volume with no pages',
        stage: 'pages',
      );
    }
    return InterconnectReaderChapter(
      backend: backend,
      bookKey: manifest.bookKey.isEmpty ? entry.series.key : manifest.bookKey,
      title: manifest.title.isEmpty ? entry.series.title : manifest.title,
      pages: manifest.pages,
      managedDirectory: managedDirectory,
      persistProgress: persistProgress,
      initialPage: initialPage,
    );
  }

  /// 封面走对端清单里已经带好的绝对 `coverUrl`（host 按 client 实际请求地址回填，
  /// 与指纹钉扎一致），因此复用互联自己的封面通道——**不能**用裸 HTTP：自签证书的
  /// 对端需要 `badCertificateCallback`，普通 client 拿不到。
  @override
  Future<List<int>> fetchCover(
    OnlineMangaLibraryEntry entry,
    String url,
  ) async {
    try {
      return await backend.fetchRemoteCover(url);
    } on Object catch (error) {
      throw OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        '$error',
        cause: error,
        stage: 'cover',
      );
    }
  }

  Future<RemoteMangaManifest> _manifest(
    OnlineMangaLibraryEntry entry,
    String stage,
  ) async {
    try {
      return await backend.remoteMangaManifest(entry.series.key);
    } on MangaInterconnectUnsupported catch (error) {
      // 对端能力缺失 ≠ 这一本坏了：分类成 sourceDisabled，作品页据此引导用户去升级
      // 对端 / 打开对端的库服务，而不是给一个永远不会成功的「重试」。
      throw OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.sourceDisabled,
        '$error',
        cause: error,
        stage: stage,
      );
    } on Object catch (error) {
      throw OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        '$error',
        cause: error,
        stage: stage,
      );
    }
  }
}

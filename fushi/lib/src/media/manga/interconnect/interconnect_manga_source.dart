import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi_engine/media/manga/manga_chapter_storage.dart'
    show mangaChapterDigest;
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';

/// 互联漫画源里的一部「作品」。
///
/// 对端的漫画在本仓是 `EpubBooks` 里 `format=='manga'` 的一行，有两种形状：
///   · **单卷本地漫画**（mokuro 导入）：**一本 = 一卷**、卷内无章节结构，所以一部作品
///     = 对端的一本，其唯一一章就是整卷；与 mokuro 「一卷一个 `.mokuro`」的现实一致，
///     不为了凑「多章」去猜卷号。
///   · **章节式在线漫画**（对端 Mihon / Aidoku 书架条目，BUG-2474）：对端按章下载在
///     自己机器上，章表由页表端点的 `chapters` 给出（只列对端已完整下载的章），每章
///     的 key 与对端逐字相同，目录摘要（`sha256(key)[:24]`）两端自然一致。
///
/// 清单不新开端点：漫画本来就在 `/api/library/books` 里带 `format=='manga'` +
/// `hasMangaContent` / `hasMangaChapters` 出现（三个 additive 字段）。
class InterconnectMangaCatalog {
  const InterconnectMangaCatalog(this.backend);

  final InterconnectSyncBackend backend;

  /// 对端库里**有内容可读**的漫画。
  ///
  /// `hasMangaContent` 是 host 侧 `hasExportableMangaContent` 的结论（非空页表 + 每页
  /// 图都在），`hasMangaChapters` 是「`chapters/` 下至少一章有 `manga.json`」，各与
  /// 自己那条页表端点的准入判据同源——所以列出来的每一本都翻得开，不会出现
  /// BUG-2400 那种「清单说有、点开说没有」的占位空合集。
  Future<List<RemoteBookInfo>> listSeries() async {
    final List<RemoteBookInfo> books = await backend.listRemoteBooks();
    return <RemoteBookInfo>[
      for (final RemoteBookInfo book in books)
        if (isReadableRemoteManga(book)) book,
    ];
  }

  /// 该远端条目是否能经互联漫画源读（单卷有页表，或章节式有已下载的章）。
  ///
  /// 漫画架的远端过滤与本源的清单过滤**共用**这一条，两处判据不会漂开。
  static bool isReadableRemoteManga(RemoteBookInfo book) =>
      BookFormat.parseOrEpub(book.format) == BookFormat.manga &&
      (book.hasMangaContent || book.hasMangaChapters);

  /// 把一条对端漫画做成书架条目（加入书架 / 直接开读共用同一份身份推导）。
  ///
  /// 章节式条目（[RemoteBookInfo.hasMangaChapters]）在这里**没有章**：章表要问页表
  /// 端点，加入书架前先经 [InterconnectLibraryAdapter.refresh] 补全（作品页打开时也
  /// 会刷新）。单卷条目的唯一一章就是整卷。
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
          if (book.collection != null) 'collection': book.collection!.toJson(),
          if (book.mangaReadingMode != null)
            'readingMode': book.mangaReadingMode,
          if (book.hasMangaChapters) 'chaptered': true,
        },
      ),
      chapters: book.hasMangaChapters
          ? const <OnlineMangaChapter>[]
          : <OnlineMangaChapter>[chapterFor(seriesKey)],
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

  /// 对端章表里的一章 → 书架章节。key / name / number / scanlator / uploadedAt 逐字
  /// 透传（对端的 `chaptersJson` 就是这几列），`raw` 只记页数供作品页显示。
  static OnlineMangaChapter chapterFromRemote(RemoteMangaChapterInfo chapter) =>
      OnlineMangaChapter(
        key: chapter.key,
        name: chapter.name,
        number: chapter.number,
        scanlator: chapter.scanlator,
        uploadedAt: chapter.uploadedAt,
        raw: <String, Object?>{'pageCount': chapter.pageCount},
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
    // 章节式（BUG-2474）：章表 = 对端已下载的章，对端每多下一章、这里刷新一次就多
    // 一章；单卷：唯一一章仍是整卷。判据是对端**这次**答了什么，不是书架上记的
    // 形状——对端把一本单卷漫画换成在线条目（或反过来）时刷新即收敛。
    final List<OnlineMangaChapter> chapters = manifest.hasChapters
        ? <OnlineMangaChapter>[
            for (final RemoteMangaChapterInfo chapter in manifest.chapters)
              InterconnectMangaCatalog.chapterFromRemote(chapter),
          ]
        : <OnlineMangaChapter>[
            InterconnectMangaCatalog.chapterFor(entry.series.key),
          ];
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
          'chaptered': manifest.hasChapters,
        },
      ),
      chapters: chapters,
    );
  }

  @override
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) async {
    // 整卷那一章的 key 就是作品 key（[InterconnectMangaCatalog.chapterFor]）；其它
    // key 一律是对端章节式条目的章，按摘要走章端点。
    final bool isVolume = chapter.key == entry.series.key;
    final String? digest = isVolume ? null : mangaChapterDigest(chapter.key);
    final RemoteMangaManifest manifest = digest == null
        ? await _manifest(entry, 'pages')
        : await _chapterManifest(entry, digest);
    if (manifest.pages.isEmpty) {
      throw const OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        'The peer returned a manga chapter with no pages',
        stage: 'pages',
      );
    }
    final String bookKey =
        manifest.bookKey.isEmpty ? entry.series.key : manifest.bookKey;
    return <OnlineMangaPageRef>[
      for (int index = 0; index < manifest.pages.length; index++)
        InterconnectMangaPageRef(
          index: index,
          bookKey: bookKey,
          remoteIndex: manifest.pages[index].index,
          chapterDigest: digest,
        ),
    ];
  }

  /// **不自己造 HTTP client**：互联对端可能是自签证书 + TOFU 指纹钉扎，只有
  /// [InterconnectSyncBackend] 手上那条会话带得动 `badCertificateCallback` 与
  /// Basic 凭据。裸 `http.Client` 在钉扎对端上必然握手失败。
  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) async {
    if (page is! InterconnectMangaPageRef) {
      throw ArgumentError.value(
        page,
        'page',
        'not an interconnect page reference',
      );
    }
    final String? digest = page.chapterDigest;
    final Uint8List bytes = digest == null
        ? await backend.fetchRemoteMangaPage(page.bookKey, page.remoteIndex)
        : await backend.fetchRemoteMangaChapterPage(
            page.bookKey,
            digest,
            page.remoteIndex,
          );
    if (bytes.isEmpty) {
      throw StateError(
        'Peer returned an empty manga page: ${page.bookKey}#${page.index}',
      );
    }
    return bytes;
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
  ) =>
      _guarded(stage, () => backend.remoteMangaManifest(entry.series.key));

  /// 章节式条目某一章的页表。对端没下（或只下了一半）这一章 → 404，但这**不是**
  /// 源不可用：对端下完就有了，所以分类成可重试的 runtimeFailure 而不是
  /// sourceDisabled（作品页对后者渲染「源被禁用」且不给重试）。章端点只会在新
  /// host 上被调用（老 host 不会在 manifest 里给出 chapters），故这里的 404 不可能
  /// 是「对端版本过低」。
  Future<RemoteMangaManifest> _chapterManifest(
    OnlineMangaLibraryEntry entry,
    String digest,
  ) async {
    try {
      return await backend.remoteMangaChapterManifest(entry.series.key, digest);
    } on MangaInterconnectUnsupported catch (error) {
      throw OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        'The peer has not downloaded this chapter yet',
        cause: error,
        stage: 'pages',
      );
    } on Object catch (error) {
      throw OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        '$error',
        cause: error,
        stage: 'pages',
      );
    }
  }

  Future<RemoteMangaManifest> _guarded(
    String stage,
    Future<RemoteMangaManifest> Function() request,
  ) async {
    try {
      return await request();
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

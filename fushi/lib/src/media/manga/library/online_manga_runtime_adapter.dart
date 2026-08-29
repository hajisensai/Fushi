import 'dart:io';

import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/manga/aidoku/aidoku_package_store.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_reader_chapter.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_source_browse_page.dart'
    show aidokuChapterDisplayTitle;
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_reader_chapter.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime_factory.dart';

/// 一条在线漫画书架条目**不可用**的原因。
///
/// 分类而不是一句 message：作品页要据此决定给哪种出路——源被禁用要引导去
/// 「来源」页启用，平台不支持要直说「这个源在本平台不可用」而不是让用户对着
/// 「加载失败 + 重试」按钮反复重试一个永远不会成功的操作。
enum OnlineMangaUnavailableReason {
  /// 扩展/包已卸载或被停用。
  sourceDisabled,

  /// 该运行时在本平台根本不存在（Aidoku 只在 macOS/iOS）。
  platformUnsupported,

  /// 运行时在，但这次调用失败了（网络、站点抽风、Cloudflare）。
  runtimeFailure,
}

class OnlineMangaUnavailable implements Exception {
  const OnlineMangaUnavailable(
    this.reason,
    this.message, {
    this.cause,
    this.stage,
    this.sourceLabel,
  });

  final OnlineMangaUnavailableReason reason;
  final String message;
  final Object? cause;

  /// 断在哪一步：`details` / `chapters` / `pages` / `cover`。
  ///
  /// BUG-1767 的教训：三个阶段共用一个 catch，桥接层对它们返回的 code 可能完全
  /// 一样，不记 stage 就分不出是拉详情、拉章节还是取页面失败。
  final String? stage;

  /// 出错时那个源的展示名，进诊断文本。
  final String? sourceLabel;

  /// 可复制诊断对话框用的全文。
  ///
  /// 必须带上运行时原生侧的堆栈（`MihonRuntimeException.diagnostics` 里的
  /// `PlatformException.details`）——那几 KB 堆栈不进页面正文，但排障只能靠它。
  String get diagnostics {
    final Object? nested = cause;
    final String detail = nested is MihonRuntimeException
        ? nested.diagnostics
        : (nested?.toString() ?? message);
    return <String>[
      'stage: ${stage ?? 'unknown'}',
      if (sourceLabel != null) 'source: $sourceLabel',
      'reason: ${reason.name}',
      '',
      detail,
    ].join('\n');
  }

  @override
  String toString() => 'OnlineMangaUnavailable($reason): $message';
}

/// 一次刷新拉回来的作品 + 章节。
class OnlineMangaRefreshResult {
  const OnlineMangaRefreshResult({
    required this.series,
    required this.chapters,
  });

  final OnlineMangaSeries series;
  final List<OnlineMangaChapter> chapters;
}

/// 把「某个在线漫画运行时」收成书架侧需要的四件事。
///
/// 书架、作品页和阅读器只跟这个契约打交道，因此加第三个运行时不需要再动它们
/// 任何一行——这正是 v88 前 Aidoku 进不了书架的原因：那时的
/// `MihonLibraryService` 直接把 `MihonManager` 焊死在签名里。
abstract interface class OnlineMangaRuntimeAdapter {
  OnlineMangaRuntimeKind get kind;

  /// 本平台是否可能有这个运行时。返回 false 时上层不再尝试任何网络调用。
  bool get isSupportedOnThisPlatform;

  /// 源的展示名（作品页副标题）。解析不到返回 null，让 UI 回退到包名。
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry);

  /// 重新拉作品详情 + 章节列表。
  Future<OnlineMangaRefreshResult> refresh(OnlineMangaLibraryEntry entry);

  /// 解析出一章，交给共享阅读器。
  Future<OnlineMangaReaderChapter> openChapter({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
    required Directory managedDirectory,
    required bool persistProgress,
    int? initialPage,
  });

  /// 取封面字节（入库时落盘一份，之后书架离线可见）。
  Future<List<int>> fetchCover(OnlineMangaLibraryEntry entry, String url);
}

// ── Mihon ─────────────────────────────────────────────────────────────

class MihonLibraryAdapter implements OnlineMangaRuntimeAdapter {
  const MihonLibraryAdapter(this.manager, {this.presetContext});

  final MihonManager manager;

  /// 调用方**已经解析好**的源上下文。
  ///
  /// 源浏览页手上本来就有一份（网格就是用它拉出来的），书架条目没有。给了就直接
  /// 用，不给才从 manager 现解析。
  ///
  /// 这不是优化，是正确性：`_sourceRow` 要求该源已在库里登记且启用，而**预览态**
  /// （`MihonPreviewTarget`，试用一个还没安装的扩展）根本没有库行——现解析必然抛
  /// SOURCE_DISABLED。此外现解析还会走 `manager.initialise()`，把一次纯展示变成
  /// 一趟可能很慢、甚至挂住的初始化。
  final MihonSourceContext? presetContext;

  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.mihon;

  /// 同 [AidokuLibraryAdapter.isSupportedOnThisPlatform]：上下文已经预置好时，
  /// 「本平台能不能自己造运行时」这条限制不适用。
  @override
  bool get isSupportedOnThisPlatform =>
      presetContext != null || MihonRuntimeFactory.isSupported;

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async {
    try {
      return _sourceRow(entry).name;
    } on OnlineMangaUnavailable {
      return null;
    }
  }

  @override
  Future<OnlineMangaRefreshResult> refresh(
    OnlineMangaLibraryEntry entry,
  ) async {
    final MihonSourceContext context = await _context(entry);
    final MihonManga request = MihonManga.fromJson(entry.series.raw);
    // 三个阶段共用一个 catch，桥接层对它们返回的 code 可能完全一样，所以必须
    // 自己记住断在哪一步（BUG-1767）。
    String stage = 'details';
    try {
      final MihonManga details = await manager.runtime.getDetails(
        context.extension,
        context.source,
        request,
        preferences: context.preferences,
      );
      stage = 'chapters';
      final List<MihonChapter> chapters = await manager.runtime.getChapters(
        context.extension,
        context.source,
        details,
        preferences: context.preferences,
      );
      return OnlineMangaRefreshResult(
        // `mangaDetailsParse` 返回的是增量、可能不带 url（BUG-1767），所以身份
        // 一律用手上这条已知条目的 key，不读返回值的 url。
        series: _seriesFrom(details, fallbackKey: entry.series.key),
        chapters: <OnlineMangaChapter>[
          for (final MihonChapter chapter in chapters) _chapterFrom(chapter),
        ],
      );
    } on Object catch (error) {
      throw OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        '$error',
        cause: error,
        stage: stage,
        sourceLabel: context.source.name,
      );
    }
  }

  @override
  Future<OnlineMangaReaderChapter> openChapter({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
    required Directory managedDirectory,
    required bool persistProgress,
    int? initialPage,
  }) async {
    final MihonSourceContext context = await _context(entry);
    final MihonChapter native = MihonChapter.fromJson(chapter.raw);
    try {
      final List<MihonPage> pages = await manager.runtime.getPages(
        context.extension,
        context.source,
        native,
        preferences: context.preferences,
      );
      return MihonReaderChapter(
        manager: manager,
        sourceContext: context,
        manga: MihonManga.fromJson(entry.series.raw),
        chapter: native,
        pages: pages,
        managedDirectory: managedDirectory,
        persistProgress: persistProgress,
        initialPage: initialPage,
      );
    } on Object catch (error) {
      throw OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        '$error',
        cause: error,
        stage: 'pages',
        sourceLabel: context.source.name,
      );
    }
  }

  @override
  Future<List<int>> fetchCover(
    OnlineMangaLibraryEntry entry,
    String url,
  ) async {
    final MihonSourceContext context = await _context(entry);
    return manager.runtime.fetchSourceImage(
      context.extension,
      context.source,
      url,
      preferences: context.preferences,
    );
  }

  MangaOnlineSourceRow _sourceRow(OnlineMangaLibraryEntry entry) {
    for (final MangaOnlineSourceRow row in manager.sources) {
      if (row.extensionPackage == entry.extensionPackage &&
          row.sourceId == entry.sourceId &&
          row.enabled) {
        return row;
      }
    }
    throw const OnlineMangaUnavailable(
      OnlineMangaUnavailableReason.sourceDisabled,
      'The manga source is missing or disabled',
    );
  }

  Future<MihonSourceContext> _context(OnlineMangaLibraryEntry entry) async {
    final MihonSourceContext? preset = presetContext;
    if (preset != null) return preset;
    if (!MihonRuntimeFactory.isSupported) {
      throw const OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.platformUnsupported,
        'Mihon extensions are not available on this platform',
      );
    }
    await manager.initialise();
    final MangaOnlineSourceRow row = _sourceRow(entry);
    try {
      return await manager.contextForSource(row);
    } on Object catch (error) {
      throw OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.sourceDisabled,
        '$error',
        cause: error,
      );
    }
  }

  static OnlineMangaSeries _seriesFrom(
    MihonManga manga, {
    required String fallbackKey,
  }) {
    final Map<String, Object?> raw = manga.toJson();
    final String key = manga.url.isEmpty ? fallbackKey : manga.url;
    // raw 要能被 MihonManga.fromJson 吃回来并保住身份，所以缺 url 时补上。
    raw['url'] = key;
    return OnlineMangaSeries(
      key: key,
      title: manga.title,
      coverUrl: manga.coverUrl,
      author: manga.author,
      artist: manga.artist,
      description: manga.description,
      genre: manga.genre,
      raw: raw,
    );
  }

  static OnlineMangaChapter _chapterFrom(MihonChapter chapter) =>
      OnlineMangaChapter(
        key: chapter.url,
        name: chapter.name,
        scanlator: chapter.scanlator,
        number: chapter.number,
        uploadedAt: chapter.uploadedAt <= 0 ? null : chapter.uploadedAt,
        raw: chapter.toJson(),
      );

  /// 供源浏览页在「加入书架」时把已在手的原生对象直接归一化。
  static OnlineMangaSeries seriesOf(MihonManga manga) =>
      _seriesFrom(manga, fallbackKey: manga.url);

  static OnlineMangaChapter chapterOf(MihonChapter chapter) =>
      _chapterFrom(chapter);
}

// ── Aidoku ────────────────────────────────────────────────────────────

class AidokuLibraryAdapter implements OnlineMangaRuntimeAdapter {
  AidokuLibraryAdapter({AidokuRuntime? runtime, this.presetPackage})
    : _runtime = runtime;

  /// 调用方已经拿在手里的安装包（与 [MihonLibraryAdapter.presetContext] 同理）。
  ///
  /// 给了就不再去扫 `AidokuPackageStore.listInstalled()`——那是一次磁盘遍历，
  /// 而源浏览页早就持有这个包。
  final AidokuInstalledPackage? presetPackage;

  AidokuRuntime? _runtime;

  AidokuRuntime get _resolvedRuntime =>
      _runtime ??= AidokuRuntimeFactory.create();

  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.aidoku;

  /// 平台门只管「要不要**我自己**去造运行时」。
  ///
  /// `AidokuRuntimeFactory.isSupported` 表达的是「本平台能不能创建 Aidoku 运行
  /// 时」（只有 macOS/iOS）。但调用方把运行时和安装包都预置进来时，这条限制根本
  /// 不适用——那份运行时已经在手上、能直接用。只看平台会把这种情况误判成不可用，
  /// 于是页面明明能拉到章节却显示「本平台不支持」。
  @override
  bool get isSupportedOnThisPlatform =>
      (_runtime != null && presetPackage != null) ||
      AidokuRuntimeFactory.isSupported;

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async {
    try {
      return (await _package(entry)).name;
    } on OnlineMangaUnavailable {
      return null;
    }
  }

  @override
  Future<OnlineMangaRefreshResult> refresh(
    OnlineMangaLibraryEntry entry,
  ) async {
    final AidokuInstalledPackage package = await _package(entry);
    try {
      final Map<String, Object?> details = await _resolvedRuntime.getDetails(
        package.packagePath,
        entry.series.raw,
      );
      return OnlineMangaRefreshResult(
        series: seriesOf(details, fallbackKey: entry.series.key),
        chapters: chaptersOf(details),
      );
    } on Object catch (error) {
      throw OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        '$error',
        cause: error,
        // Aidoku 的 getDetails 一次带回详情和章节，分不出更细的阶段。
        stage: 'details',
        sourceLabel: package.name,
      );
    }
  }

  @override
  Future<OnlineMangaReaderChapter> openChapter({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
    required Directory managedDirectory,
    required bool persistProgress,
    int? initialPage,
  }) async {
    final AidokuInstalledPackage package = await _package(entry);
    try {
      final List<Object?> rawPages = await _resolvedRuntime.getPages(
        package.packagePath,
        entry.series.raw,
        chapter.raw,
      );
      return AidokuReaderChapter(
        package: package,
        manga: entry.series.raw,
        chapter: chapter.raw,
        pages: aidokuImagePagesFrom(rawPages),
        managedDirectory: managedDirectory,
        persistProgress: persistProgress,
        initialPage: initialPage,
      );
    } on Object catch (error) {
      throw OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        '$error',
        cause: error,
        stage: 'pages',
        sourceLabel: package.name,
      );
    }
  }

  @override
  Future<List<int>> fetchCover(
    OnlineMangaLibraryEntry entry,
    String url,
  ) async {
    // Aidoku 封面是普通 https 资源（源包不提供图片代理接口），带上作品页作为
    // referer 就够——与 AidokuMangaPageProvider 取页图时的做法一致。
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.getUrl(Uri.parse(url));
      final String? referer = entry.series.raw['url']?.toString();
      if (referer != null && Uri.tryParse(referer)?.isScheme('https') == true) {
        request.headers.set(HttpHeaders.refererHeader, referer);
      }
      final HttpClientResponse response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw OnlineMangaUnavailable(
          OnlineMangaUnavailableReason.runtimeFailure,
          'Cover request failed with HTTP ${response.statusCode}',
        );
      }
      final List<int> bytes = <int>[];
      await for (final List<int> chunk in response) {
        bytes.addAll(chunk);
      }
      return bytes;
    } finally {
      client.close(force: true);
    }
  }

  Future<AidokuInstalledPackage> _package(OnlineMangaLibraryEntry entry) async {
    final AidokuInstalledPackage? preset = presetPackage;
    if (preset != null) return preset;
    if (!AidokuRuntimeFactory.isSupported) {
      throw const OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.platformUnsupported,
        'Aidoku sources are only available on macOS and iOS',
      );
    }
    final List<AidokuInstalledPackage> installed =
        await (await AidokuPackageStore.open()).listInstalled();
    for (final AidokuInstalledPackage package in installed) {
      if (package.id == entry.extensionPackage && package.enabled) {
        return package;
      }
    }
    throw const OnlineMangaUnavailable(
      OnlineMangaUnavailableReason.sourceDisabled,
      'The Aidoku source package is missing or disabled',
    );
  }

  /// Aidoku 的详情 map 直接归一化成作品实体。
  ///
  /// `chapters` 键刻意从 raw 里剥掉：整份章节列表已经单独存在
  /// [OnlineMangaLibraryEntry.chapters] 里，留在 raw 里会让 `sourceMetadata`
  /// 把几百章存两遍。
  static OnlineMangaSeries seriesOf(
    Map<String, Object?> manga, {
    required String fallbackKey,
  }) {
    final Map<String, Object?> raw = Map<String, Object?>.of(manga)
      ..remove('chapters');
    final String key = raw['key']?.toString().trim().isNotEmpty == true
        ? raw['key']!.toString()
        : fallbackKey;
    raw['key'] = key;
    final Object? authors = manga['authors'];
    final String? author = authors is List<Object?> && authors.isNotEmpty
        ? authors.map((Object? value) => value.toString()).join(', ')
        : manga['author']?.toString();
    final Object? tags = manga['tags'];
    final String? genre = tags is List<Object?> && tags.isNotEmpty
        ? tags.map((Object? value) => value.toString()).join(', ')
        : manga['genre']?.toString();
    return OnlineMangaSeries(
      key: key,
      title: manga['title']?.toString() ?? '',
      coverUrl: (manga['cover'] ?? manga['coverUrl'])?.toString(),
      author: author,
      artist: manga['artist']?.toString(),
      description: manga['description']?.toString(),
      genre: genre,
      raw: raw,
    );
  }

  static List<OnlineMangaChapter> chaptersOf(Map<String, Object?> details) {
    final Object? raw = details['chapters'];
    if (raw is! List<Object?>) return const <OnlineMangaChapter>[];
    final List<OnlineMangaChapter> chapters = <OnlineMangaChapter>[];
    for (final Object? item in raw) {
      if (item is! Map<Object?, Object?>) continue;
      final Map<String, Object?> map = item.cast<String, Object?>();
      final String key = map['key']?.toString() ?? '';
      if (key.isEmpty) continue;
      // 字段名以 Aidoku 的 wire 形状为准：蛇形 `chapter_number` /
      // `date_uploaded`，翻译组是**复数列表** `scanlators`（不是 Mihon 那样的
      // 单个 `scanlator`），标题可能为空、要回退到卷/话号。抄错这几处不会报错，
      // 只会让章节列表变成一片没有编号、没有副标题的空行。
      final num? chapterNumber = map['chapter_number'] as num?;
      final int uploadedAt = (map['date_uploaded'] as num?)?.toInt() ?? 0;
      final Object? scanlators = map['scanlators'];
      final String scanlator = scanlators is List<Object?>
          ? scanlators.map((Object? value) => value.toString()).join(', ')
          : map['scanlator']?.toString() ?? '';
      chapters.add(
        OnlineMangaChapter(
          key: key,
          name: aidokuChapterDisplayTitle(map),
          scanlator: scanlator.isEmpty ? null : scanlator,
          number: chapterNumber?.toDouble(),
          uploadedAt: uploadedAt <= 0 ? null : uploadedAt,
          raw: map,
        ),
      );
    }
    return List<OnlineMangaChapter>.unmodifiable(chapters);
  }
}

import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/download/manga_download_sidecar.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime_factory.dart';
import 'package:fushi/src/media/manga/mihon/mihon_web_login_page.dart';
import 'package:fushi/src/media/manga/mihon/mihon_web_url.dart';
import 'package:fushi/src/media/manga/mihon/quirks/comico_magazine_comic_quirk.dart';
import 'package:fushi/src/media/online/online_source_error_text.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 一条在线漫画书架条目**不可用**的原因。
///
/// 分类而不是一句 message：作品页要据此决定给哪种出路——源被禁用要引导去
/// 「来源」页启用，平台不支持要直说「这个源在本平台不可用」而不是让用户对着
/// 「加载失败 + 重试」按钮反复重试一个永远不会成功的操作。
enum OnlineMangaUnavailableReason {
  /// 扩展/包已卸载或被停用。
  sourceDisabled,

  /// 该运行时在本平台根本不存在（如 iOS 上的 Mihon、已移除的 Aidoku）。
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

  /// 给用户看的一句话（toast / 错误视图正文）。
  ///
  /// [message] 多数是包装时的 `'$error'` 原串（`SocketException: Failed host
  /// lookup ...`），原样保留给 [diagnostics] / 日志；展示一律走这里，经
  /// [describeOnlineSourceError] 归一。[message] 不是 [cause] 的原串时说明
  /// 包装方专门写了说明（如「对端还没下载这一章」），按文本归一而不是退回
  /// [cause]。
  String get userMessage {
    final Object? nested = cause;
    if (nested != null && message == '$nested') {
      return describeOnlineSourceError(nested);
    }
    return describeOnlineSourceErrorText(message);
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

/// 一章页表里的一页：各运行时自己的取图引用 + 页序。
///
/// 密封是为了让 [OnlineMangaRuntimeAdapter.fetchChapterPage] 能穷尽分派而不靠
/// `is` 链；下载服务只按 [index] 命名落盘文件，不看里面是什么。
sealed class OnlineMangaPageRef {
  const OnlineMangaPageRef({required this.index});

  /// 0-based 页序（落盘名 `page-000001` 由它 +1 得出）。
  final int index;

  /// Original provider URL, used only to match optional OCR sidecars.
  String? get sourceUrl => null;
}

/// Mihon：取图必须经扩展自己的 OkHttp 客户端（拦截器、cookie、按请求头）。
class MihonMangaPageRef extends OnlineMangaPageRef {
  const MihonMangaPageRef({
    required super.index,
    required this.context,
    required this.page,
  });

  final MihonSourceContext context;
  final MihonPage page;

  @override
  String? get sourceUrl => page.resolvedUrl;
}

/// 源补丁（quirk）产出的裸 https 页：URL 自带签名，只需 Referer（BUG-2514）。
///
/// 与 [MihonMangaPageRef] 的区别是**不经**扩展的 OkHttp——这些页根本不是扩展
/// 解析出来的，扩展对它们一无所知。
class HttpMangaPageRef extends OnlineMangaPageRef {
  const HttpMangaPageRef({
    required super.index,
    required this.url,
    required this.referer,
  });

  final String url;

  /// 源站 baseUrl（不带尾斜杠），作为 Referer。
  final String referer;

  @override
  String? get sourceUrl => url;
}

/// 互联对端：`bookKey` + 页序即是端点路径段。
class InterconnectMangaPageRef extends OnlineMangaPageRef {
  const InterconnectMangaPageRef({
    required super.index,
    required this.bookKey,
    required this.remoteIndex,
    this.chapterDigest,
  });

  final String bookKey;

  /// 对端页表里的 `index`（通常与 [index] 相同，但以对端报的为准）。
  final int remoteIndex;

  /// 章节式在线漫画的章目录摘要（BUG-2474）；null = 单卷本地漫画，页走
  /// `/pages/<i>`，非 null 走 `/chapters/<digest>/pages/<i>`。
  final String? chapterDigest;
}

/// 把「某个在线漫画运行时」收成书架侧需要的几件事。
///
/// 书架、作品页、下载服务和阅读器只跟这个契约打交道，因此加第三个运行时不需要
/// 再动它们任何一行——这正是 v88 前 Aidoku 进不了书架的原因：那时的
/// `MihonLibraryService` 直接把 `MihonManager` 焊死在签名里。
///
/// 取页是**两段式**（设计稿 2026-09-12 §3）：先 [resolveChapterPages] 拿页表，再逐页
/// [fetchChapterPage] 取字节。两个消费者共用这一对方法：下载服务（落章目录）与
/// 阅读器的在线直读会话 `OnlineMangaReaderSession`（2026-09-26 起，临时缓存）。
abstract interface class OnlineMangaRuntimeAdapter {
  OnlineMangaRuntimeKind get kind;

  /// 本平台是否可能有这个运行时。返回 false 时上层不再尝试任何网络调用。
  bool get isSupportedOnThisPlatform;

  /// 源的展示名（作品页副标题）。解析不到返回 null，让 UI 回退到包名。
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry);

  /// 重新拉作品详情 + 章节列表。
  Future<OnlineMangaRefreshResult> refresh(OnlineMangaLibraryEntry entry);

  /// 解析一章的页表（按页序）。空章节视为失败，由实现抛 [OnlineMangaUnavailable]。
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  });

  /// 取一页字节。只接受本运行时自己在 [resolveChapterPages] 里造的引用。
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page);

  /// 取封面字节（入库时落盘一份，之后书架离线可见）。
  Future<List<int>> fetchCover(OnlineMangaLibraryEntry entry, String url);
}

/// Optional OCR sidecar capability. Sources that do not implement this are
/// never queried for sidecars.
abstract interface class MangaOcrSidecarProvider {
  Future<String?> fetchChapterOcrSidecar({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  });
}

/// 在 app 内登录源站所需的一切（[runtime] 交给 `mihonLoginTarget` 判能力）。
typedef OnlineMangaLoginTarget = ({
  Object runtime,
  String sourceName,
  String baseUrl,
});

/// 有「在 app 内登录源站」流程的适配器（BUG-2479）。
///
/// 独立于 [OnlineMangaRuntimeAdapter]：Aidoku / 互联对端没有这条流程，作品页
/// 用 `is OnlineMangaLoginCapable` 判有没有，与运行时那边的 cookie 能力接口同一
/// 套写法。
abstract interface class OnlineMangaLoginCapable {
  /// 该条目所属源的登录目标；源没登记 / 运行时不接受浏览器登录 / baseUrl 解析
  /// 不出 host 时返回 null。
  OnlineMangaLoginTarget? loginTarget(OnlineMangaLibraryEntry entry);

  /// 「登录能不能解开这一章」：能就返回登录目标，否则 null。锁章弹窗按它决定
  /// 给不给「登录」按钮——源整体能登录不等于每一章登录后都能读（BUG-2514：
  /// quirk 章匿名请求，登录了也拿不到付费正文，给按钮就是假承诺）。
  OnlineMangaLoginTarget? loginTargetForChapter(
    OnlineMangaLibraryEntry entry,
    OnlineMangaChapter chapter,
  );
}

/// 有「作品在源站的网页」的适配器：作品页 AppBar 的「在网站打开」入口用
/// `is OnlineMangaWebUrlCapable` 判有没有（本地卷 / 互联对端没有）。
abstract interface class OnlineMangaWebUrlCapable {
  /// 该条目在源站的网页地址；源没登记、扩展没给出地址且 baseUrl 也拼不出时
  /// 返回 null（按钮照常显示，点了给「该源没有网页」提示，不做静态判定——
  /// 地址要真问扩展才知道）。
  Future<Uri?> webUrl(OnlineMangaLibraryEntry entry);
}

/// 同一扩展下另一种语言的已启用源（BUG-2510）。
class OnlineMangaSiblingSource {
  const OnlineMangaSiblingSource({
    required this.sourceId,
    required this.name,
    required this.language,
  });

  final String sourceId;
  final String name;
  final String language;
}

/// 「这个源按语言取章」的说明：当前源的语言 + 同扩展下其它语言的源。
class OnlineMangaSourceLanguageScope {
  const OnlineMangaSourceLanguageScope({
    required this.language,
    required this.siblings,
  });

  final String language;
  final List<OnlineMangaSiblingSource> siblings;
}

/// 章节列表按源语言过滤的适配器（BUG-2510）。
///
/// Mihon 的多语言扩展（MangaDex 之类）一语言一个源，日文源在一部只有译版的作品
/// 上合法地返回 0 话。作品页空态要能说清「不是加载失败、是这个源只取这一种
/// 语言」并给出同扩展其它语言源的出路。Aidoku 的语言是源内设置、app 侧不掌握，
/// 互联对端没有语言概念，两者不实现——作品页用 `is` 判，没有就沿用旧空态文案。
abstract interface class OnlineMangaLanguageScoped {
  /// 该条目所属源的语言范围；源没登记 / 语言为空或 `all`（不按语言取章）时
  /// 返回 null。
  OnlineMangaSourceLanguageScope? languageScope(OnlineMangaLibraryEntry entry);

  /// 同一部作品换到 [sibling] 源：返回能拉它的 adapter 与对应的 seed。
  /// 章节留空，由作品页进页后自己拉。前提是同扩展的各语言源共用同一套作品
  /// URL（MangaDex / MangaPlus / Webtoons 都如此）；一个扩展打包多个不同站点
  /// 的情况不成立，那类扩展的源语言通常也是 `all`，不会走到这里。
  /// 源缺失 / 扩展被禁用抛 [OnlineMangaUnavailable]。
  Future<({OnlineMangaRuntimeAdapter adapter, OnlineMangaLibraryEntry seed})>
  siblingOf(OnlineMangaLibraryEntry entry, OnlineMangaSiblingSource sibling);
}

// ── Mihon ─────────────────────────────────────────────────────────────

class MihonLibraryAdapter
    implements
        OnlineMangaRuntimeAdapter,
        MangaOcrSidecarProvider,
        OnlineMangaLoginCapable,
        OnlineMangaWebUrlCapable,
        OnlineMangaLanguageScoped {
  const MihonLibraryAdapter(
    this.manager, {
    this.presetContext,
    this.comicoQuirk,
  });

  final MihonManager manager;

  @override
  Future<String?> fetchChapterOcrSidecar({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) async {
    final MihonSourceContext context = await _context(entry);
    return fetchMokuroSidecar(
      entry,
      chapter,
      sourceName: context.source.name,
      sourceBaseUrl: context.source.baseUrl,
    );
  }

  /// 测试缝：null = 生产装配（走应用代理出口的 http 客户端）。
  final ComicoMagazineComicQuirk? comicoQuirk;

  ComicoMagazineComicQuirk get _comico =>
      comicoQuirk ?? ComicoMagazineComicQuirk();

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

  /// 上下文已经预置好时，「本平台能不能自己造运行时」这条限制不适用。
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
  OnlineMangaLoginTarget? loginTarget(OnlineMangaLibraryEntry entry) {
    final MihonSourceContext? preset = presetContext;
    String name;
    String baseUrl;
    if (preset != null) {
      name = preset.source.name;
      baseUrl = preset.source.baseUrl;
    } else {
      try {
        final MangaOnlineSourceRow row = _sourceRow(entry);
        name = row.name;
        baseUrl = row.baseUrl;
      } on OnlineMangaUnavailable {
        return null;
      }
    }
    final Object runtime = manager.runtime;
    if (mihonLoginTarget(runtime: runtime, baseUrl: baseUrl) == null) {
      return null;
    }
    return (runtime: runtime, sourceName: name, baseUrl: baseUrl);
  }

  @override
  Future<Uri?> webUrl(OnlineMangaLibraryEntry entry) async {
    final MihonSourceContext context;
    try {
      context = await _context(entry);
    } on OnlineMangaUnavailable {
      return null;
    }
    return resolveMihonMangaWebUrl(
      runtime: manager.runtime,
      context: context,
      manga: MihonManga.fromJson(entry.series.raw),
    );
  }

  @override
  OnlineMangaLoginTarget? loginTargetForChapter(
    OnlineMangaLibraryEntry entry,
    OnlineMangaChapter chapter,
  ) => ComicoMagazineComicQuirk.ownsChapter(chapter.raw)
      ? null
      : loginTarget(entry);

  /// Mihon 里「不按语言取章」的源语言值：多语言单源扩展用这些占位。
  static const Set<String> _languageAgnostic = <String>{'', 'all', 'multi'};

  @override
  OnlineMangaSourceLanguageScope? languageScope(OnlineMangaLibraryEntry entry) {
    final MihonSourceContext? preset = presetContext;
    final String language;
    if (preset != null) {
      language = preset.source.language;
    } else {
      try {
        language = _sourceRow(entry).language;
      } on OnlineMangaUnavailable {
        return null;
      }
    }
    if (_languageAgnostic.contains(language.toLowerCase())) return null;
    return OnlineMangaSourceLanguageScope(
      language: language,
      siblings: siblingSourcesOf(
        manager.sources,
        extensionPackage: entry.extensionPackage,
        language: language,
      ),
    );
  }

  /// 同扩展、其它语言、已启用的源，每种语言留一个（镜像站不重复出 chip），
  /// 按语言码排序。
  ///
  /// 本源语言由调用方给而不是从 [sources] 反查：预览态（试用未安装的扩展）
  /// 本源根本不在库里，反查会漏掉「同语言镜像」这条过滤。
  static List<OnlineMangaSiblingSource> siblingSourcesOf(
    Iterable<MangaOnlineSourceRow> sources, {
    required String extensionPackage,
    required String language,
  }) {
    final Map<String, OnlineMangaSiblingSource> byLanguage =
        <String, OnlineMangaSiblingSource>{};
    final String own = language.toLowerCase();
    for (final MangaOnlineSourceRow row in sources) {
      final String candidate = row.language.toLowerCase();
      if (!row.enabled ||
          row.extensionPackage != extensionPackage ||
          candidate == own ||
          _languageAgnostic.contains(candidate)) {
        continue;
      }
      byLanguage.putIfAbsent(
        candidate,
        () => OnlineMangaSiblingSource(
          sourceId: row.sourceId,
          name: row.name,
          language: row.language,
        ),
      );
    }
    return byLanguage.values.toList(growable: false)..sort(
      (OnlineMangaSiblingSource a, OnlineMangaSiblingSource b) =>
          a.language.compareTo(b.language),
    );
  }

  @override
  Future<({OnlineMangaRuntimeAdapter adapter, OnlineMangaLibraryEntry seed})>
  siblingOf(
    OnlineMangaLibraryEntry entry,
    OnlineMangaSiblingSource sibling,
  ) async {
    final OnlineMangaLibraryEntry seed = OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: entry.extensionPackage,
      sourceId: sibling.sourceId,
      series: entry.series,
      chapters: const <OnlineMangaChapter>[],
    );
    // 用一个**没有** preset 的 adapter 去解析 sibling 的上下文：查库行、
    // initialise、把 EXTENSION_DISABLED 之类包成 OnlineMangaUnavailable 全在
    // `_context` 一处；本 adapter 若带 preset，`_context` 会早退回本源的上下文。
    final MihonSourceContext context = await MihonLibraryAdapter(
      manager,
    )._context(seed);
    return (
      adapter: MihonLibraryAdapter(manager, presetContext: context),
      seed: seed,
    );
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
      final List<OnlineMangaChapter> chapters = await _chapters(
        context,
        details,
        seriesKey: entry.series.key,
      );
      return OnlineMangaRefreshResult(
        // `mangaDetailsParse` 返回的是增量、可能不带 url（BUG-1767），所以身份
        // 一律用手上这条已知条目的 key，不读返回值的 url。
        series: _seriesFrom(details, fallbackKey: entry.series.key),
        chapters: chapters,
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

  /// 扩展拉章节；コミコ `magazine_comic` 作品扩展报 Not Found 时换本仓的
  /// quirk 路由再拉一次（BUG-2514），产出的章带标记、取页也走 quirk。
  Future<List<OnlineMangaChapter>> _chapters(
    MihonSourceContext context,
    MihonManga details, {
    required String seriesKey,
  }) async {
    try {
      final List<MihonChapter> chapters = await manager.runtime.getChapters(
        context.extension,
        context.source,
        details,
        preferences: context.preferences,
      );
      return <OnlineMangaChapter>[
        for (final MihonChapter chapter in chapters) _chapterFrom(chapter),
      ];
    } on Object catch (error) {
      final int? contentId = ComicoMagazineComicQuirk.contentIdOf(seriesKey);
      if (contentId == null ||
          !ComicoMagazineComicQuirk.matches(context.source) ||
          !ComicoMagazineComicQuirk.isNotFound(error)) {
        rethrow;
      }
      final List<MihonChapter> chapters;
      try {
        chapters = await _comico.chapters(
          contentId: contentId,
          baseUrl: context.source.baseUrl,
          language: context.source.language,
        );
      } on Object catch (quirkError, stack) {
        // quirk 也失败（普通 comic 被下架之类）：对用户抛**扩展的原始错误**
        // （带原生堆栈的诊断），quirk 自己的失败只记日志——否则诊断框里只剩
        // 一条 /magazine_comic 的 404，真正的线索没了。
        ErrorLogService.instance.log(
          'MihonLibraryAdapter.comicoQuirk',
          quirkError,
          stack,
        );
        // ignore: only_throw_errors — 原样抛回扩展那份，类型由扩展决定。
        throw error;
      }
      return <OnlineMangaChapter>[
        for (final MihonChapter chapter in chapters)
          _chapterFrom(
            chapter,
            extraRaw: const <String, Object?>{
              ComicoMagazineComicQuirk.rawMarkerKey:
                  ComicoMagazineComicQuirk.rawMarkerValue,
            },
          ),
      ];
    }
  }

  @override
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) async {
    final MihonSourceContext context = await _context(entry);
    final MihonChapter native = MihonChapter.fromJson(chapter.raw);
    try {
      if (ComicoMagazineComicQuirk.ownsChapter(chapter.raw)) {
        final List<String> urls = await _comico.pageUrls(
          chapterUrl: native.url,
          baseUrl: context.source.baseUrl,
          language: context.source.language,
        );
        return <OnlineMangaPageRef>[
          for (int index = 0; index < urls.length; index++)
            HttpMangaPageRef(
              index: index,
              url: urls[index],
              referer: context.source.baseUrl,
            ),
        ];
      }
      final List<MihonPage> pages = await manager.runtime.getPages(
        context.extension,
        context.source,
        native,
        preferences: context.preferences,
      );
      if (pages.isEmpty) {
        throw const MihonRuntimeException(
          'EMPTY_CHAPTER',
          'The source returned no pages for this chapter',
        );
      }
      return <OnlineMangaPageRef>[
        for (int index = 0; index < pages.length; index++)
          MihonMangaPageRef(index: index, context: context, page: pages[index]),
      ];
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

  /// [HttpMangaPageRef] 是 quirk 产出、扩展不认识的页（URL 自带签名），例外
  /// 走裸 https。其余走 [CancellableMihonRuntime.fetchImageRequest]（请求可被
  /// runtime 侧登记）；不支持的 runtime 退回 [MihonRuntime.fetchImage]——两者都
  /// 经扩展自己的 OkHttp 客户端，不能换成裸 HTTP，会丢掉扩展拦截器、cookie 与
  /// 按请求头。
  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) async {
    if (page is HttpMangaPageRef) {
      // 目前只有コミコ一个 quirk 产出这种页；再来一个时给 ref 加 quirk 标识分派。
      return _comico.fetchImage(page.url, baseUrl: page.referer);
    }
    if (page is! MihonMangaPageRef) {
      throw ArgumentError.value(page, 'page', 'not a Mihon page reference');
    }
    final MihonRuntime runtime = manager.runtime;
    if (runtime is CancellableMihonRuntime) {
      return (runtime as CancellableMihonRuntime).fetchImageRequest(
        page.context.extension,
        page.context.source,
        page.page,
        requestId: 'download-${identityHashCode(page)}-${page.index}',
        preferences: page.context.preferences,
      );
    }
    return runtime.fetchImage(
      page.context.extension,
      page.context.source,
      page.page,
      preferences: page.context.preferences,
    );
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
    // 不再按 `MihonRuntimeFactory.isSupported` 静态判平台：[manager] 手里已经是
    // 一个具体的 [MihonRuntime]（生产只在 `AppModel.mihonManager` 过了平台门、
    // `MihonRuntimeFactory.create` 成功后才会有 manager），它的存在就是能力证明；
    // 在这里再问一遍 `Platform` 只会把注入了 runtime 的用例在 Linux CI 上误判成
    // platformUnsupported（develop@4846ea1 的 mihon_language_scope_test 红）。
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

  static OnlineMangaChapter _chapterFrom(
    MihonChapter chapter, {
    Map<String, Object?> extraRaw = const <String, Object?>{},
  }) => OnlineMangaChapter(
    key: chapter.url,
    name: chapter.name,
    scanlator: chapter.scanlator,
    number: chapter.number,
    uploadedAt: chapter.uploadedAt <= 0 ? null : chapter.uploadedAt,
    locked: OnlineMangaChapter.isLockedChapterName(chapter.name),
    raw: <String, Object?>{...chapter.toJson(), ...extraRaw},
  );

  /// 供源浏览页在「加入书架」时把已在手的原生对象直接归一化。
  static OnlineMangaSeries seriesOf(MihonManga manga) =>
      _seriesFrom(manga, fallbackKey: manga.url);

  static OnlineMangaChapter chapterOf(MihonChapter chapter) =>
      _chapterFrom(chapter);
}

// ── Aidoku（已移除，只剩旧书架条目） ─────────────────────────────────────

/// 旧版本留下的 Aidoku 书架条目的适配器。
///
/// Aidoku 宿主已整体移除，本仓不再有任何能执行 Aidoku 源的代码；但用户库里可能
/// 还留着 `runtime: aidoku` 的书架条目（描述符 wire 值冻结，见
/// [OnlineMangaRuntimeKind.aidoku]）。这些条目必须能照常列出、打开作品页、读已
/// 下载到本地的章节、被删除，所以分派仍要有一个适配器——它对一切网络操作都如实
/// 回报「本平台不可用」，作品页据此显示不可用提示，而不是崩在找不到运行时上。
class LegacyAidokuLibraryAdapter implements OnlineMangaRuntimeAdapter {
  const LegacyAidokuLibraryAdapter();

  static const OnlineMangaUnavailable _removed = OnlineMangaUnavailable(
    OnlineMangaUnavailableReason.platformUnsupported,
    'The Aidoku runtime has been removed from Fushi',
  );

  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.aidoku;

  @override
  bool get isSupportedOnThisPlatform => false;

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async => null;

  @override
  Future<OnlineMangaRefreshResult> refresh(OnlineMangaLibraryEntry entry) =>
      Future<OnlineMangaRefreshResult>.error(_removed);

  @override
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) => Future<List<OnlineMangaPageRef>>.error(_removed);

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) =>
      Future<Uint8List>.error(_removed);

  @override
  Future<List<int>> fetchCover(OnlineMangaLibraryEntry entry, String url) =>
      Future<List<int>>.error(_removed);
}

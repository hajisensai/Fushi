import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_unavailable.dart';
import 'package:fushi/src/media/manga/download/manga_download_sidecar.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime_factory.dart';
import 'package:fushi/src/media/manga/mihon/mihon_web_login_page.dart';
import 'package:fushi/src/media/manga/mihon/mihon_web_url.dart';
import 'package:fushi/src/media/manga/mihon/quirks/comico_magazine_comic_quirk.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

// 不可用错误与 Cloudflare 判型定义在无 UI 依赖的文件里（全源搜索 runner 等非 widget
// 层直接 import 那份）；这里转出，存量调用方不用改 import。
export 'package:fushi/src/media/manga/library/online_manga_unavailable.dart';

/// 页引用已随运行时进程失效（桌面 sidecar 重启，BUG-4917）。
///
/// 不是「这一页取失败」：同一章重新 [OnlineMangaRuntimeAdapter.resolveChapterPages]
/// 换一份引用就能取。只由 [OnlineMangaRuntimeAdapter.fetchChapterPage] 抛，
/// [OnlineMangaChapterPageRefs] 接住它重解析页表。
class OnlineMangaPageRefExpired implements Exception {
  const OnlineMangaPageRefExpired(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => 'OnlineMangaPageRefExpired: $message';
}

/// 一章的页表，运行时重启后就地换新引用（BUG-4917）。
///
/// 在线直读会话（`OnlineMangaReaderSession`）按页序取页，页数与每页的身份串
/// （面板 / OCR 缓存键）在开会话时就定了；这里只持有可以换的那部分——取页引用。
/// 取页撞上 [OnlineMangaPageRefExpired] 时重解析一次页表：新表与旧表**逐页**是
/// 同一份（[sameSourcePages]：页数相同、每页源端身份 [OnlineMangaPageRef.pageKey]
/// 都在且相等）才整份换新、用新引用再取这一页；否则源端章节已不是开会话时那一份
/// （页数变了，或同页数换了 / 重排了页，audit-035），按失败处理
/// （[OnlineMangaUnavailable]，之后的取页都直接报这个错，不再反复重解析）——
/// 接着取只会把两版页图混进同一章。并发撞上失效的取页共用同一次重解析。
class OnlineMangaChapterPageRefs {
  OnlineMangaChapterPageRefs({
    required this.adapter,
    required this.entry,
    required this.chapter,
    required List<OnlineMangaPageRef> pages,
  }) : _pages = List<OnlineMangaPageRef>.unmodifiable(pages);

  final OnlineMangaRuntimeAdapter adapter;
  final OnlineMangaLibraryEntry entry;
  final OnlineMangaChapter chapter;

  List<OnlineMangaPageRef> _pages;
  Future<List<OnlineMangaPageRef>>? _reresolving;
  OnlineMangaUnavailable? _mismatch;

  /// 页数（开会话时定，之后不变）。
  int get length => _pages.length;

  /// 重解析后发现源端页表已变（页数或某页身份）：这份页表再也取不到页，持有者
  /// （缓存页表的互联 host、下载服务）要丢掉它，按新页表重开。
  bool get pageTableChanged => _mismatch != null;

  /// 当前有效的第 [index] 页引用（取消在飞请求要对得上当前引用）。
  OnlineMangaPageRef operator [](int index) => _pages[index];

  /// 取第 [index] 页字节；引用随运行时失效时重解析页表后再取一次。
  Future<Uint8List> fetch(int index) async {
    final List<OnlineMangaPageRef> used = _pages;
    try {
      return await adapter.fetchChapterPage(used[index]);
    } on OnlineMangaPageRefExpired {
      final List<OnlineMangaPageRef> fresh = await _refreshAfterExpiry(used);
      return adapter.fetchChapterPage(fresh[index]);
    }
  }

  Future<List<OnlineMangaPageRef>> _refreshAfterExpiry(
    List<OnlineMangaPageRef> expired,
  ) {
    final OnlineMangaUnavailable? mismatch = _mismatch;
    if (mismatch != null) {
      return Future<List<OnlineMangaPageRef>>.error(mismatch);
    }
    // 别的取页已经换过新表：直接用新表，不再解析一次。
    if (!identical(expired, _pages)) {
      return Future<List<OnlineMangaPageRef>>.value(_pages);
    }
    return _reresolving ??= _reresolve().whenComplete(() {
      _reresolving = null;
    });
  }

  Future<List<OnlineMangaPageRef>> _reresolve() async {
    final List<OnlineMangaPageRef> fresh = await adapter.resolveChapterPages(
      entry: entry,
      chapter: chapter,
    );
    if (!sameSourcePages(_pages, fresh)) {
      final OnlineMangaUnavailable mismatch = OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        fresh.length != _pages.length
            ? 'The chapter now has ${fresh.length} pages instead of '
                  '${_pages.length} after the runtime restarted'
            : 'The chapter pages changed at the source after the runtime '
                  'restarted',
        stage: 'pages',
      );
      _mismatch = mismatch;
      throw mismatch;
    }
    _pages = List<OnlineMangaPageRef>.unmodifiable(fresh);
    return _pages;
  }

  /// [a] 与 [b] 是否源端同一份页表：页数相同，且逐页 [OnlineMangaPageRef.pageKey]
  /// 都非 null 且相等。认不出身份（null）的页一律当作「可能变了」——宁可让持有者
  /// 重开，也不把两版页图拼成一章。
  static bool sameSourcePages(
    List<OnlineMangaPageRef> a,
    List<OnlineMangaPageRef> b,
  ) {
    if (a.length != b.length) return false;
    for (int index = 0; index < a.length; index++) {
      final String? key = a[index].pageKey;
      if (key == null || key != b[index].pageKey) return false;
    }
    return true;
  }
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

  /// 源端稳定页身份（audit-035）：同一个值 = 源端同一页图，**不随**运行时进程、
  /// 取图令牌、代理端口变。下载续跑按它认磁盘上已落地的页还算不算数、页表重排后
  /// 落到了哪一页；重解析页表时按它判源端章节有没有换页。
  ///
  /// null = 这个运行时给不出（旧宿主 / 对端没报）：续跑不复用这页、重解析一律
  /// 当作已变。不要拿取图地址凑——桌面 sidecar 的代理地址每次重启都变、带令牌的
  /// CDN 地址会轮换，凑出来的身份要么天天误判重下，要么认错页。
  String? get pageKey;
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

  /// 优先扩展原样给的图片地址：桌面上 [MihonPage.resolvedUrl] 是 sidecar 进程内的
  /// 代理地址，既对不上 OCR sidecar 里的源站地址，也每次重启都变。
  @override
  String? get sourceUrl {
    final String? original = page.sourceImageUrl;
    return original != null && original.isNotEmpty
        ? original
        : page.resolvedUrl;
  }

  @override
  String? get pageKey => page.pageKey;
}

/// 裸 http(s) 页：源补丁（quirk）产出的签名 URL（BUG-2514），以及网页漫画
/// （[OnlineMangaRuntimeKind.web]）扫出来的图。
///
/// 与 [MihonMangaPageRef] 的区别是**不经**扩展的 OkHttp——这些页根本不是扩展
/// 解析出来的，扩展对它们一无所知。
class HttpMangaPageRef extends OnlineMangaPageRef {
  const HttpMangaPageRef({
    required super.index,
    required this.url,
    required this.referer,
    this.headers = const <String, String>{},
  });

  final String url;

  /// 源站 baseUrl（不带尾斜杠），作为 Referer。空串 = 不带 Referer。
  final String referer;

  /// 额外请求头（网页漫画：同站 Cookie、扫图 WebView 的 User-Agent、站点规则
  /// 要求的头）。quirk 页不用，恒为空。
  final Map<String, String> headers;

  @override
  String? get sourceUrl => url;

  /// 页图地址本身（网页漫画扫出来的图、quirk 产出的签名地址）。签名会轮换的源
  /// 续跑时按变了处理、重取，宁慢不错。
  @override
  String? get pageKey => url;
}

/// 互联对端：`bookKey` + 页序即是端点路径段。
class InterconnectMangaPageRef extends OnlineMangaPageRef {
  const InterconnectMangaPageRef({
    required super.index,
    required this.bookKey,
    required this.remoteIndex,
    this.chapterDigest,
    this.remotePageKey,
  });

  final String bookKey;

  /// 对端页表报的这一页身份（`RemoteMangaPageInfo.key`，原样）；旧对端不报 = null。
  /// 取页时把它的摘要带给对端核对（HBK-AUDIT-205）。
  final String? remotePageKey;

  /// [remotePageKey] 前缀上 host 侧 bookKey + 章摘要：同一个源端身份在不同的书 /
  /// 章里不是同一页。
  @override
  String? get pageKey => switch (remotePageKey) {
    final String key => '$bookKey\u0000${chapterDigest ?? ''}\u0000$key',
    null => null,
  };

  /// 对端页表里的 `index`（通常与 [index] 相同，但以对端报的为准）。
  final int remoteIndex;

  /// 章节式在线漫画的章目录摘要（BUG-2474）；null = 单卷本地漫画，页走
  /// `/pages/<i>`，非 null 走 `/chapters/<digest>/pages/<i>`。
  final String? chapterDigest;
}

/// Kavita 服务器：服务器配置 id + Kavita chapterId + 页序（0 起）。
///
/// **不带**图片 URL：Kavita 的 `/api/Reader/image` 认 `apiKey` 查询参数，URL 本身
/// 就是长期凭据，所以 [sourceUrl] 恒 null（它会被写进下载 sidecar），取图时再经
/// 服务器配置现拼。
class KavitaMangaPageRef extends OnlineMangaPageRef {
  const KavitaMangaPageRef({
    required super.index,
    required this.serverConfigId,
    required this.chapterId,
    required this.page,
  });

  final String serverConfigId;
  final int chapterId;

  /// Kavita 侧页序（0 起，通常与 [index] 相同）。
  final int page;

  /// Kavita 的章 id 是服务器侧稳定身份，章内页序由服务器按文件定。
  @override
  String get pageKey =>
      'kavita\u0000$serverConfigId\u0000$chapterId\u0000$page';

  Map<String, Object?> toJson() => <String, Object?>{
    'index': index,
    'serverConfigId': serverConfigId,
    'chapterId': chapterId,
    'page': page,
  };

  static KavitaMangaPageRef? fromJson(Map<String, Object?> json) {
    final int? index = (json['index'] as num?)?.toInt();
    final int? chapterId = (json['chapterId'] as num?)?.toInt();
    final int? page = (json['page'] as num?)?.toInt();
    final String serverConfigId = json['serverConfigId']?.toString() ?? '';
    if (index == null ||
        chapterId == null ||
        page == null ||
        serverConfigId.isEmpty) {
      return null;
    }
    return KavitaMangaPageRef(
      index: index,
      serverConfigId: serverConfigId,
      chapterId: chapterId,
      page: page,
    );
  }
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
  ///
  /// 引用随运行时进程失效（桌面 sidecar 重启）时抛 [OnlineMangaPageRefExpired]：
  /// 长期持有页表的调用方经 [OnlineMangaChapterPageRefs] 取页，由它重解析换新引用。
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

/// 能取消在飞取页请求的适配器（在线直读换章 / 关阅读器时释放运行时取图通道）。
///
/// 独立于 [OnlineMangaRuntimeAdapter]：只有经可取消运行时取页的实现才有意义，
/// 调用方用 `is OnlineMangaPageCancellable` 判能力。
abstract interface class OnlineMangaPageCancellable {
  /// 尽力取消 [pages] 仍在飞的 [OnlineMangaRuntimeAdapter.fetchChapterPage]。
  Future<void> cancelChapterPages(Iterable<OnlineMangaPageRef> pages);
}

/// 能替不在作品页上的调用方（下载中心的失败任务行）解 Cloudflare 挑战的适配器。
///
/// 任务行只留下了失败的异常，没有作品页手上那个 manager；下载服务经这个能力从
/// 适配器取解题用的运行时，按 [canSolveMihonCloudflare] 判要不要给「验证」。
abstract interface class OnlineMangaChallengeSolver {
  /// 解题用的运行时（Mihon 是 manager 的 runtime；不是 [ChallengeMihonRuntime]
  /// 的就不给验证按钮）。
  Object get challengeRuntime;
}

/// [error] 里有没有 [runtime] 能解的 Cloudflare 挑战。「验证」按钮显不显示的
/// **唯一**判据：作品页、全源搜索、源浏览、封面失败与下载中心共用。
bool canSolveMihonCloudflare({
  required Object? runtime,
  required Object? error,
}) =>
    runtime is ChallengeMihonRuntime && mihonCloudflareChallenge(error) != null;

/// 用 [runtime] 解 [error] 里的挑战（弹验证页，总是由用户点按钮触发）。
///
/// true = 解完；false = 没有可解的挑战，或用户关掉了验证页
/// （`CHALLENGE_CANCELLED`，不算失败）；其余失败照抛给调用方展示。
Future<bool> solveMihonCloudflare({
  required Object? runtime,
  required Object? error,
}) async {
  final MihonCloudflareChallengeException? challenge = mihonCloudflareChallenge(
    error,
  );
  if (runtime is! ChallengeMihonRuntime || challenge == null) return false;
  try {
    await runtime.solveCloudflare(
      challenge.url,
      userAgent: challenge.userAgent,
    );
  } on MihonRuntimeException catch (failure) {
    if (failure.code == 'CHALLENGE_CANCELLED') return false;
    rethrow;
  }
  return true;
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
        OnlineMangaLanguageScoped,
        OnlineMangaPageCancellable,
        OnlineMangaChallengeSolver {
  const MihonLibraryAdapter(
    this.manager, {
    this.presetContext,
    this.comicoQuirk,
  });

  final MihonManager manager;

  @override
  Object get challengeRuntime => manager.runtime;

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
  /// SOURCE_DISABLED。此外现解析还要等 manager 的本地就绪段（读库），纯展示
  /// 用不着。
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
    try {
      if (runtime is CancellableMihonRuntime) {
        return await (runtime as CancellableMihonRuntime).fetchImageRequest(
          page.context.extension,
          page.context.source,
          page.page,
          requestId: mihonPageRequestId(page),
          preferences: page.context.preferences,
        );
      }
      return await runtime.fetchImage(
        page.context.extension,
        page.context.source,
        page.page,
        preferences: page.context.preferences,
      );
    } on MihonRuntimeException catch (error) {
      if (error.code != kMihonStalePageReferenceCode) rethrow;
      throw OnlineMangaPageRefExpired(error.message, cause: error);
    }
  }

  @override
  Future<void> cancelChapterPages(Iterable<OnlineMangaPageRef> pages) async {
    final MihonRuntime runtime = manager.runtime;
    if (runtime is! CancellableMihonRuntime) return;
    final List<String> requestIds = <String>[
      for (final OnlineMangaPageRef page in pages)
        if (page is MihonMangaPageRef) mihonPageRequestId(page),
    ];
    if (requestIds.isEmpty) return;
    await (runtime as CancellableMihonRuntime).cancelImageRequests(requestIds);
  }

  /// 同一个页引用对象 → 同一个运行时请求号（取消要对得上）；不同的页引用对象 →
  /// 一定不同的请求号。
  ///
  /// 旧实现拿 `identityHashCode` 拼号：它不唯一，两个同页号的活引用撞上同一个号时，
  /// 桌面运行时按请求号登记的取图客户端被后一个顶掉（前一个请求被直接关掉），
  /// 取消也会取消错页。现在按引用对象发单调递增序号（[Expando] 随引用回收）。
  @visibleForTesting
  static String mihonPageRequestId(MihonMangaPageRef page) =>
      _pageRequestIds[page] ??= 'page-${_nextPageRequestId++}-${page.index}';

  static final Expando<String> _pageRequestIds = Expando<String>(
    'mihonPageRequestId',
  );
  static int _nextPageRequestId = 0;

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
    // 只等本地就绪段：[MihonManager.contextForSource] 只用已装扩展与库里的源
    // 偏好，不需要仓库目录。等完整 `initialise()` 会让冷启动后第一次开在线章
    // 陪着等仓库索引 + 下载量的网络请求（仓库多 / 连不上时以分钟计）。
    await manager.ensureLocalReady();
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

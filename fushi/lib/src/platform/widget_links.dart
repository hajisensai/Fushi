import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:fushi/src/anki/source_review_navigation.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/platform/app_shortcut_router.dart'
    show unwindToHomeRoute;

/// 桌面小组件里一条「继续」卡的媒体种类（同时是快照 JSON 的 `kind` 值与深链
/// `kind=` 参数）。书与漫画在数据层同属 EPUB 行，靠 [ModuleId] 区分门控。
enum WidgetMediaKind {
  book(ModuleId.books, HomeTab.books),
  manga(ModuleId.manga, HomeTab.manga),
  video(ModuleId.video, HomeTab.video);

  const WidgetMediaKind(this.module, this.homeTab);

  /// 门控模块：用户在「功能模块」里关掉它，小组件不展示、深链也不落地。
  final ModuleId module;

  /// 目标条目已不存在时落到的首页 tab。
  final HomeTab homeTab;

  /// 快照 JSON 与深链里的字符串值。
  String get wire => name;

  static WidgetMediaKind? tryParse(String? value) {
    for (final WidgetMediaKind kind in values) {
      if (kind.name == value) return kind;
    }
    return null;
  }
}

/// 桌面小组件「打开某个首页 tab」深链的目标（`tab/<wire>`）。有声书挂在书籍下面，
/// 没有自己的 tab。
enum WidgetTab {
  books(ModuleId.books, HomeTab.books),
  manga(ModuleId.manga, HomeTab.manga),
  video(ModuleId.video, HomeTab.video),
  music(ModuleId.music, HomeTab.music),
  games(ModuleId.games, HomeTab.games),
  dictionaries(ModuleId.lookup, HomeTab.dictionaries),
  srs(ModuleId.srs, HomeTab.srs);

  const WidgetTab(this.module, this.homeTab);

  /// 门控模块：关着就退回首页（见 [runWidgetLink]）。
  final ModuleId module;
  final HomeTab homeTab;

  /// 深链里的字符串值。
  String get wire => name;

  /// 小组件快照 / 原生侧用的完整链接。
  String get link => 'fushi://widget/tab/$name';

  static WidgetTab? tryParse(String? value) {
    if (value == null) return null;
    final String lower = value.toLowerCase();
    for (final WidgetTab tab in values) {
      if (tab.name == lower) return tab;
    }
    return null;
  }
}

/// `settings/<wire>` 深链能打开的设置页。
enum WidgetSettingsTarget {
  /// 制卡设置（SRS provider 取决于它）。
  cards,

  /// 主屏幕小组件设置页（目标 / 隐私）。
  widgets;

  String get wire => name;

  static WidgetSettingsTarget? tryParse(String? value) {
    if (value == null) return null;
    final String lower = value.toLowerCase();
    for (final WidgetSettingsTarget t in values) {
      if (t.name == lower) return t;
    }
    return null;
  }
}

/// 「接下来」小组件里一条服务器条目的来源（深链 `server?source=` 的值）。
enum WidgetServerSource {
  /// Jellyfin / Emby / Plex（视频模块）。
  mediaServer,

  /// Audiobookshelf（有声书，书模块）。
  audiobookshelf;

  String get wire => name;

  /// 门控模块：关着时深链不落地。
  ModuleId get module =>
      this == mediaServer ? ModuleId.video : ModuleId.books;

  static WidgetServerSource? tryParse(String? value) {
    if (value == null) return null;
    final String lower = value.toLowerCase();
    for (final WidgetServerSource s in values) {
      if (s.name.toLowerCase() == lower) return s;
    }
    return null;
  }
}

/// Android 桌面小组件点按产生的深链（`fushi://widget/...`）。
///
/// 与长按图标的 [AppShortcut] 刻意分开：那个枚举会被发布成启动器快捷方式，
/// 小组件的点按目标不该混进去。入口是同一个：原生侧把链接当 ACTION_VIEW intent
/// 交给 `receive_intent`，落在 main.dart 的 `handleIncomingUrl`。
///
/// - `fushi://widget/continue?kind=<book|manga|video>&id=<id>`：打开该条目。
/// - `fushi://widget/srs`：开始内置复习。
/// - `fushi://widget/stats`：打开学习统计。
/// - `fushi://widget/open`：只把 app 带到前台。
/// - `fushi://widget/tab/<books|manga|video|music|games|dictionaries|srs>`：切到该 tab。
/// - `fushi://widget/lookup?word=<词>`：打开查词（带词）。
/// - `fushi://widget/settings/<cards|widgets>`：打开对应设置页。
/// - `fushi://widget/vocab`：打开收藏夹（收藏词 / 制卡历史）。
/// - `fushi://widget/downloads`：打开下载中心（浏览 › 下载 › 任务）。
/// - `fushi://widget/server?source=<mediaServer|audiobookshelf>&server=<id>&item=<id>`：
///   打开首页「继续」里的那条服务器条目（与首页点卡同一落地）。
sealed class WidgetLink {
  const WidgetLink();

  static const String _scheme = 'fushi';
  static const String _host = 'widget';

  /// 不是小组件链接返回 `null`；是小组件链接但动作未知（新版本小组件被降级回旧
  /// 版本点开）、或 `continue` 缺合法 `kind`，同样返回 `null`，调用方按「未处理」放行。
  /// `continue` 的 `id` 可以为空（条目已不在时落到对应 tab）。
  static WidgetLink? tryParse(String? value) {
    if (value == null) return null;
    try {
      return _parse(value);
    } on FormatException {
      // 坏的百分号编码在读 `queryParameters` / `pathSegments` 时才抛：当「不是合法链接」。
      return null;
    } on ArgumentError {
      return null;
    }
  }

  static WidgetLink? _parse(String value) {
    final Uri? uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme.toLowerCase() != _scheme ||
        uri.host.toLowerCase() != _host) {
      return null;
    }
    final String action = uri.pathSegments.isEmpty
        ? ''
        : uri.pathSegments.first.toLowerCase();
    switch (action) {
      case 'continue':
        final WidgetMediaKind? kind = WidgetMediaKind.tryParse(
          uri.queryParameters['kind']?.toLowerCase(),
        );
        if (kind == null) return null;
        return WidgetContinueLink(
          kind: kind,
          id: uri.queryParameters['id'] ?? '',
        );
      case 'srs':
        return const WidgetSrsLink();
      case 'stats':
        return const WidgetStatsLink();
      case 'open':
        return const WidgetOpenLink();
      case 'tab':
        final WidgetTab? tab = WidgetTab.tryParse(
          uri.pathSegments.length > 1 ? uri.pathSegments[1] : null,
        );
        return tab == null ? null : WidgetTabLink(tab);
      case 'lookup':
        final String word = (uri.queryParameters['word'] ?? '').trim();
        return word.isEmpty ? null : WidgetLookupLink(word);
      case 'settings':
        final WidgetSettingsTarget? target = WidgetSettingsTarget.tryParse(
          uri.pathSegments.length > 1 ? uri.pathSegments[1] : null,
        );
        return target == null ? null : WidgetSettingsLink(target);
      case 'vocab':
        return const WidgetVocabLink();
      case 'downloads':
        return const WidgetDownloadsLink();
      case 'server':
        final WidgetServerSource? source = WidgetServerSource.tryParse(
          uri.queryParameters['source'],
        );
        final String server = uri.queryParameters['server'] ?? '';
        final String item = uri.queryParameters['item'] ?? '';
        if (source == null || server.isEmpty || item.isEmpty) return null;
        return WidgetServerLink(source: source, serverId: server, itemId: item);
    }
    return null;
  }
}

final class WidgetContinueLink extends WidgetLink {
  const WidgetContinueLink({required this.kind, required this.id});

  final WidgetMediaKind kind;

  /// 书 / 漫画 = `MediaItem.mediaIdentifier`，视频 = `VideoBookRow.bookUid`；
  /// 空串 = 没有具体条目。
  final String id;

  @override
  bool operator ==(Object other) =>
      other is WidgetContinueLink && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => 'WidgetContinueLink($kind, $id)';
}

final class WidgetSrsLink extends WidgetLink {
  const WidgetSrsLink();
}

final class WidgetStatsLink extends WidgetLink {
  const WidgetStatsLink();
}

final class WidgetOpenLink extends WidgetLink {
  const WidgetOpenLink();
}

final class WidgetTabLink extends WidgetLink {
  const WidgetTabLink(this.tab);

  final WidgetTab tab;

  @override
  bool operator ==(Object other) => other is WidgetTabLink && other.tab == tab;

  @override
  int get hashCode => tab.hashCode;

  @override
  String toString() => 'WidgetTabLink($tab)';
}

final class WidgetLookupLink extends WidgetLink {
  const WidgetLookupLink(this.word);

  /// 已 trim、非空。
  final String word;

  @override
  bool operator ==(Object other) =>
      other is WidgetLookupLink && other.word == word;

  @override
  int get hashCode => word.hashCode;

  @override
  String toString() => 'WidgetLookupLink($word)';
}

final class WidgetSettingsLink extends WidgetLink {
  const WidgetSettingsLink(this.target);

  final WidgetSettingsTarget target;

  @override
  bool operator ==(Object other) =>
      other is WidgetSettingsLink && other.target == target;

  @override
  int get hashCode => target.hashCode;

  @override
  String toString() => 'WidgetSettingsLink($target)';
}

final class WidgetVocabLink extends WidgetLink {
  const WidgetVocabLink();
}

final class WidgetDownloadsLink extends WidgetLink {
  const WidgetDownloadsLink();
}

final class WidgetServerLink extends WidgetLink {
  const WidgetServerLink({
    required this.source,
    required this.serverId,
    required this.itemId,
  });

  final WidgetServerSource source;
  final String serverId;

  /// 与 `ServerContinueCandidate.itemId` 同口径（ABS 播客集是 `<item>/<episode>`）。
  final String itemId;

  /// 快照里给原生侧的完整链接（参数做百分号编码）。
  static String build({
    required WidgetServerSource source,
    required String serverId,
    required String itemId,
  }) => Uri(
    scheme: WidgetLink._scheme,
    host: WidgetLink._host,
    path: '/server',
    queryParameters: <String, String>{
      'source': source.wire,
      'server': serverId,
      'item': itemId,
    },
  ).toString();

  /// 首页 feed 里的候选键（`ServerContinueCandidate.key`）。
  String get key => '${source.name}|$serverId|$itemId';

  @override
  bool operator ==(Object other) =>
      other is WidgetServerLink &&
      other.source == source &&
      other.serverId == serverId &&
      other.itemId == itemId;

  @override
  int get hashCode => Object.hash(source, serverId, itemId);

  @override
  String toString() => 'WidgetServerLink($source, $serverId, $itemId)';
}

/// 小组件深链的冷启动排队，与 `AppShortcutQueue` 同口径：冷启动时 URL 比
/// `initialise()` 先到，而 HomePage.initState 会把首页 tab 重置成启动 tab，所以先
/// 存着，等 home 挂载后的首帧再落地；连点多次只落最后一条。
class WidgetLinkQueue {
  WidgetLinkQueue({required this.isActive, required this.run});

  /// 宿主（根 widget）是否还挂着；帧回调跑到时已卸载就丢弃。
  final bool Function() isActive;

  /// 真正的落地动作（见 [runWidgetLink]）。
  final Future<void> Function(WidgetLink link) run;

  WidgetLink? _pending;
  bool _scheduled = false;

  @visibleForTesting
  WidgetLink? get pending => _pending;

  /// URL 到达：先存下；[ready] 时立刻排到下一帧，未就绪由宿主在就绪后的 build
  /// 里调 [schedule]。
  void enqueue(WidgetLink link, {required bool ready}) {
    _pending = link;
    if (ready) schedule();
  }

  /// 有排队的链接就在下一帧落地。根 build 每次都会调，重复调用是 no-op。
  void schedule() {
    if (_scheduled || _pending == null) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      final WidgetLink? link = _pending;
      _pending = null;
      if (link != null && isActive()) unawaited(run(link));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }
}

/// 落地一条小组件深链。
///
/// - [WidgetOpenLink]：什么都不做（点按本身已把 app 带到前台）。
/// - 目标模块已关：什么都不做（旧小组件还没刷新时点到，不能切 tab 也不能把用户
///   正在看的页面退掉）。
/// - 新手引导未完成：只切 tab，不动路由栈。
/// - 其余：先切 tab、逐层退回首页根路由（与快捷方式同一条
///   [ExternalMediaNavigation] 队列），回到根路由后再打开目标；退不回根（媒体页
///   拒绝关闭 / 有未保存对话框）就停在原地。打开目标本身**不**占着队列等它关闭
///   （阅读器 / 复习页会一直开着），所以排在队列之外。
///   - 继续：目标条目此刻已经开着（用户最小化 app 后又点小组件）时
///     [isContinueItemOpen] 为 true，什么都不做——点按本身已把 app 带回前台，退到首页
///     再重开会丢掉当前页面状态；[openContinueItem] 返回 false（条目已不存在）时留在
///     对应 tab。
///   - 复习：[openSrsReview] 返回 false（没有待复习的卡）时留在复习 tab。
///   - 统计：[openStats]。
///   - tab：只切 tab（模块已关 → 回首页，不留在一个不存在的 tab 上）。
///   - 查词：切到词典 tab 后 [openLookup]；词典模块关着时回首页。
///   - 设置：[openSettings]；制卡设置跟制卡模块门控，小组件设置页不门控。
///   - 收藏夹：[openVocab]。
///   - 下载中心：浏览模块开着才落地（切到浏览 tab）；之后 [openDownloads] 切到
///     「下载 › 任务」页签。
///   - 服务器条目：落到首页（让首页「继续」的取数起来），[openServerItem] 返回 false
///     （条目已不在进行中）时留在首页。
Future<void> runWidgetLink(
  WidgetLink link, {
  required ModuleVisibility visibility,
  required bool onboardingCompleted,
  required NavigatorState? navigator,
  required void Function(HomeTab tab) selectHomeTab,
  required Future<bool> Function(WidgetContinueLink link) openContinueItem,
  required Future<bool> Function() openSrsReview,
  required Future<void> Function() openStats,
  required Future<void> Function(String word) openLookup,
  required Future<void> Function(WidgetSettingsTarget target) openSettings,
  required Future<void> Function() openVocab,
  bool Function(WidgetContinueLink link)? isContinueItemOpen,
  ExternalMediaNavigation? media,
  Future<void> Function()? openDownloads,
  Future<bool> Function(WidgetServerLink link)? openServerItem,
}) async {
  if (link is WidgetOpenLink) return;
  if (link is WidgetContinueLink && (isContinueItemOpen?.call(link) ?? false)) {
    return;
  }
  final HomeTab? tab = switch (link) {
    WidgetContinueLink(:final WidgetMediaKind kind) =>
      visibility.isEnabled(kind.module) ? kind.homeTab : null,
    WidgetSrsLink() => visibility.isEnabled(ModuleId.srs) ? HomeTab.srs : null,
    WidgetStatsLink() => HomeTab.home,
    WidgetOpenLink() => null,
    // 目标 tab 的模块关着：回首页（小组件还没刷新时点到旧入口）。
    WidgetTabLink(:final WidgetTab tab) =>
      visibility.isEnabled(tab.module) ? tab.homeTab : HomeTab.home,
    WidgetLookupLink() =>
      visibility.isEnabled(ModuleId.lookup) ? HomeTab.dictionaries : null,
    WidgetSettingsLink(:final WidgetSettingsTarget target) =>
      target == WidgetSettingsTarget.cards &&
              !visibility.isEnabled(ModuleId.cardCreation)
          ? HomeTab.home
          : HomeTab.settings,
    WidgetVocabLink() => HomeTab.home,
    WidgetDownloadsLink() =>
      visibility.isEnabled(ModuleId.browse) ? HomeTab.browse : null,
    WidgetServerLink(:final WidgetServerSource source) =>
      visibility.isEnabled(source.module) ? HomeTab.home : null,
  };
  if (tab == null) return;
  if (!onboardingCompleted) {
    selectHomeTab(tab);
    return;
  }
  final ExternalMediaNavigation mediaNavigation =
      media ?? ExternalMediaNavigation.instance;
  bool atHomeRoot = false;
  await mediaNavigation.navigate(() async {
    selectHomeTab(tab);
    if (navigator == null) return;
    await unwindToHomeRoute(navigator, media: mediaNavigation);
    atHomeRoot = navigator.mounted && !navigator.canPop();
  });
  if (!atHomeRoot) return;
  switch (link) {
    case WidgetContinueLink():
      await openContinueItem(link);
    case WidgetSrsLink():
      await openSrsReview();
    case WidgetStatsLink():
      await openStats();
    case WidgetOpenLink():
    case WidgetTabLink():
      break;
    case WidgetLookupLink(:final String word):
      await openLookup(word);
    case WidgetSettingsLink(:final WidgetSettingsTarget target):
      if (target == WidgetSettingsTarget.cards &&
          !visibility.isEnabled(ModuleId.cardCreation)) {
        break;
      }
      await openSettings(target);
    case WidgetVocabLink():
      await openVocab();
    case WidgetDownloadsLink():
      await openDownloads?.call();
    case WidgetServerLink():
      await openServerItem?.call(link);
  }
}

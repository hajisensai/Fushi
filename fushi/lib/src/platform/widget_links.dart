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
sealed class WidgetLink {
  const WidgetLink();

  static const String _scheme = 'fushi';
  static const String _host = 'widget';

  /// 不是小组件链接返回 `null`；是小组件链接但动作未知（新版本小组件被降级回旧
  /// 版本点开）、或 `continue` 缺合法 `kind`，同样返回 `null`，调用方按「未处理」放行。
  /// `continue` 的 `id` 可以为空（条目已不在时落到对应 tab）。
  static WidgetLink? tryParse(String? value) {
    if (value == null) return null;
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
Future<void> runWidgetLink(
  WidgetLink link, {
  required ModuleVisibility visibility,
  required bool onboardingCompleted,
  required NavigatorState? navigator,
  required void Function(HomeTab tab) selectHomeTab,
  required Future<bool> Function(WidgetContinueLink link) openContinueItem,
  required Future<bool> Function() openSrsReview,
  required Future<void> Function() openStats,
  bool Function(WidgetContinueLink link)? isContinueItemOpen,
  ExternalMediaNavigation? media,
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
      break;
  }
}

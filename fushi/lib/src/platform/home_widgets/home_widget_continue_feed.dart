import 'package:flutter/widgets.dart';

import 'package:fushi/src/platform/home_widgets/home_widget_snapshot.dart';

/// 首页「继续」的一条，交给小组件用（封面仍是首页自己那条取图链给的 [ImageProvider]）。
@immutable
class HomeWidgetContinueSource {
  const HomeWidgetContinueSource({
    required this.key,
    required this.kind,
    required this.title,
    required this.subtitle,
    this.progress,
    this.progressLabel,
    this.cover,
    this.coverKey,
  });

  /// 稳定身份（`book:<mediaIdentifier>` / `video:<bookUid>` / `game:<id>` /
  /// `remote:<id>` / `server:<serverId>:<itemId>`），也是深链 `fushi://continue/<key>`。
  final String key;
  final HomeWidgetItemKind kind;
  final String title;
  final String subtitle;
  final double? progress;
  final String? progressLabel;
  final ImageProvider? cover;

  /// 封面缓存键（换了封面就换键）；null = 用 [cover] 的 `toString()`。
  final String? coverKey;

  String get signature =>
      '$key|$title|$subtitle|${progress?.toStringAsFixed(3)}|$progressLabel|'
      '${coverKey ?? cover?.toString()}';
}

/// 首页 ↔ 小组件的接线板。
///
/// 「继续」只在首页里算（模块门控、远端 / 服务器补位、合集折叠都在那儿），所以由首页
/// 每次算完 [publish]，小组件宿主监听 [items]；点小组件进来时 [requestOpen]，由首页用与
/// 点卡片完全相同的打开函数处理——不在别处再写一份打开逻辑。
class HomeWidgetContinueFeed {
  HomeWidgetContinueFeed._();

  static final HomeWidgetContinueFeed instance = HomeWidgetContinueFeed._();

  /// null = 首页还没算过（冷启动）。
  final ValueNotifier<List<HomeWidgetContinueSource>?> items =
      ValueNotifier<List<HomeWidgetContinueSource>?>(null);

  /// 首页重新聚合了一轮（统计 / 进度可能变了）：小组件宿主据此重算学习段。
  final ValueNotifier<int> dashboardReloads = ValueNotifier<int>(0);

  /// 等首页打开的条目键。首页处理后清空。
  final ValueNotifier<String?> pendingOpen = ValueNotifier<String?>(null);

  String? _lastSignature;

  void publish(List<HomeWidgetContinueSource> next) {
    final String signature = next
        .map((HomeWidgetContinueSource s) => s.signature)
        .join('\n');
    if (signature == _lastSignature) return;
    _lastSignature = signature;
    items.value = List<HomeWidgetContinueSource>.unmodifiable(next);
  }

  void notifyDashboardReloaded() => dashboardReloads.value++;

  void requestOpen(String key) {
    // 同一键连点两次也要再触发一次：先清后设。
    pendingOpen.value = null;
    pendingOpen.value = key;
  }

  @visibleForTesting
  void resetForTest() {
    _lastSignature = null;
    items.value = null;
    pendingOpen.value = null;
  }
}

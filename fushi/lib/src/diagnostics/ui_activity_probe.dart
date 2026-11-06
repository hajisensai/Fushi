// 内存采样探针（[PreviousExitLog.startMemorySampling]）：采样窗口里出了几帧、此刻用户看得见哪些页面。
//
// BUG-4075：同一台 Android 停在 SRS 页 / 小说统计页不动，native malloc 以约 10 MB/s 匀速上涨直到
// Scudo OOM，SRS 账本证明那几分钟 SRS 零活动。匀速上涨的形态像「每帧泄漏」，但采样里没有两样证据：
// ① 停着不动时是否仍在持续出帧（有东西在逐帧重绘）；② 当时停在哪一页（根导航的路由大多是匿名
// MaterialPageRoute，首页各 tab 也不是路由）。本探针补这两样：
//
// - `frames=N`：上次采样以来 [SchedulerBinding] 跑过的帧数（持久帧回调计数，O(1)）；
// - `page=[A>B]`：沿元素树找类型名以 `Page` 结尾的 widget，跳过 `TickerMode(enabled: false)` 的子树
//   ——被盖住的路由、IndexedStack 里没显示的 tab 都在那种子树里，它们的动画不跑、不会逐帧画。
//   顺序 = 树中先序（外层在前，栈顶路由在后）；
// - `tick=[A×3 B]`：同一趟走树里数各 widget 持有的活跃 ticker（23876 报告停在牌组列表每 30 s 出
//   3400+ 帧，要点名是谁在逐帧跑）。frames 高而 tick 为空 = 出帧不是 ticker 驱动的（动图、视频纹理、
//   平台视图、手动 scheduleFrame）；
// - `build=N who=[site×k; …]`：23878 报告停在牌组列表满 120 fps 出帧、tick 却为空，本地单独挂牌组页
//   静止后不排帧——要帧的不是动画。这里套住 [BuildOwner.onBuildScheduled]（任何 setState /
//   markNeedsBuild 在一帧里第一次弄脏元素时都经它要帧），数窗口里「因重建而要帧」的次数，并按
//   [kUiActivityStackSampleInterval] 节流抓调用栈、取第一个应用自己的栈帧记成 `函数@文件:行`。
//   frames ≫ build = 出帧不是重建驱动（纹理 / 平台视图 / 纯重绘），who 直接点名谁在逐帧 setState。

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

/// `page=[…]` 最多列几个页面（取最后几个：最靠里 / 最靠栈顶的那些）。
const int kUiActivityMaxPages = 4;

/// 一次走树最多访问的元素数：超过就停（取证不能反过来卡 UI 线程）。
const int kUiActivityMaxElements = 200000;

/// 采样窗口帧计数 + 可见页面。全进程一份，[install] 在生产启动时调一次。
abstract final class UiActivityProbe {
  static int _frames = 0;
  static int _builds = 0;
  static final Map<String, int> _buildSites = <String, int>{};
  static final Stopwatch _sinceStack = Stopwatch();
  static bool _installed = false;

  /// 挂上持久帧回调与重建要帧钩子（幂等）。持久帧回调没有注销接口，所以只在生产启动时装一次。
  static void install() {
    if (_installed) return;
    _installed = true;
    SchedulerBinding.instance.addPersistentFrameCallback((Duration _) {
      _frames++;
    });
    final BuildOwner? owner = WidgetsBinding.instance.buildOwner;
    if (owner != null) {
      final VoidCallback? framework = owner.onBuildScheduled;
      owner.onBuildScheduled = () {
        recordBuildScheduled(StackTrace.current);
        framework?.call();
      };
    }
  }

  /// 记一次「因重建要帧」：计数，并在距上次抓栈超过 [kUiActivityStackSampleInterval] 时记下调用点。
  @visibleForTesting
  static void recordBuildScheduled(StackTrace stack) {
    _builds++;
    if (_sinceStack.isRunning &&
        _sinceStack.elapsed < kUiActivityStackSampleInterval) {
      return;
    }
    _sinceStack
      ..reset()
      ..start();
    final String site = buildSiteOf(stack.toString());
    _buildSites.update(site, (int n) => n + 1, ifAbsent: () => 1);
  }

  /// 测试收尾：清零计数。
  @visibleForTesting
  static void resetFrames() {
    _frames = 0;
    _builds = 0;
    _buildSites.clear();
    _sinceStack
      ..stop()
      ..reset();
  }

  /// 取走窗口帧数并清零，附上此刻可见页面与活跃 ticker 的持有者：
  /// `frames=123 page=[HomePage>SrsHomePage] tick=[FushiWavyLinearProgress×3]`。
  static String? probe() {
    final int frames = _frames;
    _frames = 0;
    final int builds = _builds;
    _builds = 0;
    final Map<String, int> sites = Map<String, int>.of(_buildSites);
    _buildSites.clear();
    final UiActivitySnapshot snap = scanUiActivity(
      WidgetsBinding.instance.rootElement,
    );
    final List<String> parts = <String>[
      if (_installed) 'frames=$frames',
      if (snap.pages.isNotEmpty) 'page=[${snap.pages.join('>')}]',
      if (snap.tickers.isNotEmpty)
        'tick=[${describeTickerOwners(snap.tickers)}]',
      if (_installed) 'build=$builds',
      if (sites.isNotEmpty)
        'who=[${describeTickerOwners(sites, max: kUiActivityMaxBuildSites, separator: '; ')}]',
    ];
    return parts.isEmpty ? null : parts.join(' ');
  }
}

/// 一次走树的结果：可见页面（外层在前）与活跃 ticker 持有者（widget 类型名 → 活跃 ticker 数）。
typedef UiActivitySnapshot = ({List<String> pages, Map<String, int> tickers});

/// `tick=[…]` 最多列几个持有者（按活跃 ticker 数降序，其余记 `+N`）。
const int kUiActivityMaxTickerOwners = 6;

/// `who=[…]` 最多列几个调用点。
const int kUiActivityMaxBuildSites = 4;

/// 重建要帧时抓调用栈的最小间隔：120 fps 下每 30 s 最多抓约 150 次，抓栈本身不成为负担。
const Duration kUiActivityStackSampleInterval = Duration(milliseconds: 200);

/// 从调用栈文本里取第一个不属于框架 / SDK / 本探针的栈帧，格式 `函数@文件:行`；找不到记 `?`。
///
/// 框架帧（`package:flutter/`、`dart:`、riverpod 的通知分发）只说明「有人 setState」，不说明是谁，
/// 跳过它们才落到真正逐帧弄脏元素的应用代码。
@visibleForTesting
String buildSiteOf(String stack) {
  final RegExp frame = RegExp(r'^#\d+\s+(.+?) \((.+?):(\d+)(?::\d+)?\)$');
  for (final String line in stack.split('\n')) {
    final RegExpMatch? m = frame.firstMatch(line.trim());
    if (m == null) continue;
    final String uri = m.group(2)!;
    if (uri.startsWith('dart:') ||
        uri.startsWith('package:flutter/') ||
        uri.startsWith('package:flutter_riverpod/') ||
        uri.startsWith('package:riverpod/') ||
        uri.startsWith('package:stack_trace/') ||
        uri.endsWith('/ui_activity_probe.dart')) {
      continue;
    }
    final String file = uri.substring(uri.lastIndexOf('/') + 1);
    return '${m.group(1)}@$file:${m.group(3)}';
  }
  return '?';
}

/// 从 [root] 先序走元素树，跳过 `TickerMode(enabled: false)` 的子树（里面的 ticker 被静音、不驱动出帧）：
///
/// - 收集类型名以 `Page` 结尾的 widget（相邻重复只记一次），只留最后 [maxPages] 个；
/// - 对混入了 [SingleTickerProviderStateMixin] / [TickerProviderStateMixin] 的 State，数它持有的
///   活跃且未静音的 ticker——每个活跃 ticker 每个 vsync 都要一帧，持续出帧时这里点名是谁在跑。
///   ticker 是 mixin 私有字段，只能经它们的 `debugFillProperties`（release 也在）取到对象本身。
///
/// [root] 为空返回空结果。
@visibleForTesting
UiActivitySnapshot scanUiActivity(
  Element? root, {
  int maxPages = kUiActivityMaxPages,
  int maxElements = kUiActivityMaxElements,
}) {
  final List<String> pages = <String>[];
  final Map<String, int> tickers = <String, int>{};
  if (root == null) return (pages: pages, tickers: tickers);
  int visited = 0;
  void visit(Element element) {
    if (visited >= maxElements) return;
    visited++;
    final Widget widget = element.widget;
    if (widget is TickerMode && !widget.enabled) return;
    final String name = _typeName(widget);
    if (name.endsWith('Page') && (pages.isEmpty || pages.last != name)) {
      pages.add(name);
    }
    if (element is StatefulElement) {
      final int active = _activeTickerCount(element.state);
      if (active > 0) {
        tickers.update(name, (int n) => n + active, ifAbsent: () => active);
      }
    }
    element.visitChildElements(visit);
  }

  visit(root);
  return (
    pages: pages.length <= maxPages
        ? pages
        : pages.sublist(pages.length - maxPages),
    tickers: tickers,
  );
}

/// `A×3 B +2`：按活跃 ticker 数降序取前 [max] 个持有者，数量为 1 不写倍数。
@visibleForTesting
String describeTickerOwners(
  Map<String, int> tickers, {
  int max = kUiActivityMaxTickerOwners,
  String separator = ' ',
}) {
  final List<MapEntry<String, int>> sorted = tickers.entries.toList()
    ..sort((MapEntry<String, int> a, MapEntry<String, int> b) {
      final int byCount = b.value.compareTo(a.value);
      return byCount != 0 ? byCount : a.key.compareTo(b.key);
    });
  final List<String> out = <String>[
    for (final MapEntry<String, int> e in sorted.take(max))
      e.value == 1 ? e.key : '${e.key}×${e.value}',
    if (sorted.length > max) '+${sorted.length - max}',
  ];
  return out.join(separator);
}

String _typeName(Widget widget) {
  final String full = widget.runtimeType.toString();
  final int generic = full.indexOf('<');
  return generic < 0 ? full : full.substring(0, generic);
}

/// [state] 持有的活跃且未静音的 ticker 数；不是 ticker 提供者或读不出来为 0。
int _activeTickerCount(State<StatefulWidget> state) {
  if (state is! SingleTickerProviderStateMixin &&
      state is! TickerProviderStateMixin) {
    return 0;
  }
  final DiagnosticPropertiesBuilder props = DiagnosticPropertiesBuilder();
  try {
    state.debugFillProperties(props);
  } on Object {
    return 0;
  }
  int active = 0;
  bool counts(Object? t) => t is Ticker && t.isActive && !t.muted;
  for (final DiagnosticsNode node in props.properties) {
    if (node is! DiagnosticsProperty<Object?>) continue;
    final Object? value = node.value;
    if (counts(value)) {
      active++;
    } else if (value is Iterable<Object?>) {
      active += value.where(counts).length;
    }
  }
  return active;
}

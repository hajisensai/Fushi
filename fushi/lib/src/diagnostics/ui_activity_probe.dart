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
// - `req=N fcb=[site×n; …] fvis=[site×k; …]`：#w-MhvbxSFc 停在牌组列表 120 fps、build≈0、tick 空——
//   build= 与 tick= 都绕开了的要帧来源只剩两类：① 不在元素树里的帧回调（State 已 dispose 后又被
//   异步回调启动的「孤儿 ticker」、非 State 的 scheduleFrameCallback）；② render object 在帧外
//   markNeedsPaint / markNeedsLayout。两类最终都经 [SchedulerBinding.scheduleFrame] 向引擎要帧，
//   [FushiWidgetsFlutterBinding] 在那里拦一刀：`req` = 窗口里真正发出的要帧次数；
//   `fcb` = 由帧回调发出的要帧，按**注册 / 启动该回调的调用点**精确计数（ticker 逐帧续排时栈里只有
//   框架，所以在它第一次注册时记下调用点、之后按回调身份归账，孤儿 ticker 也逃不掉）；
//   `fvis` = 其余要帧（render object 弄脏、重建、平台消息），按间隔节流抓栈取调用点。
// - `layers=[PictureLayer×40 …]`：此刻合成树里各类 layer 的数量（每帧都要把整棵树重新光栅化，
//   逐帧涨原生内存时看是哪类 layer：BackdropFilter / ShaderMask / Texture / PlatformView …）。

import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart'
    show ContainerLayer, Layer, RenderView, RendererBinding;
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

  // ---- 要帧归因（由 [FushiWidgetsFlutterBinding] 喂；没换 binding 时全为空，不输出）----

  static int _requests = 0;
  static final Map<String, int> _callbackRequestSites = <String, int>{};
  static final Map<String, int> _otherRequestSites = <String, int>{};
  static final Stopwatch _sinceRequestStack = Stopwatch();

  /// 帧回调 → 注册 / 启动它的调用点。Ticker 每次续排传的是同一个 `_tick` tear-off（同一接收者的
  /// tear-off 相等），所以按 `==` 归账。按插入序淘汰最旧的，上限 [kUiActivityMaxCallbackSites]。
  static final LinkedHashMap<Function, String> _callbackSites =
      LinkedHashMap<Function, String>();

  /// 正在 [beginFrameCallbackRegistration] 与 [endFrameCallbackRegistration] 之间：这期间的要帧
  /// 归给这个调用点。
  static String? _registeringSite;

  /// 帧回调注册开始（[SchedulerBinding.scheduleFrameCallback] 入口）。首次注册（`rescheduling`
  /// 为 false：Ticker.start / 解除静音、动图下一帧……）抓栈记下调用点；逐帧续排直接按回调身份查。
  /// [stack] 只给测试用，生产传 null 取当前栈。
  static void beginFrameCallbackRegistration(
    Function callback, {
    required bool rescheduling,
    StackTrace? stack,
  }) {
    String? site = _callbackSites[callback];
    if (rescheduling && site != null) {
      // 还活着的回调挪到队尾，不被后来大量短命 ticker 挤出去（常驻的孤儿 ticker 正是要找的那个）。
      _callbackSites
        ..remove(callback)
        ..[callback] = site;
    } else {
      final String fresh = frameRequestSiteOf(
        (stack ?? StackTrace.current).toString(),
      );
      // 已有具体调用点时，不被后来的「全是框架」的注册（如 TickerMode 解除静音）覆盖成 `~`/`?`。
      if (site == null || !_isVague(fresh)) {
        _callbackSites.remove(callback);
        _callbackSites[callback] = fresh;
        if (_callbackSites.length > kUiActivityMaxCallbackSites) {
          _callbackSites.remove(_callbackSites.keys.first);
        }
        site = fresh;
      }
    }
    _registeringSite = site;
  }

  /// 帧回调注册结束。
  static void endFrameCallbackRegistration() {
    _registeringSite = null;
  }

  /// [SchedulerBinding.scheduleFrame] 真正要向引擎要一帧时调（已排过帧 / 帧被禁用时不调）。
  /// [stack] 只给测试用。
  static void recordFrameRequest({StackTrace? stack}) {
    _requests++;
    final String? registering = _registeringSite;
    if (registering != null) {
      _callbackRequestSites.update(
        registering,
        (int n) => n + 1,
        ifAbsent: () => 1,
      );
      return;
    }
    if (_sinceRequestStack.isRunning &&
        _sinceRequestStack.elapsed < kUiActivityStackSampleInterval) {
      return;
    }
    _sinceRequestStack
      ..reset()
      ..start();
    final String site = frameRequestSiteOf(
      (stack ?? StackTrace.current).toString(),
    );
    _otherRequestSites.update(site, (int n) => n + 1, ifAbsent: () => 1);
  }

  static bool _isVague(String site) => site == '?' || site.startsWith('~');

  /// 测试收尾：清零计数。
  @visibleForTesting
  static void resetFrames() {
    _frames = 0;
    _builds = 0;
    _buildSites.clear();
    _sinceStack
      ..stop()
      ..reset();
    _requests = 0;
    _callbackRequestSites.clear();
    _otherRequestSites.clear();
    _callbackSites.clear();
    _registeringSite = null;
    _sinceRequestStack
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
    final int requests = _requests;
    _requests = 0;
    final Map<String, int> callbackRequests = Map<String, int>.of(
      _callbackRequestSites,
    );
    _callbackRequestSites.clear();
    final Map<String, int> otherRequests = Map<String, int>.of(
      _otherRequestSites,
    );
    _otherRequestSites.clear();
    final UiActivitySnapshot snap = scanUiActivity(
      WidgetsBinding.instance.rootElement,
    );
    final Map<String, int> layers = countLayers(
      RendererBinding.instance.renderViews,
    );
    final List<String> parts = <String>[
      if (_installed) 'frames=$frames',
      if (snap.pages.isNotEmpty) 'page=[${snap.pages.join('>')}]',
      if (snap.tickers.isNotEmpty)
        'tick=[${describeTickerOwners(snap.tickers)}]',
      if (_installed) 'build=$builds',
      if (sites.isNotEmpty)
        'who=[${describeTickerOwners(sites, max: kUiActivityMaxBuildSites, separator: '; ')}]',
      if (requests > 0) 'req=$requests',
      if (callbackRequests.isNotEmpty)
        'fcb=[${describeTickerOwners(callbackRequests, max: kUiActivityMaxBuildSites, separator: '; ')}]',
      if (otherRequests.isNotEmpty)
        'fvis=[${describeTickerOwners(otherRequests, max: kUiActivityMaxBuildSites, separator: '; ')}]',
      if (layers.isNotEmpty)
        'layers=[${describeTickerOwners(layers, max: kUiActivityMaxLayerTypes)}]',
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
        uri.endsWith('/ui_activity_probe.dart') ||
        uri.endsWith('/fushi_binding.dart')) {
      continue;
    }
    final String file = uri.substring(uri.lastIndexOf('/') + 1);
    return '${m.group(1)}@$file:${m.group(3)}';
  }
  return '?';
}

/// 记住多少个帧回调的注册调用点（每个活着的 ticker / 动图各占一个）。
const int kUiActivityMaxCallbackSites = 512;

/// `layers=[…]` 最多列几类 layer。
const int kUiActivityMaxLayerTypes = 10;

/// 一次 layer 普查最多访问的 layer 数。
const int kUiActivityMaxLayers = 50000;

/// 要帧调用链最多记几帧。
const int kUiActivityMaxChainFrames = 10;

/// 要帧调用点：先取第一个应用栈帧（同 [buildSiteOf]）；整栈都是框架 / SDK 时，记**原始调用链**：
/// 去掉探针与 binding 自身后栈顶最多 [kUiActivityMaxChainFrames] 帧，`~` 开头、`<` 相连，
/// 每帧 `函数(文件:行)`（如 `~SchedulerBinding.scheduleFrame(binding.dart:957)<…`）。
///
/// #AaRXcVUaXv：上一版此时只挑「第一个非调度框架帧」，结果整栈都落在调度 / 渲染 / dart:ui 里的
/// 那种要帧被记成 `?`，恰好丢掉了最关键的那条链。不用 `@` 连接：日志脱敏会把 `x@y:n` 当邮箱抹掉。
/// 不符合 `#n 函数 (uri:行)` 格式的行（AOT 未符号化帧等）截断后原样记入。
@visibleForTesting
String frameRequestSiteOf(String stack) {
  final String app = buildSiteOf(stack);
  if (app != '?') return app;
  final RegExp frame = RegExp(r'^#\d+\s+(.+?) \((.+?)(?::(\d+))?(?::\d+)?\)$');
  final List<String> chain = <String>[];
  for (final String raw in stack.split('\n')) {
    final String line = raw.trim();
    if (line.isEmpty) continue;
    if (chain.length >= kUiActivityMaxChainFrames) break;
    final RegExpMatch? m = frame.firstMatch(line);
    if (m == null) {
      final String text = line.replaceFirst(RegExp(r'^#\d+\s+'), '');
      chain.add(text.length <= 60 ? text : text.substring(0, 60));
      continue;
    }
    final String uri = m.group(2)!;
    if (uri.endsWith('/ui_activity_probe.dart') ||
        uri.endsWith('/fushi_binding.dart')) {
      continue;
    }
    final String file = uri.substring(uri.lastIndexOf('/') + 1);
    final String? lineNo = m.group(3);
    chain.add('${m.group(1)}($file${lineNo == null ? '' : ':$lineNo'})');
  }
  return chain.isEmpty ? '?' : '~${chain.join('<')}';
}

/// 合成树里各类 layer 的数量（类型名 → 个数），走 [views] 的根 layer，最多 [maxLayers] 个。
@visibleForTesting
Map<String, int> countLayers(
  Iterable<RenderView> views, {
  int maxLayers = kUiActivityMaxLayers,
}) {
  final Map<String, int> counts = <String, int>{};
  int visited = 0;
  void visit(Layer layer) {
    if (visited >= maxLayers) return;
    visited++;
    final String full = layer.runtimeType.toString();
    final int generic = full.indexOf('<');
    final String name = generic < 0 ? full : full.substring(0, generic);
    counts.update(name, (int n) => n + 1, ifAbsent: () => 1);
    if (layer is ContainerLayer) {
      for (Layer? c = layer.firstChild; c != null; c = c.nextSibling) {
        visit(c);
      }
    }
  }

  for (final RenderView view in views) {
    // release 下拿合成树的唯一入口（debugLayer 只在 debug 有值）；只读、只数类型。
    // ignore: invalid_use_of_protected_member
    final Layer? root = view.layer;
    if (root != null) visit(root);
  }
  return counts;
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

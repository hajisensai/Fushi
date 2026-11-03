import 'package:meta/meta.dart';

/// 媒体页「跳转回退」的历史栈（小说阅读器 / 漫画阅读器 / 视频播放器共用）。
///
/// 浏览器式的后退 / 前进双栈：一次**非连续**移动（跳章、拖进度、点字幕跳转……）
/// 之前把出发点压进后退栈；「返回」把当前位置压进前进栈、弹出后退栈顶作为落点，
/// 「前进」反之；新的跳转作废前进栈。对齐 Apple 图书「返回第 N 页」与 Hoshi 的
/// 章节跳转来回。
///
/// 纯数据结构，不碰 UI / 播放器：位置类型 [T] 与落地方式由各页决定，同一处的判据
/// 由 [isSamePlace] 给出（连点同一目录项、来回点同一句不重复压栈）。
/// 一次跳转的来源动作（「跳转记录」面板里那一行的副标题）。纯数据，文案由 UI 层
/// 映射；null 表示调用点没声明（面板只写时间）。
enum JumpSource {
  /// 目录选章。
  tableOfContents,

  /// 正文内链 / 脚注。
  link,

  /// 全文搜索结果。
  search,

  /// 收藏句 / 书签。
  favorite,

  /// 字数 / 百分比定位。
  positionJump,

  /// 图库 / 页面一览。
  gallery,

  /// 拖动 / 点击进度条、页码滑块松手。
  progressBar,

  /// 点句（有声书句子、字幕列表）。
  cue,

  /// 章节跳转（上一章 / 下一章、章节列表）。
  chapter,

  /// 跳页对话框。
  pageDialog,

  /// 回到开头。
  restart,

  /// 查词浮层「跳到此句」。
  lookup,

  /// 遥控 / 控制通道（`fushi_cli`）。
  remote,
}

/// 历史栈里的一条：位置 + 记下的时刻 + 来源动作。
@immutable
class JumpHistoryEntry<T> {
  const JumpHistoryEntry({required this.point, required this.at, this.source});

  final T point;

  /// 记下这一条的时刻（离开这里 / 走返回、前进经过这里的那一刻）。
  final DateTime at;

  /// 从这里离开时的动作；返回 / 前进途经时压入的条目为 null。
  final JumpSource? source;

  JumpHistoryEntry<T> withPoint(T next) =>
      JumpHistoryEntry<T>(point: next, at: at, source: source);
}

class JumpHistory<T> {
  JumpHistory({required this.isSamePlace, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// 栈深上限：超出丢最旧的一条。
  static const int maxDepth = 50;

  final bool Function(T a, T b) isSamePlace;
  final DateTime Function() _clock;

  final List<JumpHistoryEntry<T>> _back = <JumpHistoryEntry<T>>[];
  final List<JumpHistoryEntry<T>> _forward = <JumpHistoryEntry<T>>[];

  /// 后退栈，**由旧到新**（末尾 = 「返回」的落点）。只读视图。
  List<JumpHistoryEntry<T>> get backEntries =>
      List<JumpHistoryEntry<T>>.unmodifiable(_back);

  /// 前进栈，**由远到近**（末尾 = 「前进」的落点）。只读视图。
  List<JumpHistoryEntry<T>> get forwardEntries =>
      List<JumpHistoryEntry<T>>.unmodifiable(_forward);

  bool get canGoBack => _back.isNotEmpty;
  bool get canGoForward => _forward.isNotEmpty;
  bool get isEmpty => _back.isEmpty && _forward.isEmpty;

  /// 「返回」将落到的点（栈顶），没有为 null。
  T? get backTarget => _back.isEmpty ? null : _back.last.point;

  /// 「前进」将落到的点，没有为 null。
  T? get forwardTarget => _forward.isEmpty ? null : _forward.last.point;

  /// 一次新的跳转即将离开 [origin]：压进后退栈，前进栈作废（与浏览器一致）。
  /// 与栈顶同一处时不重复压。返回是否真的压了栈。
  ///
  /// [source] 是这次跳转的动作（面板副标题）；与栈顶同一处时只刷新栈顶的时刻与
  /// 来源，不新增条目。
  bool recordDeparture(T origin, {JumpSource? source}) {
    _forward.clear();
    final T? top = backTarget;
    final JumpHistoryEntry<T> entry = JumpHistoryEntry<T>(
      point: origin,
      at: _clock(),
      source: source,
    );
    if (top != null && isSamePlace(top, origin)) {
      // 位置保留栈顶原值：只用新出发点覆盖的话，连续几次「同一处」的出发点会
      // 一路漂移（视频 1 秒内算同一处：60000 → 60900 → 61000…）。
      _back[_back.length - 1] = JumpHistoryEntry<T>(
        point: top,
        at: entry.at,
        source: entry.source,
      );
      return false;
    }
    _push(_back, entry);
    return true;
  }

  /// 「返回」：把 [current] 压进前进栈，弹出后退栈顶作为落点。
  T? goBack(T current) => goBackSteps(current, 1);

  /// 一次走 [steps] 步「返回」（面板里点后退栈中的某一条）：途经的条目依次进前进
  /// 栈，与连按 [steps] 次「返回」结果一致。步数超出栈深时返回 null、不动栈。
  T? goBackSteps(T current, int steps) {
    if (steps < 1 || steps > _back.length) return null;
    T here = current;
    for (int i = 0; i < steps; i++) {
      final JumpHistoryEntry<T> target = _back.removeLast();
      _push(_forward, JumpHistoryEntry<T>(point: here, at: _clock()));
      here = target.point;
    }
    return here;
  }

  /// 「前进」：把 [current] 压回后退栈，弹出前进栈顶作为落点。
  T? goForward(T current) => goForwardSteps(current, 1);

  /// [goBackSteps] 的前进版。
  T? goForwardSteps(T current, int steps) {
    if (steps < 1 || steps > _forward.length) return null;
    T here = current;
    for (int i = 0; i < steps; i++) {
      final JumpHistoryEntry<T> target = _forward.removeLast();
      _push(_back, JumpHistoryEntry<T>(point: here, at: _clock()));
      here = target.point;
    }
    return here;
  }

  /// 用 [point] 替换后退栈顶（没有栈顶时什么都不做）：同一次用户动作先后带动了
  /// 两条轴（小说正文跳转随即带动有声书音频）时，把刚压的点升级而不是压两条。
  void replaceBackTop(T point) {
    if (_back.isEmpty) return;
    _back[_back.length - 1] = _back.last.withPoint(point);
  }

  void clear() {
    _back.clear();
    _forward.clear();
  }

  static void _push<T>(
    List<JumpHistoryEntry<T>> stack,
    JumpHistoryEntry<T> entry,
  ) {
    stack.add(entry);
    if (stack.length > maxDepth) stack.removeAt(0);
  }
}

/// 「走 N 步」的单飞执行器：返回 / 前进 / 面板跳转共用。
///
/// 采样「当前在哪」可能是异步的（小说阅读器要经 WebView 读视口位置），所以**在第
/// 一个 await 之前**就占住 [busy]，采样、改栈、恢复都在同一段 try/finally 里，
/// 结束统一放开。连点两下 ↶、或面板跳转与顶栏按钮几乎同时触发时，后来的那次直接
/// 落空——不会两次都越过守卫、各自改栈（连退两步、前进栈压两份同一位置、两个恢复
/// 并发）。[busy] 期间宿主的「记录出发点」也应当跳过（恢复带出的跳转不入栈）。
class JumpHistoryWalker<T> {
  bool _busy = false;

  /// 正在走（采样 / 改栈 / 恢复中）。
  bool get busy => _busy;

  /// 在 [history] 上走 [steps] 步（负 = 返回，正 = 前进）。[here] 按要去的那一点
  /// 采样当前位置（返回 null = 采不到，放弃且不改栈）；改栈后先调 [onStepped]
  /// （图标重新计时等），再 await [restore] 落地。真的走了返回 true。
  Future<bool> walk(
    JumpHistory<T> history,
    int steps, {
    required Future<T?> Function(T destination) here,
    required Future<void> Function(T target) restore,
    void Function()? onStepped,
  }) async {
    if (_busy || steps == 0) return false;
    final List<JumpHistoryEntry<T>> entries = steps < 0
        ? history.backEntries
        : history.forwardEntries;
    final int n = steps.abs();
    if (n > entries.length) return false;
    _busy = true;
    try {
      final T destination = entries[entries.length - n].point;
      final T? current = await here(destination);
      if (current == null) return false;
      final T? target = steps < 0
          ? history.goBackSteps(current, n)
          : history.goForwardSteps(current, n);
      if (target == null) return false;
      onStepped?.call();
      await restore(target);
      return true;
    } finally {
      _busy = false;
    }
  }
}

/// 「跳转记录」顶栏图标自动隐藏的可选秒数（设置分段选项；0 = 不自动隐藏）。
const List<int> kJumpHistoryAutoHideOptions = <int>[0, 30, 60, 300];

/// 自动隐藏的出厂值：不自动隐藏（所有者 2026-11-02「默认不管」）。
const int kJumpHistoryAutoHideDefaultSeconds = 0;

/// 旧的视频专用键 `video_jump_pill_auto_hide_seconds`（选项 5 / 10 / 15 / 0，
/// 旧默认 10 不落库）折算成新档位：没存过 = 新默认；显式 0 = 0；其余秒数折到最短
/// 的非零档位（新档位都比旧的长，「会自动隐藏」这层意图保留）。
int migrateLegacyJumpPillAutoHide(int? legacySeconds) {
  if (legacySeconds == null) return kJumpHistoryAutoHideDefaultSeconds;
  if (legacySeconds <= 0) return 0;
  return kJumpHistoryAutoHideOptions.firstWhere((int s) => s > 0);
}

/// 媒体时间轴位置的文案：满一小时 `h:mm:ss`，否则 `m:ss`（视频播放位置、有声书全书
/// 时间共用；「跳转记录」顶栏 tooltip 与面板行都用它）。
String formatJumpHistoryTime(int ms) {
  final Duration d = Duration(milliseconds: ms < 0 ? 0 : ms);
  final int h = d.inHours;
  final String m = (d.inMinutes % 60).toString().padLeft(h > 0 ? 2 : 1, '0');
  final String s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// 时间轴落点在进度条上的比例（视频播放位置、有声书全书时间共用）：时长未知
/// （未 load / 直播流）时不画（null）。
double? timelineJumpMarkFraction(int pointMs, int? durationMs) {
  if (durationMs == null || durationMs <= 0) return null;
  return pointMs / durationMs;
}

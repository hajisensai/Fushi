/// 媒体页「跳转回退」的历史栈（小说阅读器 / 漫画阅读器 / 视频播放器共用）。
///
/// 浏览器式的后退 / 前进双栈：一次**非连续**移动（跳章、拖进度、点字幕跳转……）
/// 之前把出发点压进后退栈；「返回」把当前位置压进前进栈、弹出后退栈顶作为落点，
/// 「前进」反之；新的跳转作废前进栈。对齐 Apple 图书「返回第 N 页」与 Hoshi 的
/// 章节跳转来回。
///
/// 纯数据结构，不碰 UI / 播放器：位置类型 [T] 与落地方式由各页决定，同一处的判据
/// 由 [isSamePlace] 给出（连点同一目录项、来回点同一句不重复压栈）。
class JumpHistory<T> {
  JumpHistory({required this.isSamePlace});

  /// 栈深上限：超出丢最旧的一条。
  static const int maxDepth = 50;

  final bool Function(T a, T b) isSamePlace;

  final List<T> _back = <T>[];
  final List<T> _forward = <T>[];

  bool get canGoBack => _back.isNotEmpty;
  bool get canGoForward => _forward.isNotEmpty;
  bool get isEmpty => _back.isEmpty && _forward.isEmpty;

  /// 「返回」将落到的点（栈顶），没有为 null。
  T? get backTarget => _back.isEmpty ? null : _back.last;

  /// 「前进」将落到的点，没有为 null。
  T? get forwardTarget => _forward.isEmpty ? null : _forward.last;

  /// 一次新的跳转即将离开 [origin]：压进后退栈，前进栈作废（与浏览器一致）。
  /// 与栈顶同一处时不重复压。返回是否真的压了栈。
  bool recordDeparture(T origin) {
    _forward.clear();
    final T? top = backTarget;
    if (top != null && isSamePlace(top, origin)) return false;
    _push(_back, origin);
    return true;
  }

  /// 「返回」：把 [current] 压进前进栈，弹出后退栈顶作为落点。
  T? goBack(T current) {
    if (_back.isEmpty) return null;
    final T target = _back.removeLast();
    _push(_forward, current);
    return target;
  }

  /// 「前进」：把 [current] 压回后退栈，弹出前进栈顶作为落点。
  T? goForward(T current) {
    if (_forward.isEmpty) return null;
    final T target = _forward.removeLast();
    _push(_back, current);
    return target;
  }

  /// 用 [point] 替换后退栈顶（没有栈顶时什么都不做）：同一次用户动作先后带动了
  /// 两条轴（小说正文跳转随即带动有声书音频）时，把刚压的点升级而不是压两条。
  void replaceBackTop(T point) {
    if (_back.isEmpty) return;
    _back[_back.length - 1] = point;
  }

  void clear() {
    _back.clear();
    _forward.clear();
  }

  static void _push<T>(List<T> stack, T point) {
    stack.add(point);
    if (stack.length > maxDepth) stack.removeAt(0);
  }
}

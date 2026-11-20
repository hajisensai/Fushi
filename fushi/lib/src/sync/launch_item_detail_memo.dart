/// 一次起播之内的条目详情短复用。
///
/// 媒体服务器从库行起播会连着要同一份条目详情三次：重开入口取服务器端断点 /
/// 带令牌的封面（`buildMediaServerLaunch`）、取流、下后端默认字幕。三次是同一个
/// 端点、串行压在首帧前；服务器不可达时前两次还各等满一轮请求超时。
///
/// 这里只做「同一次起播」内的复用，不是缓存：
///
/// * 只留**一格**（最近那一条），存的是服务器原样返回的详情——版本选择由各消费
///   方在读出后各自套用，所以换了版本再取字幕拿到的仍是当下选中的那个版本。
/// * 窗口 [window] 从请求**落定**起算，过了就重新取。
/// * **只有重开入口那一次**（`keepFailure: true`）的失败记一格，并且**只交给一个
///   读取方一次**：随后的取流立刻抛同一个错，不再等第二轮超时；用户之后重试时
///   照常重新请求。别处取详情（详情页）失败不留——那里的失败页面自己吞掉了，
///   不该让随后的起播不发请求就失败。
/// * 断点（LWW 用）必须是服务器最新值，读断点的路径不走这里。
library;

/// 复用窗口。够盖住「重开入口 → 取流 → 下默认字幕」这一串，又短到不会把上一次
/// 起播的详情带进下一次。
const Duration kLaunchItemDetailReuseWindow = Duration(seconds: 10);

class _LaunchItemDetailSlot<T> {
  _LaunchItemDetailSlot(this.id, this.future);

  final String id;
  final Future<T> future;

  /// 失败后是否留给下一次读取：重开入口发起或接上这一发时置真。
  bool keepFailure = false;

  /// 这一发的结果已经有读取方（[LaunchItemDetailMemo.reuseOrFetch]）在等：它失败
  /// 时那个读取方当场就拿到错了，不能再留一格交给下一次读取。
  bool readerAttached = false;

  DateTime? settledAt;
  bool failed = false;
}

/// 见库注释。[T] 是服务器原样返回的条目详情（Jellyfin 的 item、Plex 的
/// metadata）。
class LaunchItemDetailMemo<T> {
  LaunchItemDetailMemo({
    this.window = kLaunchItemDetailReuseWindow,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration window;
  final DateTime Function() _now;

  _LaunchItemDetailSlot<T>? _slot;

  /// 取详情用：要服务器的最新值，所以已落定的旧结果一律不用（同一条还在途的
  /// 那一发本身就是最新的，直接共用）。成功结果总是记下，留给随后的
  /// [reuseOrFetch]；失败只在 [keepFailure]（重开入口那一次）时才留。
  Future<T> fetchAndRemember(
    String id,
    Future<T> Function() fetch, {
    required bool keepFailure,
  }) {
    _LaunchItemDetailSlot<T>? slot = _slot;
    if (slot == null || slot.id != id || slot.settledAt != null) {
      slot = _start(id, fetch);
    }
    if (keepFailure) slot.keepFailure = true;
    return slot.future;
  }

  /// 取流 / 取字幕用：同一条在途或窗口内已落定的那一份直接用，否则现取。
  ///
  /// 记下的失败只在这里抛一次就清掉；接上在途的那一发、或自己现取的，失败都由
  /// 这次调用当场拿走，不留记录。
  Future<T> reuseOrFetch(String id, Future<T> Function() fetch) {
    _LaunchItemDetailSlot<T>? slot = _slot;
    if (slot != null && slot.id == id) {
      final DateTime? settledAt = slot.settledAt;
      if (settledAt == null) {
        slot.readerAttached = true;
        return slot.future;
      }
      if (_now().difference(settledAt) <= window) {
        if (slot.failed) _slot = null;
        return slot.future;
      }
    }
    slot = _start(id, fetch)..readerAttached = true;
    return slot.future;
  }

  _LaunchItemDetailSlot<T> _start(String id, Future<T> Function() fetch) {
    final _LaunchItemDetailSlot<T> slot = _LaunchItemDetailSlot<T>(id, fetch());
    _slot = slot;
    slot.future.then<void>(
      (T _) {
        slot.settledAt = _now();
      },
      onError: (Object _) {
        slot
          ..settledAt = _now()
          ..failed = true;
        final bool keep = slot.keepFailure && !slot.readerAttached;
        if (!keep && identical(_slot, slot)) _slot = null;
      },
    );
    return slot;
  }
}

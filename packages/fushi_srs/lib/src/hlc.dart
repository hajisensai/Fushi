/// 混合逻辑时钟（铁律 F）与可信时间。
library;

/// HLC = (物理毫秒, 计数器, writerId)，按字典序比较。
class Hlc implements Comparable<Hlc> {
  const Hlc(this.physical, this.counter, this.writerId);

  final int physical;
  final int counter;
  final String writerId;

  static const Hlc zero = Hlc(0, 0, '');

  @override
  int compareTo(Hlc other) {
    final int p = physical.compareTo(other.physical);
    if (p != 0) return p;
    final int c = counter.compareTo(other.counter);
    if (c != 0) return c;
    return writerId.compareTo(other.writerId);
  }

  bool operator >(Hlc other) => compareTo(other) > 0;
  bool operator <(Hlc other) => compareTo(other) < 0;

  /// 线格式：`<physical>:<counter>:<writerId>`（writerId 可含冒号，只切前两段）。
  String encode() => '$physical:$counter:$writerId';

  static Hlc decode(String text) {
    final int a = text.indexOf(':');
    final int b = a < 0 ? -1 : text.indexOf(':', a + 1);
    if (a < 0 || b < 0) throw FormatException('bad hlc: $text');
    return Hlc(
      int.parse(text.substring(0, a)),
      int.parse(text.substring(a + 1, b)),
      text.substring(b + 1),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Hlc &&
      other.physical == physical &&
      other.counter == counter &&
      other.writerId == writerId;

  @override
  int get hashCode => Object.hash(physical, counter, writerId);

  @override
  String toString() => 'Hlc(${encode()})';
}

/// 排序与 HLC 推进共用的容差：发布时服务器时间 S 之后最多 10 分钟。
const int srsClockToleranceMs = 10 * 60 * 1000;

/// 本机 HLC 状态。只在本机发出事件与收到对端事件时推进。
class HlcClock {
  HlcClock(this.writerId, {Hlc? last}) : _last = last ?? Hlc(0, 0, writerId);

  final String writerId;
  Hlc _last;

  Hlc get last => _last;

  /// 本机发出事件：取 max(可信时间, 已见过的最大 HLC)。
  Hlc tick(int trustedNowMs) {
    if (trustedNowMs > _last.physical) {
      _last = Hlc(trustedNowMs, 0, writerId);
    } else {
      _last = Hlc(_last.physical, _last.counter + 1, writerId);
    }
    return _last;
  }

  /// 收到对端事件（第六轮审查第 3 条）：**先钳位再推进**。
  ///
  /// 用 `min(远端物理时间, S(e) + 10 分钟)` 推进；S 未知时只推进到 `本机可信时间 + 10 分钟`。
  /// 不钳位的话，一台时钟快一年的设备会把所有收到它数据的设备的 HLC 推到一年后，
  /// 之后所有人的事件都被钳到 S + 10 分钟，排序退化成「按批次 S」。
  void receive(Hlc remote, {int? serverTimeMs, required int trustedNowMs}) {
    final int bound = (serverTimeMs ?? trustedNowMs) + srsClockToleranceMs;
    final int effective = remote.physical < bound ? remote.physical : bound;
    if (effective > _last.physical) {
      _last = Hlc(effective, 0, writerId);
    } else if (effective == _last.physical && remote.physical == effective) {
      final int c = remote.counter > _last.counter
          ? remote.counter
          : _last.counter;
      _last = Hlc(effective, c, writerId);
    }
  }
}

/// 事件时间来源（铁律 F 第一层）。
enum SrsTimeSource {
  /// 本次开机已与同步后端校时：服务器时间锚点 + 含睡眠的单调时钟。
  anchored('anchored'),

  /// 开机后还没校时：墙钟。
  wall('wall');

  const SrsTimeSource(this.wire);

  final String wire;

  static SrsTimeSource parse(String? wire) =>
      wire == anchored.wire ? anchored : wall;
}

/// 可信时间：同步成功时记下 (服务器时间, 单调时钟读数, 本次开机 ID)，
/// 之后 = 锚点服务器时间 + 单调时钟经过量；同一次开机内改系统时间不影响。
class SrsTrustedClock {
  SrsTrustedClock({
    required int Function() wallClockMs,
    required int Function() monotonicMs,
    required String bootId,
  }) : _wall = wallClockMs,
       _mono = monotonicMs,
       _bootId = bootId;

  final int Function() _wall;
  final int Function() _mono;
  final String _bootId;

  int? _anchorServerMs;
  int? _anchorMonoMs;
  String? _anchorBootId;

  /// 同步成功、拿到服务器时间时调用。
  void anchor({required int serverTimeMs}) {
    _anchorServerMs = serverTimeMs;
    _anchorMonoMs = _mono();
    _anchorBootId = _bootId;
  }

  /// 恢复持久化的锚点（只有同一次开机的锚点才有效）。
  void restoreAnchor({
    required int serverTimeMs,
    required int monotonicMs,
    required String bootId,
  }) {
    if (bootId != _bootId) return;
    _anchorServerMs = serverTimeMs;
    _anchorMonoMs = monotonicMs;
    _anchorBootId = bootId;
  }

  bool get isAnchored => _anchorBootId == _bootId && _anchorServerMs != null;

  /// 墙钟与可信时间的偏差（毫秒），未校时为 null。超过 10 分钟时同步状态里提示「系统时间不准」。
  int? get wallSkewMs => isAnchored ? _wall() - now().$1 : null;

  /// (可信时间毫秒, 时间来源)。
  (int, SrsTimeSource) now() {
    if (isAnchored) {
      final int elapsed = _mono() - _anchorMonoMs!;
      return (_anchorServerMs! + elapsed, SrsTimeSource.anchored);
    }
    return (_wall(), SrsTimeSource.wall);
  }
}

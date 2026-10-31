/// 混合逻辑时钟（铁律 F）与可信时间。
library;

/// HLC = (物理毫秒, 计数器, writerId)。事件间的先后按排序键（钳位后的 HLC + eventId）比，只在 Rust 里
/// 算一份（native/fushi_fsrs/src/ordering.rs）；这里不提供比较。
class Hlc {
  const Hlc(this.physical, this.counter, this.writerId);

  final int physical;
  final int counter;
  final String writerId;

  static const Hlc zero = Hlc(0, 0, '');

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
  /// 本进程已与同步后端校时：墙钟 + 校时时测得的「服务器时间 − 墙钟」偏移。
  anchored('anchored'),

  /// 本进程还没校时：墙钟。
  wall('wall');

  const SrsTimeSource(this.wire);

  final String wire;

  static SrsTimeSource parse(String? wire) =>
      wire == anchored.wire ? anchored : wall;
}

/// 可信时间：同步成功时记下「服务器时间 − 同一刻的墙钟」偏移，之后 = 墙钟 + 偏移。
///
/// 只记偏移、不再按「锚点 + 单调时钟经过量」推算：单调时钟（Dart Stopwatch）在 Android 上不计深睡，睡一觉
/// 可信时间就落后睡掉的时长；而且锚点的服务器时间与单调读数只要不是同一刻取的，差多少可信时间就偏多少
/// （曾经把一整轮同步的耗时算成「墙钟超前」，同步慢 = 卡顿时可信时间超前十几分钟，复习记录写进未来、
/// 进程重启退回墙钟后时间倒流）。墙钟一直在走（睡眠也算），偏移只在下一次校时时更新。
class SrsTrustedClock {
  SrsTrustedClock({required int Function() wallClockMs, required String bootId})
    : _wall = wallClockMs,
      _bootId = bootId;

  final int Function() _wall;
  final String _bootId;

  int? _offsetMs;
  String? _anchorBootId;

  /// 当前墙钟（毫秒）。校时的调用方用它记下「服务器时间被观测到的那一刻」。
  int wallNowMs() => _wall();

  /// 同步成功、拿到服务器时间时调用。
  ///
  /// [observedAtWallMs]：服务器盖下 [serverTimeMs] 那一刻的墙钟读数（同步一轮里围着写 head 的那次上传取，
  /// 见 `SrsSync2Report.serverTimeWallMs`）。不给就按现在的墙钟算，只适合当场拿到的服务器时间。
  void anchor({required int serverTimeMs, int? observedAtWallMs}) {
    _offsetMs = serverTimeMs - (observedAtWallMs ?? _wall());
    _anchorBootId = _bootId;
  }

  /// 恢复持久化的偏移（只有本进程写下的才有效：进程之间用户可能改过系统时间）。
  void restoreAnchor({required int offsetMs, required String bootId}) {
    if (bootId != _bootId) return;
    _offsetMs = offsetMs;
    _anchorBootId = bootId;
  }

  bool get isAnchored => _anchorBootId == _bootId && _offsetMs != null;

  /// 持久化用：(偏移, 本进程 ID)，未校时为 null。
  ({int offsetMs, String bootId})? get anchorState =>
      isAnchored ? (offsetMs: _offsetMs!, bootId: _bootId) : null;

  /// 墙钟与可信时间的偏差（毫秒，正 = 墙钟超前），未校时为 null。超过 10 分钟时同步状态里提示「系统时间不准」。
  int? get wallSkewMs => isAnchored ? -_offsetMs! : null;

  /// (可信时间毫秒, 时间来源)。
  (int, SrsTimeSource) now() {
    if (isAnchored) return (_wall() + _offsetMs!, SrsTimeSource.anchored);
    return (_wall(), SrsTimeSource.wall);
  }
}

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
  /// 本进程已与同步后端校时：校时那一刻的服务器时间 + 开机时钟（含睡眠）之后走过的量。
  anchored('anchored'),

  /// 本进程还没校时：墙钟（有上一个进程留下的校时偏移时 = 墙钟 + 该偏移，仍算未校时）。
  wall('wall');

  const SrsTimeSource(this.wire);

  final String wire;

  static SrsTimeSource parse(String? wire) =>
      wire == anchored.wire ? anchored : wall;
}

/// 持久化的校时状态（[SrsTrustedClock.anchorState]）。
typedef SrsClockAnchorState = ({
  /// 写下它的进程（[SrsTrustedClock] 的 `bootId`）。
  String bootId,

  /// 保存那一刻「可信时间 − 墙钟」：别的进程（重启 / 重新开机后）在下一次校时前按「墙钟 + 它」估算。
  int offsetMs,

  /// 校时那一刻的服务器时间；只有本进程校过时才有。
  int? serverTimeMs,

  /// 与 [serverTimeMs] 同一刻的开机时钟读数。
  int? bootTimeMs,
});

/// 可信时间：同步校时时记下「服务器时间 S、同一刻的开机时钟读数 B」，之后 = S + (开机时钟 − B)。
///
/// 开机时钟（`ffsrs_boot_time_ms`，native/fushi_fsrs/src/boot_clock.rs）**睡眠也计时**、**不受改系统时间影响**：
/// - 不能用 Dart Stopwatch：Android / Linux 上是 CLOCK_MONOTONIC，深睡不计，睡一觉可信时间落后睡掉的时长；
/// - 不能用「墙钟 + 偏移」：校时之后在同一进程里改系统时间，可信时间跟着跳，「系统时间不准」也再查不出来。
///
/// [wallSkewMs] 每次现算（墙钟 − 可信时间），校时后改过系统时间也能报出来。
///
/// 开机时钟重启后从 0 重新计：S/B 只在写下它的进程里有效（[restoreAnchor] 按 bootId 判）；别的进程只接上一份
/// 「可信时间 − 墙钟」偏移，按墙钟 + 偏移估算到下一次校时，来源记为 [SrsTimeSource.wall]（未校时）。
class SrsTrustedClock {
  SrsTrustedClock({
    required int Function() wallClockMs,
    required int Function() bootClockMs,
    required String bootId,
  }) : _wall = wallClockMs,
       _boot = bootClockMs,
       _bootId = bootId;

  final int Function() _wall;
  final int Function() _boot;
  final String _bootId;

  int? _anchorServerMs;
  int? _anchorBootMs;

  /// 上一个进程留下的「可信时间 − 墙钟」（未校时的估算用）。
  int? _carriedOffsetMs;

  /// 当前墙钟（毫秒）。
  int wallNowMs() => _wall();

  /// 当前开机时钟（毫秒，含睡眠）。校时的调用方用它记下「服务器时间被观测到的那一刻」。
  int bootNowMs() => _boot();

  /// 同步成功、拿到服务器时间时调用。
  ///
  /// [observedAtBootMs]：服务器盖下 [serverTimeMs] 那一刻的开机时钟读数（同步一轮里围着写 head 的那次上传取，
  /// 见 `SrsSync2Report.serverTimeBootMs`）。必须与服务器时间是**同一刻**的读数：配错一刻（例如拿一轮开头的
  /// 读数配末尾的服务器时间），差多少可信时间就偏多少（BUG-3900）。
  void anchor({required int serverTimeMs, required int observedAtBootMs}) {
    _anchorServerMs = serverTimeMs;
    _anchorBootMs = observedAtBootMs;
    _carriedOffsetMs = null;
  }

  /// 恢复持久化的校时状态。
  ///
  /// 本进程写下的（[bootId] 相同、开机时钟没有倒退）：完整恢复 S/B，接着按开机时钟推算。别的进程写下的：开机
  /// 时钟可能已经因重启归零、读数没法对上，只接 [offsetMs]，下一次校时前按墙钟 + 偏移估算、算未校时。
  void restoreAnchor({
    required int offsetMs,
    required String bootId,
    int? serverTimeMs,
    int? bootTimeMs,
  }) {
    if (bootId == _bootId &&
        serverTimeMs != null &&
        bootTimeMs != null &&
        _boot() >= bootTimeMs) {
      _anchorServerMs = serverTimeMs;
      _anchorBootMs = bootTimeMs;
      _carriedOffsetMs = null;
      return;
    }
    _anchorServerMs = null;
    _anchorBootMs = null;
    _carriedOffsetMs = offsetMs;
  }

  bool get isAnchored => _anchorServerMs != null && _anchorBootMs != null;

  /// 持久化用；既没校时也没有接上的偏移时为 null。
  SrsClockAnchorState? get anchorState {
    if (isAnchored) {
      return (
        bootId: _bootId,
        offsetMs: now().$1 - _wall(),
        serverTimeMs: _anchorServerMs,
        bootTimeMs: _anchorBootMs,
      );
    }
    final int? carried = _carriedOffsetMs;
    if (carried == null) return null;
    return (
      bootId: _bootId,
      offsetMs: carried,
      serverTimeMs: null,
      bootTimeMs: null,
    );
  }

  /// 墙钟与可信时间的偏差（毫秒，正 = 墙钟超前），每次现算；未校时为 null。超过 10 分钟时同步状态里提示
  /// 「系统时间不准」。
  int? get wallSkewMs => isAnchored ? _wall() - now().$1 : null;

  /// (可信时间毫秒, 时间来源)。
  (int, SrsTimeSource) now() {
    final int? server = _anchorServerMs;
    final int? at = _anchorBootMs;
    if (server != null && at != null) {
      return (server + (_boot() - at), SrsTimeSource.anchored);
    }
    return (_wall() + (_carriedOffsetMs ?? 0), SrsTimeSource.wall);
  }
}

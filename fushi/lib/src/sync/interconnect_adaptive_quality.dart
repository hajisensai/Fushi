/// 互联远端视频「自动」档的自适应决策（按实测网况升降画质）。
///
/// 播放页每秒喂一拍采样，这里决定要不要换档。纯逻辑、无 IO、无 Flutter——换档抖动
/// 是这类功能最容易翻车的地方（一卡就降、一快就升，用户看到的是画质每隔几秒变一次），
/// 所以判据全部收在这里，能被单测按拍钉死。
library;

import 'dart:math' show max;

import 'package:fushi/src/sync/interconnect_video_quality.dart';
import 'package:fushi/src/sync/remote_video_client.dart';

/// 换档的理由（OSD 文案与诊断用）。
enum AdaptiveQualityReason {
  /// 卡了：缓冲事件够多，当前档撑不住。
  stall,

  /// 带宽富余：缓冲一直很足、也没卡过，可以往上走一档。
  headroom,
}

/// 一次换档决定。
class AdaptiveQualityDecision {
  const AdaptiveQualityDecision({
    required this.targetIndex,
    required this.reason,
  });

  /// 目标档在 [kInterconnectQualityPresets] 里的下标。
  final int targetIndex;
  final AdaptiveQualityReason reason;

  @override
  String toString() => 'AdaptiveQualityDecision($targetIndex, ${reason.name})';
}

/// 自适应的**上界**：卡过一次之后就不再回到「原画直传」。
///
/// 原画的码率是源文件说了算（一部 BDRip 能到 20 Mbps 以上），一旦实测发现这条链路
/// 撑不住它，再升回去只会让用户又卡一次。所以升档的天花板是受管档位里最高的那一档，
/// 而不是原画。
const int kAdaptiveMaxIndex = 0;

/// 换档后的冷却拍数。
///
/// 每次换档都要重新取流、重新起播，代价不小；30 秒的冷却让「降一档 → 还是卡 → 再降」
/// 之间至少隔着一段真实的观察期，而不是在一次网络抖动里连降三档。
const int kAdaptiveCooldownTicks = 30;

/// 降档判据的观察窗（拍）。
const int kAdaptiveStallWindowTicks = 20;

/// 窗口内卡到几拍就降档。
///
/// 2 拍（≈2 秒缓冲）还在容忍范围内——起播、seek、关键帧对齐都可能带来一两拍的
/// 缓冲；3 拍开始就是真的跟不上了。
const int kAdaptiveStallTicksToDrop = 3;

/// 升档判据：要连续这么多拍没卡过。
///
/// 比降档窗口长得多（90 秒 vs 20 秒）：降档要灵敏，升档要迟钝。判错方向的代价不
/// 对称——降错了只是这一段画质低一点，升错了是直接卡给用户看。
const int kAdaptiveHeadroomQuietTicks = 90;

/// 升档判据：缓冲时长要稳定高过这个秒数。
///
/// 用「缓冲了多少秒」而不是「下载速度」当富余判据，是因为播放器按需下载：缓冲填满
/// 之后它就不再全速拉流，稳态下的下载速度≈媒体码率，看上去永远「刚好够用」，据此
/// 判断富余会永远判不出来。缓冲深度才如实反映「拉得比放得快」。
const double kAdaptiveHeadroomCacheSeconds = 25;

/// 用户 seek 之后最多这么多拍的缓冲**不算卡顿**（BUG-2731）。
///
/// seek 在远端流上要断开旧连接、重新发 Range 请求，平板实测一次就缓冲 3～4 秒——
/// 正好越过 [kAdaptiveStallTicksToDrop]，于是局域网原画直传被当成「撑不住」降成
/// 转码，再按 seek 之前的旧位置重开，用户看到的就是「滑一下又回去了」。这段缓冲
/// 反映的是 seek 的代价，不是网况。
///
/// 宽限是**有上限**的：seek 之后一直缓冲超过 10 秒，那就是真的跟不上了，照常计入。
/// 一出现不缓冲的一拍（seek 已落地起播）宽限立即结束。
///
/// 频繁 seek（句子循环、反复拖动）时宽限不能每次无条件续命，否则差网上缓冲永远不入
/// 卡顿窗口、永不降档。但 seek 本身有与网况无关的固定代价（局域网平板 3～4 拍），
/// 也不能给宽限设总额（那会让局域网连续拖动降档，BUG-2731 回归）。所以判据是「窗口
/// 内平均每次 seek 的代价」是否超出健康链路的正常代价
/// [kAdaptiveSeekCostBaselineTicks]：窗口内有 ≥2 次 seek 时，被豁免的缓冲拍数超过
/// 「seek 次数 × 正常代价」的部分按卡顿计。
///
/// 已知盲区（审查记录，未修，改判据前先读）：
/// - **1 Hz 采样的空档**：宽限靠「采到一拍不缓冲」结束。seek 落地后若是「短暂起播
///   零点几秒又卡住」，这段起播可能正好落在两次采样之间，采样看到的仍是连续缓冲，
///   宽限一直延续到 10 拍上限——真卡顿被多吞最多 10 秒才开始计入；反过来若起播恰好
///   被采到，宽限立即结束、紧随其后的卡顿照常计入，行为取决于采样相位。
/// - **平均代价落在正常范围内的高频 seek**：每次 seek 平均缓冲 3～5 拍的高频循环
///   不降档——这类代价与局域网 seek 无法区分，且降到转码档后 HLS seek 并不更快。
const int kAdaptiveSeekGraceTicks = 10;

/// 一次 seek 在健康链路上的正常代价（拍）。BUG-2731 实测局域网平板 3～4 拍，取 5。
/// 窗口内有 ≥2 次 seek、且豁免的缓冲拍数超过「seek 次数 × 本值」时，超出部分按卡顿计
/// （见 [kAdaptiveSeekGraceTicks]）。
const int kAdaptiveSeekCostBaselineTicks = 5;

/// 观察窗里一拍的分类。
enum _TickKind {
  /// 没在缓冲。
  clear,

  /// 缓冲且不在 seek 宽限内：按卡顿计。
  stalled,

  /// 缓冲但在 seek 宽限内：先按 seek 代价豁免。
  graced,
}

/// 观察窗里的一拍。
class _WindowTick {
  const _WindowTick(this.kind, this.graceSeekSerial);

  final _TickKind kind;

  /// [_TickKind.graced] 拍归属的那次 seek（登记时的拍序号），其他拍为 null。
  final int? graceSeekSerial;
}

/// 自适应换档事务：写入目标档 → 重载 → 没立起来就回滚（BUG-4460）。
///
/// 取流协商要读 [write] 写进去的目标档，所以必须先写；[reload] 没把新流立起来
/// （返回 false 或抛错）时把共享档回滚到原值——否则共享状态停在一个没起来的档上，
/// 页面「重试」与进程级单例 backend 的下一次同 scope 起播都会沿用它。只在共享档
/// 此刻仍是我们写的那个目标时回滚：换档途中用户手动选档、换源 / 换链路让 backend
/// 重新定了起点，都不能被一个过期的原值覆盖。
///
/// 返回新流是否立起来；[reload] 抛的错回滚后原样重新抛出。
Future<bool> runAdaptiveQualitySwitch({
  required int? Function() read,
  required void Function(int? index) write,
  required int targetIndex,
  required Future<bool> Function() reload,
}) async {
  final int? previous = read();
  write(targetIndex);
  bool ok = false;
  try {
    ok = await reload();
    return ok;
  } finally {
    if (!ok && read() == targetIndex) write(previous);
  }
}

/// 「自动」档的自适应控制器。
///
/// 只在用户选了「自动」时才该被喂采样；用户显式选了某一档就是选定了，不该被自动
/// 改掉——那会让设置看起来自己会动。
class AdaptiveQualityController {
  AdaptiveQualityController({List<MediaServerQualityPreset>? presets})
    : _presets = presets ?? kInterconnectQualityPresets;

  final List<MediaServerQualityPreset> _presets;

  /// 最近若干拍的分类（环形窗口，新的在末尾）。
  final List<_WindowTick> _window = <_WindowTick>[];

  /// 已喂的拍数（单调递增，给 seek 登记定位用）。
  int _tickSerial = 0;

  /// 落在观察窗内的 seek（登记时的 [_tickSerial]，即它之后第一拍是第
  /// `serial + 1` 拍）。
  final List<int> _seekSerials = <int>[];

  /// 当前宽限归属的 seek（[_seekSerials] 里的值）。
  int? _graceSeekSerial;

  /// 连续没卡过的拍数。
  int _quietTicks = 0;

  /// 连续「缓冲深度够」的拍数。
  int _healthyCacheTicks = 0;

  /// 距上次换档的拍数；初值给足冷却，避免起播头 30 秒就急着动。
  int _ticksSinceSwitch = 0;

  /// seek 宽限剩余拍数（见 [kAdaptiveSeekGraceTicks]）。
  int _seekGraceTicksLeft = 0;

  /// 起播/换集后重置：新的一条流，过去的观察不再作数。
  void reset() {
    _window.clear();
    _seekSerials.clear();
    _graceSeekSerial = null;
    _quietTicks = 0;
    _healthyCacheTicks = 0;
    _ticksSinceSwitch = 0;
    _seekGraceTicksLeft = 0;
  }

  /// 用户发起了一次 seek：随后的缓冲先按 seek 代价处理（见 [kAdaptiveSeekGraceTicks]）。
  void noteSeek() {
    _seekGraceTicksLeft = kAdaptiveSeekGraceTicks;
    _graceSeekSerial = _tickSerial;
    _seekSerials.add(_tickSerial);
  }

  /// 喂一拍（1 Hz）。
  ///
  /// [currentIndex] 是当前生效档（-1 = 原画直传）；[buffering] 是这一拍播放器是否在
  /// 缓冲；[cacheSeconds] 是缓冲深度（拿不到时传 null，升档判据就不成立）。
  ///
  /// 返回 null 表示保持不动。
  AdaptiveQualityDecision? tick({
    required int currentIndex,
    required bool buffering,
    double? cacheSeconds,
  }) {
    _ticksSinceSwitch++;
    _tickSerial++;

    // seek 引起的缓冲先按 seek 代价豁免；一旦起播（不缓冲）宽限立即结束。
    final _WindowTick sample;
    if (!buffering) {
      _seekGraceTicksLeft = 0;
      sample = const _WindowTick(_TickKind.clear, null);
    } else if (_seekGraceTicksLeft > 0) {
      _seekGraceTicksLeft--;
      sample = _WindowTick(_TickKind.graced, _graceSeekSerial);
    } else {
      sample = const _WindowTick(_TickKind.stalled, null);
    }

    _window.add(sample);
    while (_window.length > kAdaptiveStallWindowTicks) {
      _window.removeAt(0);
    }
    // 窗口第一拍的序号；登记在它之前的 seek（之后第一拍已滑出窗口）不再计入。
    final int windowFirstSerial = _tickSerial - _window.length + 1;
    _seekSerials.removeWhere((int s) => s + 1 < windowFirstSerial);
    if (buffering) {
      _quietTicks = 0;
    } else {
      _quietTicks++;
    }
    if (cacheSeconds != null && cacheSeconds >= kAdaptiveHeadroomCacheSeconds) {
      _healthyCacheTicks++;
    } else {
      _healthyCacheTicks = 0;
    }

    if (_ticksSinceSwitch < kAdaptiveCooldownTicks) return null;

    if (_stallScore() >= kAdaptiveStallTicksToDrop) {
      final int target = _nextLowerIndex(currentIndex);
      if (target == currentIndex) return null;
      _markSwitched();
      return AdaptiveQualityDecision(
        targetIndex: target,
        reason: AdaptiveQualityReason.stall,
      );
    }

    if (_quietTicks >= kAdaptiveHeadroomQuietTicks &&
        _healthyCacheTicks >= kAdaptiveHeadroomQuietTicks) {
      final int target = _nextHigherIndex(currentIndex);
      if (target == currentIndex) return null;
      _markSwitched();
      return AdaptiveQualityDecision(
        targetIndex: target,
        reason: AdaptiveQualityReason.headroom,
      );
    }
    return null;
  }

  /// 窗口内按卡顿计的拍数：真卡顿 + 超出正常 seek 代价的那部分豁免拍
  /// （见 [kAdaptiveSeekCostBaselineTicks]）。
  int _stallScore() {
    int stalled = 0;
    int graced = 0;
    // 参与平均的 seek：登记在窗口内的，加上豁免拍仍在窗口内的（seek 本身已滑出窗口、
    // 它的缓冲还在窗口里时，不能只算缓冲不算 seek）。
    final Set<int> seeks = <int>{..._seekSerials};
    for (final _WindowTick t in _window) {
      switch (t.kind) {
        case _TickKind.clear:
          break;
        case _TickKind.stalled:
          stalled++;
        case _TickKind.graced:
          graced++;
          final int? owner = t.graceSeekSerial;
          if (owner != null) seeks.add(owner);
      }
    }
    final int excess = seeks.length >= 2
        ? max(0, graced - seeks.length * kAdaptiveSeekCostBaselineTicks)
        : 0;
    return stalled + excess;
  }

  void _markSwitched() {
    _ticksSinceSwitch = 0;
    _window.clear();
    _seekSerials.clear();
    _quietTicks = 0;
    _healthyCacheTicks = 0;
  }

  /// 降一档。原画（-1）撑不住时的下一档是受管档位里最高的那一档，而不是最低档——
  /// 一次卡顿只说明「原画太大」，不说明要一路砸到 360p。
  int _nextLowerIndex(int currentIndex) {
    if (currentIndex < 0) return kAdaptiveMaxIndex;
    final int last = _presets.length - 1;
    return currentIndex >= last ? currentIndex : currentIndex + 1;
  }

  /// 升一档，天花板是 [kAdaptiveMaxIndex]（见那里的说明：不回原画）。
  int _nextHigherIndex(int currentIndex) {
    if (currentIndex < 0) return currentIndex; // 已经是原画，没有更高的了。
    return currentIndex <= kAdaptiveMaxIndex ? currentIndex : currentIndex - 1;
  }
}

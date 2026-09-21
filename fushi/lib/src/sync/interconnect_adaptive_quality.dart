/// 互联远端视频「自动」档的自适应决策（按实测网况升降画质）。
///
/// 播放页每秒喂一拍采样，这里决定要不要换档。纯逻辑、无 IO、无 Flutter——换档抖动
/// 是这类功能最容易翻车的地方（一卡就降、一快就升，用户看到的是画质每隔几秒变一次），
/// 所以判据全部收在这里，能被单测按拍钉死。
library;

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

/// 「自动」档的自适应控制器。
///
/// 只在用户选了「自动」时才该被喂采样；用户显式选了某一档就是选定了，不该被自动
/// 改掉——那会让设置看起来自己会动。
class AdaptiveQualityController {
  AdaptiveQualityController({List<MediaServerQualityPreset>? presets})
    : _presets = presets ?? kInterconnectQualityPresets;

  final List<MediaServerQualityPreset> _presets;

  /// 最近若干拍是否在缓冲（环形窗口，新的在末尾）。
  final List<bool> _stalls = <bool>[];

  /// 连续没卡过的拍数。
  int _quietTicks = 0;

  /// 连续「缓冲深度够」的拍数。
  int _healthyCacheTicks = 0;

  /// 距上次换档的拍数；初值给足冷却，避免起播头 30 秒就急着动。
  int _ticksSinceSwitch = 0;

  /// 起播/换集后重置：新的一条流，过去的观察不再作数。
  void reset() {
    _stalls.clear();
    _quietTicks = 0;
    _healthyCacheTicks = 0;
    _ticksSinceSwitch = 0;
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

    _stalls.add(buffering);
    while (_stalls.length > kAdaptiveStallWindowTicks) {
      _stalls.removeAt(0);
    }
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

    final int stallTicks = _stalls.where((bool s) => s).length;
    if (stallTicks >= kAdaptiveStallTicksToDrop) {
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

  void _markSwitched() {
    _ticksSinceSwitch = 0;
    _stalls.clear();
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

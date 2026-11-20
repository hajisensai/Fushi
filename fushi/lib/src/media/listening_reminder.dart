/// 「连续收听提醒」（反馈 5_mzP54WVx：加一个听时提醒，保护耳朵；拍板台 2026-11-16：
/// 加，支持提醒和关闭）：音乐 / 有声书 / 视频任一在播时累计连续收听时长，到用户选的
/// 分钟数就提醒一次（只提醒，不降音量、不自动暂停），默认关闭。
///
/// 本文件只有计时口径与调度（只依赖 foundation，不碰 widget / 插件，单测用 fake_async
/// 跑完）；「谁在播」「怎么提醒」由 `listening_reminder_app.dart` 装配。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show Listenable, visibleForTesting;

/// 出厂提醒间隔（分钟）。
const int kListeningReminderMinutesDefault = 60;

/// 设置下拉里的档位（分钟，升序，含默认值）。
const List<int> kListeningReminderMinutesChoices = <int>[
  15,
  30,
  45,
  60,
  90,
  120,
];

/// 停播多久算「歇过了」：连续不在播满这么久，累计清零。短暂暂停（接电话、切歌、
/// 拖进度）不算休息，不清零。
const Duration kListeningReminderBreak = Duration(minutes: 5);

/// 采样周期：每隔这么久看一眼有没有在播。
const Duration kListeningReminderTick = Duration(seconds: 30);

/// 系统通知（应用不在前台时）的载荷：点通知时据此认出是收听提醒，只把应用唤到前台，
/// 不落进更新中心的分派。
const String kListeningReminderNotificationPayload = 'fushi-listening-reminder';

/// 系统通知 id：固定一个（新一轮提醒替换上一条而不是叠加）。避开更新中心的
/// 9101..9105 与反馈回复的 2^30 以上区间。
const int kListeningReminderNotificationId = 9201;

/// 把任意存值归到最近的档位（[kListeningReminderMinutesChoices]）：下拉只认档位值，
/// 档位外的存值（手改库 / 旧版本）不能让设置行选不中任何一项。等距时取较大的一档。
int normalizeListeningReminderMinutes(num value) {
  final int minutes = value.round();
  int best = kListeningReminderMinutesChoices.first;
  for (final int choice in kListeningReminderMinutesChoices) {
    if ((choice - minutes).abs() <= (best - minutes).abs()) best = choice;
  }
  return best;
}

/// 连续收听计时的口径：在播的时间累加，停播满 [breakDuration] 清零；累计到阈值即
/// 触发一次并清零（提醒之后重新计下一轮）。
class ListeningReminderTracker {
  ListeningReminderTracker({this.breakDuration = kListeningReminderBreak});

  final Duration breakDuration;

  Duration _listened = Duration.zero;
  Duration _idle = Duration.zero;

  /// 本轮已连续收听的时长。
  Duration get listened => _listened;

  /// 清零（开关刚打开 / 刚提醒过）。
  void reset() {
    _listened = Duration.zero;
    _idle = Duration.zero;
  }

  /// 记一段 [elapsed]：这段时间里 [playing] 表示在不在播。返回 true = 本轮累计到了
  /// [threshold]，该提醒了（计数已清零）。
  bool record({
    required bool playing,
    required Duration elapsed,
    required Duration threshold,
  }) {
    if (elapsed <= Duration.zero) return false;
    if (!playing) {
      _idle += elapsed;
      if (_idle >= breakDuration) reset();
      return false;
    }
    _idle = Duration.zero;
    _listened += elapsed;
    if (_listened < threshold) return false;
    reset();
    return true;
  }
}

/// 调度：开关打开时按 [tick] 周期采样「有没有在播」，喂给 [ListeningReminderTracker]，
/// 到点调 [onReminder]。开关关着时不起计时器、不采样。偏好变化经 [settings] 通知，
/// 每次通知重新对一遍开关（关 → 停表清零；开 → 起表从零计）。
class ListeningReminderService {
  ListeningReminderService({
    required this.enabled,
    required this.threshold,
    required this.isPlaying,
    required this.onReminder,
    required this.settings,
    this.tick = kListeningReminderTick,
    ListeningReminderTracker? tracker,
    DateTime Function()? clock,
  }) : _tracker = tracker ?? ListeningReminderTracker(),
       _clock = clock ?? DateTime.now;

  /// 用户开没开提醒。
  final bool Function() enabled;

  /// 提醒间隔（读实时值：改了档位对正在进行的这一轮立即生效）。
  final Duration Function() threshold;

  /// 此刻是否有任何播放器在出声。
  final bool Function() isPlaying;

  /// 到点了。由装配层决定是应用内弹窗还是系统通知。
  final Future<void> Function() onReminder;

  /// 偏好仓库：开关 / 档位一变就通知。
  final Listenable settings;

  final Duration tick;
  final ListeningReminderTracker _tracker;
  final DateTime Function() _clock;

  Timer? _timer;
  DateTime? _lastSample;
  bool _started = false;

  @visibleForTesting
  bool get running => _timer != null;

  @visibleForTesting
  Duration get listened => _tracker.listened;

  /// 开始跟随偏好（重复调用无副作用）。
  void start() {
    if (_started) return;
    _started = true;
    settings.addListener(_sync);
    _sync();
  }

  void _sync() {
    final bool on = enabled();
    if (on && _timer == null) {
      _tracker.reset();
      _lastSample = _clock();
      _timer = Timer.periodic(tick, (_) => _sample());
    } else if (!on && _timer != null) {
      _timer!.cancel();
      _timer = null;
      _lastSample = null;
      _tracker.reset();
    }
  }

  /// 单次采样间隔里能按「采样那一刻在不在播」计入的上限。正常节拍下间隔约等于 [tick]；
  /// 应用被挂起 / 冷冻 / 机器休眠后补发的那次 tick 间隔可能是几小时，那段时间里到底
  /// 播没播无从得知，只有最近这一小段能认采样值。
  Duration get _maxCreditedGap => tick * 2;

  void _sample() {
    final DateTime now = _clock();
    final DateTime last = _lastSample ?? now;
    _lastSample = now;
    final Duration gap = now.difference(last);
    final Duration cap = _maxCreditedGap;
    if (gap > cap) {
      // 超出上限的部分当成「歇过了」（挂起期间进程没在跑，不能凭唤醒那一刻在播
      // 就把几小时算成连续收听），满 breakDuration 即清零；剩下的 cap 按采样值计。
      _tracker.record(
        playing: false,
        elapsed: gap - cap,
        threshold: threshold(),
      );
    }
    final bool fire = _tracker.record(
      playing: isPlaying(),
      elapsed: gap > cap ? cap : gap,
      threshold: threshold(),
    );
    if (fire) unawaited(onReminder());
  }

  void dispose() {
    if (_started) settings.removeListener(_sync);
    _started = false;
    _timer?.cancel();
    _timer = null;
  }
}

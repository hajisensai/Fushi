/// 音乐的学习统计写入面（设计 §12 / 决策 D4，统计域规则见 docs/agent/statistics.md）。
///
/// D4：**只有发生学习动作，或用户开了「听歌计入学习」，听歌才计入学习时长**。
/// - 开关开着：在播就计（墙钟窗口，`isActive` = 在播；不设空闲门——听歌没有滚动 /
///   翻页这类输入，设了门听一小时只记 10 分钟）；
/// - 开关关着（默认）：本曲发生过学习动作（歌词页查词 / 制卡 / AB 循环，见
///   [noteLearningAction]）才起表，空闲门 = 阅读空闲超时，**只由学习动作喂门**：最后
///   一次学习动作之后再听超过空闲超时，后面的窗口一律拒掉。换曲目清掉「已投入学习」。
///
/// 写入只经 [StudyClock]（`media_kind = music`，`media_key = track uid`，标题快照取曲名），
/// 不另立累计器。一曲一钟：换曲封段、建新钟。
library;

import 'dart:async';

import 'package:fushi_audio/fushi_audio.dart' show StudyClock;
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';

/// 建时钟（测试注入假 sink / 假时间）。
typedef MusicStudyClockFactory =
    StudyClock Function({
      required FushiDatabase database,
      required MusicPlayItem item,
      required bool Function() isActive,
      required Duration? idleTimeout,
    });

StudyClock _defaultClock({
  required FushiDatabase database,
  required MusicPlayItem item,
  required bool Function() isActive,
  required Duration? idleTimeout,
}) => StudyClock(
  database: database,
  mediaKind: kActivityMediaMusic,
  mediaKey: item.trackUid,
  title: item.title,
  format: item.codec ?? '',
  isActive: isActive,
  idleTimeout: idleTimeout,
);

/// 纯函数：此刻时钟该不该跑。
bool musicStudyClockMayRun({
  required bool playing,
  required bool listeningCountsAsStudy,
  required DateTime? lastLearningActionAt,
  required DateTime now,
  required Duration idleTimeout,
}) {
  if (!playing) return false;
  if (listeningCountsAsStudy) return true;
  final DateTime? last = lastLearningActionAt;
  return last != null && now.difference(last) <= idleTimeout;
}

class MusicStudyTracker {
  MusicStudyTracker({
    required MusicPlayerEngine engine,
    required FushiDatabase? Function() database,
    required bool Function() listeningCountsAsStudy,
    required Duration Function() idleTimeout,
    MusicStudyClockFactory clockFactory = _defaultClock,
    DateTime Function()? now,
  }) : _engine = engine,
       _database = database,
       _countsAsStudy = listeningCountsAsStudy,
       _idleTimeout = idleTimeout,
       _clockFactory = clockFactory,
       _now = now ?? DateTime.now {
    _engine.addListener(_sync);
  }

  final MusicPlayerEngine _engine;
  final FushiDatabase? Function() _database;
  final bool Function() _countsAsStudy;
  final Duration Function() _idleTimeout;
  final MusicStudyClockFactory _clockFactory;
  final DateTime Function() _now;

  StudyClock? _clock;
  String? _clockTrackUid;
  bool? _clockCountsAsStudy;
  String? _trackUid;
  DateTime? _lastLearningActionAt;

  /// 时钟此刻是否在走（测试 / 诊断）。
  bool get isRunning => _clock?.isRunning ?? false;

  /// 歌词页上发生了学习动作（查词 / 制卡 / AB 循环）：本曲开始计入学习、喂空闲门。
  void noteLearningAction() {
    final MusicPlayItem? item = _engine.current;
    if (item == null) return;
    if (item.trackUid != _trackUid) _onTrackChanged(item.trackUid);
    _lastLearningActionAt = _now();
    _sync();
    _clock?.touch();
  }

  /// 「听歌计入学习」开关变了：立刻按新判据起停（时钟按新口径重建）。
  void onSettingChanged() => _sync();

  void _onTrackChanged(String? uid) {
    _trackUid = uid;
    _lastLearningActionAt = null;
  }

  void _sync() {
    final MusicPlayItem? item = _engine.current;
    if (item?.trackUid != _trackUid) _onTrackChanged(item?.trackUid);
    final bool counts = _countsAsStudy();
    final bool run =
        item != null &&
        musicStudyClockMayRun(
          playing: _engine.isPlaying,
          listeningCountsAsStudy: counts,
          lastLearningActionAt: _lastLearningActionAt,
          now: _now(),
          idleTimeout: _idleTimeout(),
        );
    // 曲目或口径变了：旧钟结算封段（stop 的同步段在首个 await 之前完成）。
    if (_clock != null &&
        (_clockTrackUid != item?.trackUid || _clockCountsAsStudy != counts)) {
      _retire();
    }
    if (!run) {
      final StudyClock? c = _clock;
      if (c != null && c.isRunning) unawaited(c.stop());
      return;
    }
    final FushiDatabase? db = _database();
    if (db == null) return;
    final StudyClock clock = _clock ??= _clockFactory(
      database: db,
      item: item,
      isActive: () => _engine.isPlaying,
      idleTimeout: counts ? null : _idleTimeout(),
    );
    _clockTrackUid = item.trackUid;
    _clockCountsAsStudy = counts;
    // 开关关着时「最后一次学习动作之后超过空闲超时」由上面的判据在引擎每次通知时
    // 停表（位置事件约 10 Hz），时钟自己的空闲门是第二道。
    if (!clock.isRunning) clock.start();
  }

  void _retire() {
    final StudyClock? c = _clock;
    _clock = null;
    _clockTrackUid = null;
    _clockCountsAsStudy = null;
    if (c != null) unawaited(c.stop());
  }

  void dispose() {
    _engine.removeListener(_sync);
    _retire();
  }
}

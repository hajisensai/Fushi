/// 音乐的学习统计写入面（设计 §12 / 决策 D4，统计域规则见 docs/agent/statistics.md）。
///
/// D4：**只有发生学习动作，或用户开了「听歌计入学习」，听歌才计入学习时长**。
/// - 开关开着：在播就计（墙钟窗口；在播起表、暂停停表，与后台听书同律；不设空闲门——
///   听歌没有滚动 / 翻页这类输入，设了门听一小时只记 10 分钟）；
/// - 开关关着（默认）：本曲发生过学习动作（歌词页查词 / 制卡 / AB 循环，见
///   [noteLearningAction]）才起表，空闲门 = 阅读空闲超时，**只由学习动作喂门**：最后
///   一次学习动作之后再听超过空闲超时，后面的窗口一律拒掉。换曲目清掉「已投入学习」。
///
/// **歌词字数（决策 qQTh1Q3G9U，所有者 2026-11-23 选 a）：字数跟着时长走，不加开关。**
/// 时钟在走的时候，带时间轴歌词的当前句被播走（自然播完 / 点下一行 / 拖进度 / 换曲）那一刻，
/// 把这句的字数（[countStudyChars]）经 [StudyClock.addChars] 入账；时钟停着（D4 判不计、
/// 暂停）字数一并不计，也不记成「已计」。去重 = **每首每句一辈子只计一次**：按曲目把已计
/// 句子的曲目时间窗并成 [IntervalCoverage]，存数据库偏好 `music_lyric_coverage_<trackUid>`
/// （与视频 `video_watch_coverage_<uid>` 同一种存放形态，跨会话保留），一句的时间窗过半已在
/// 并集里就不再计（换歌词来源 / 调偏移带来的轴抖动不重计）。只有在这句上真实播放够停留门
/// （[shouldCountCueDwell]，与视频字幕同一判据）才算播过：拖进度从这句擦过去不计。歌词
/// 不依赖歌词页：时钟可能走的时候请 [MusicLyricsLive] 在后台解析当前曲目的歌词。
///
/// 写入只经 [StudyClock]（`media_kind = music`，`media_key = track uid`，标题快照取曲名），
/// 不另立累计器。一曲一钟：换曲封段、建新钟。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:fushi_audio/fushi_audio.dart' show StudyClock;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/study_char_count.dart';
import 'package:fushi_music/fushi_music.dart' show LyricTimeline;

import 'package:fushi/src/media/music/lyrics/music_lyrics_learning.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/video/video_watch_tracker.dart'
    show
        isContinuousPlaybackAdvance,
        kPlaybackAdvanceSlackMs,
        shouldCountCueDwell;
import 'package:fushi/src/startup/exit_flush_registry.dart';
import 'package:fushi/src/stats/interval_coverage.dart';
import 'package:fushi/src/stats/study_diag_log.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 每曲「已计字的歌词句」曲目时间窗并集的偏好键前缀（值 = [IntervalCoverage.toJson]）。
const String kMusicLyricCoveragePrefPrefix = 'music_lyric_coverage_';

String musicLyricCoveragePrefKey(String trackUid) =>
    '$kMusicLyricCoveragePrefPrefix$trackUid';

/// 纯函数：曲目时间窗 `[startMs, endMs)` 这句是否已经计过字——时间窗过半已在 [counted]
/// 里即算计过。零长窗按 1 ms 处理。不改 [counted]。
bool musicLyricLineAlreadyCounted(
  IntervalCoverage counted,
  int startMs,
  int endMs,
) {
  final int end = endMs > startMs ? endMs : startMs + 1;
  final int fresh = counted.copy().add(startMs, end);
  return fresh * 2 <= end - startMs;
}

/// 纯函数：停在一句上，从上次采样（媒体位置 [fromMs]，墙钟过了 [wallMs]）到这次又真实
/// 播放了多少毫秒（截在句尾 [lineEndMs]）。
///
/// - [toMs] 非 null（同一首）：连续播放（[isContinuousPlaybackAdvance]）才算，暂停、
///   拖动跳变、倒退一律 0；
/// - [toMs] 为 null（换曲了）：只有剩下的句尾在这段墙钟里播得完（= 旧曲播到头被换下）
///   才补上句尾；手动切歌时句尾还长，补 0。
int musicLyricLinePlayedDelta({
  required int fromMs,
  required int? toMs,
  required int lineEndMs,
  required int wallMs,
  required double speed,
  required bool playing,
}) {
  if (!playing || wallMs <= 0 || fromMs >= lineEndMs) return 0;
  if (toMs == null) {
    final double rate = speed > 0 ? speed : 1.0;
    final int tail = lineEndMs - fromMs;
    final double cap = wallMs * rate * 1.25 + kPlaybackAdvanceSlackMs;
    return tail <= cap ? tail : 0;
  }
  if (!isContinuousPlaybackAdvance(
    fromMs: fromMs,
    toMs: toMs,
    wallMs: wallMs,
    speed: speed,
  )) {
    return 0;
  }
  return (toMs < lineEndMs ? toMs : lineEndMs) - fromMs;
}

/// 正在听的那一句（入句时快照：离句那一刻歌词可能已经换成下一首的了）。
class _LyricLineVisit {
  _LyricLineVisit({
    required this.trackUid,
    required this.lineIndex,
    required this.startMs,
    required this.endMs,
    required this.chars,
    required this.sampleMs,
    required this.sampleAt,
  });

  final String trackUid;
  final int lineIndex;
  final int startMs;
  final int endMs;
  final int chars;
  int playedMs = 0;
  int sampleMs;
  DateTime sampleAt;
}

/// 建时钟（测试注入假 sink / 假时间）。
typedef MusicStudyClockFactory =
    StudyClock Function({
      required FushiDatabase database,
      required MusicPlayItem item,
      required Duration? idleTimeout,
    });

StudyClock _defaultClock({
  required FushiDatabase database,
  required MusicPlayItem item,
  required Duration? idleTimeout,
}) => StudyClock(
  database: database,
  mediaKind: kActivityMediaMusic,
  mediaKey: item.trackUid,
  title: item.title,
  format: item.codec ?? '',
  idleTimeout: idleTimeout,
  deferWrite: ExitFlushRegistry.instance.defer,
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
    LyricTimeline? Function(String trackUid)? lyricsFor,
    void Function(bool wanted)? setLyricsWanted,
    MusicStudyClockFactory clockFactory = _defaultClock,
    DateTime Function()? now,
  }) : _engine = engine,
       _database = database,
       _countsAsStudy = listeningCountsAsStudy,
       _idleTimeout = idleTimeout,
       _lyricsFor = lyricsFor,
       _setLyricsWanted = setLyricsWanted,
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

  /// 当前曲目的生效歌词（[MusicLyricsLive.timelineFor]）；还没解析 / 没有为 null。
  final LyricTimeline? Function(String trackUid)? _lyricsFor;

  /// 告诉 [MusicLyricsLive]：时钟可能走，后台要解析当前曲目的歌词。
  final void Function(bool wanted)? _setLyricsWanted;
  bool? _lyricsWanted;

  StudyClock? _clock;
  String? _clockTrackUid;
  bool? _clockCountsAsStudy;
  String? _trackUid;
  DateTime? _lastLearningActionAt;

  _LyricLineVisit? _visit;
  String? _coverageUid;
  IntervalCoverage? _coverage;
  Future<void>? _coverageLoad;

  /// 时钟此刻是否在走（测试 / 诊断）。
  bool get isRunning => _clock?.isRunning ?? false;

  /// 当前曲目「已计字句子」并集加载完（测试）。
  @visibleForTesting
  Future<void> get debugCoverageLoaded => _coverageLoad ?? Future<void>.value();

  /// 歌词页上发生了学习动作（查词 / 制卡 / AB 循环）：本曲开始计入学习、喂空闲门。
  void noteLearningAction() {
    if (_engine.current == null) return;
    // 先按旧状态结算（换曲在这里清掉旧曲的「已投入」），再记这次动作。
    _sync();
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
    // 先用旧曲的钟结算离开的那一句，再换曲封段。
    _trackLyricLine(item);
    if (item?.trackUid != _trackUid) _onTrackChanged(item?.trackUid);
    final bool counts = _countsAsStudy();
    final bool lyricsWanted =
        item != null && (counts || _lastLearningActionAt != null);
    if (lyricsWanted != _lyricsWanted) {
      _lyricsWanted = lyricsWanted;
      _setLyricsWanted?.call(lyricsWanted);
    }
    if (lyricsWanted && item != null) _ensureCoverage(item.trackUid);
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
      idleTimeout: counts ? null : _idleTimeout(),
    );
    _clockTrackUid = item.trackUid;
    _clockCountsAsStudy = counts;
    // 开关关着时「最后一次学习动作之后超过空闲超时」由上面的判据在引擎每次通知时
    // 停表（位置事件约 10 Hz），时钟自己的空闲门是第二道。
    if (!clock.isRunning) clock.start();
  }

  /// 跟句：当前句变了（换句 / 换曲 / 歌词没了）就结算离开的那句；停在同一句上累计真实播放。
  void _trackLyricLine(MusicPlayItem? item) {
    final DateTime now = _now();
    final int pos = _engine.position.inMilliseconds;
    final bool playing = _engine.isPlaying;
    final double speed = _engine.currentSettings.speed;
    final LyricTimeline? t = item == null
        ? null
        : _lyricsFor?.call(item.trackUid);
    final int line = t == null || !t.isSynced
        ? -1
        : musicLyricCurrentLine(t, pos);
    final _LyricLineVisit? v = _visit;
    if (v != null) {
      final bool sameTrack = v.trackUid == item?.trackUid;
      v.playedMs += musicLyricLinePlayedDelta(
        fromMs: v.sampleMs,
        toMs: sameTrack ? pos : null,
        lineEndMs: v.endMs,
        wallMs: now.difference(v.sampleAt).inMilliseconds,
        speed: speed,
        // 换曲那一刻引擎可能已报「新曲在播」或「停了」：句尾补不补只看墙钟够不够。
        playing: sameTrack ? playing : true,
      );
      v.sampleMs = pos;
      v.sampleAt = now;
      // 同一首、歌词暂时拿不到（调偏移 / 换来源后重新解析中）：不算离句。
      if (sameTrack && (v.lineIndex == line || t == null)) return;
      _visit = null;
      _leaveLine(v);
    }
    if (t == null || line < 0 || item == null) return;
    final MusicLyricLineWindow? w = musicLyricLineWindow(
      t,
      line,
      trackDurationMs: item.durationMs,
    );
    if (w == null) return;
    _visit = _LyricLineVisit(
      trackUid: item.trackUid,
      lineIndex: line,
      startMs: w.startMs,
      endMs: w.endMs,
      chars: countStudyChars(w.text),
      sampleMs: pos,
      sampleAt: now,
    );
  }

  /// 离开一句：播够了、时钟在走、这首这句没计过，才入账并记成「已计」。
  void _leaveLine(_LyricLineVisit v) {
    if (v.chars <= 0) return;
    if (!shouldCountCueDwell(
      playedMs: v.playedMs,
      cueStartMs: v.startMs,
      cueEndMs: v.endMs,
    )) {
      return;
    }
    final StudyClock? clock = _clock;
    if (clock == null || !clock.isRunning || _clockTrackUid != v.trackUid) {
      return;
    }
    final IntervalCoverage? counted = _coverage;
    if (counted == null || _coverageUid != v.trackUid) return;
    if (musicLyricLineAlreadyCounted(counted, v.startMs, v.endMs)) return;
    counted.add(v.startMs, v.endMs > v.startMs ? v.endMs : v.startMs + 1);
    clock.addChars(v.chars);
    studyDiag(
      'music',
      'lyric line ${v.lineIndex} [${v.startMs},${v.endMs}) +${v.chars}c '
          'track=${v.trackUid}',
    );
    final FushiDatabase? db = _database();
    if (db == null) return;
    unawaited(_saveCoverage(db, v.trackUid, counted.toJson()));
  }

  Future<void> _saveCoverage(
    FushiDatabase db,
    String trackUid,
    String json,
  ) async {
    try {
      await db.setPref(musicLyricCoveragePrefKey(trackUid), json);
    } on Object catch (e, st) {
      ErrorLogService.instance.log('MusicStudyTracker.saveCoverage', e, st);
    }
  }

  /// 换到 [uid] 时加载这首的「已计字句子」并集（库还没就绪就等下一次同步再加载）。
  void _ensureCoverage(String uid) {
    if (_coverageUid == uid) return;
    final FushiDatabase? db = _database();
    if (db == null) return;
    _coverageUid = uid;
    _coverage = null;
    _coverageLoad = _loadCoverage(db, uid);
  }

  Future<void> _loadCoverage(FushiDatabase db, String uid) async {
    String? json;
    try {
      json = await db.getPref(musicLyricCoveragePrefKey(uid));
    } on Object catch (e, st) {
      ErrorLogService.instance.log('MusicStudyTracker.loadCoverage', e, st);
    }
    if (_coverageUid != uid) return;
    _coverage = IntervalCoverage.fromJson(json);
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
    _visit = null;
    _retire();
  }
}

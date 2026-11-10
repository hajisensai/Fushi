/// 视频「可达末尾」：容器总时长比音视频轨实际结束得晚时，把播放器总时长改成音视频
/// 真正结束的位置（BUG：进度条显示 23:39 / 24:02 但跳不到后面）。
///
/// 根因在文件与 libmpv，不在 app：Matroska 的 Segment Duration 由 mkvmerge 取**所有轨**
/// 的结束时间，字幕轨（例如片尾一句 ASS 标牌到 24:00）比音视频长时，容器时长就比画面
/// 和声音都长。libmpv 的 `duration` 直接报容器时长；往音视频结束之后 seek 时没有可解的
/// 帧，hr-seek 直接到 EOF，`keep-open=yes`（media_kit 默认）把位置停在最后一帧——用户
/// 看到的就是「进度条还有余量，拖过去又弹回 23:39」。实测文件 MyGO S01E03.mkv：容器
/// 1442 s，视频轨 DURATION 00:23:39.962，音频轨 00:23:40.016；libmpv
/// （`--keep-open=yes --hr-seek=yes`）seek 到 1430 s 后 EOF 落在 time-pos 1419.92。
///
/// libmpv 的 `duration` 是只读属性、`--end` 也不改它，所以修正放在 media_kit
/// [PlatformPlayer] 的时长状态上（`state` / `durationController`，Fushi 自己的
/// `WebVideoPlatformPlayer` 也是这样写时长的）：所有读 `player.state.duration` /
/// `player.stream.duration` 的界面（进度条、时间文本、横滑 / 双击 seek、章节刻度、
/// `VideoPlayerController.durationMs`）都跟着改，不需要逐个改消费方。
///
/// 依据只用容器自带的逐轨统计：mkvmerge / ffmpeg 给每条轨写的 `DURATION` 标签，libmpv 在
/// `track-list/N/metadata` 里原样给出。缺任何一条音视频轨的标签就不修正（不知道真末尾时
/// 不猜）。标签陈旧（实际播放越过了修正值）时立即撤销修正、还原容器时长。
library;

import 'dart:async';
import 'dart:convert';

import 'package:media_kit/media_kit.dart';

/// 解析 Matroska 统计标签 / ffmpeg 写的 `DURATION`（`HH:MM:SS.fffffffff`），返回微秒。
/// 格式不对返回 null。
int? parseTrackDurationTagMicros(String raw) {
  final RegExpMatch? m = RegExp(
    r'^(\d+):([0-5]\d):([0-5]\d)(?:\.(\d+))?$',
  ).firstMatch(raw.trim());
  if (m == null) return null;
  final int hours = int.parse(m.group(1)!);
  final int minutes = int.parse(m.group(2)!);
  final int seconds = int.parse(m.group(3)!);
  final String fraction = (m.group(4) ?? '').padRight(6, '0').substring(0, 6);
  final int micros = int.parse(fraction);
  return ((hours * 60 + minutes) * 60 + seconds) * 1000000 + micros;
}

/// 从 libmpv `track-list`（JSON）算音视频实际结束位置（微秒）：所有**容器内**音频 / 视频
/// 轨（不含封面图、外挂轨）`metadata.DURATION` 的最大值。
///
/// 返回 null 的情况（都表示「不知道真末尾」，调用方不修正）：JSON 解析失败、没有音视频轨、
/// 任一音视频轨缺 `DURATION` 标签或格式不对。
int? playableEndMicrosFromTrackList(String trackListJson) {
  final Object? decoded;
  try {
    decoded = jsonDecode(trackListJson);
  } on FormatException {
    return null;
  }
  if (decoded is! List) return null;
  int? end;
  for (final Object? entry in decoded) {
    if (entry is! Map) continue;
    final Object? type = entry['type'];
    if (type != 'video' && type != 'audio') continue;
    if (entry['external'] == true) continue;
    if (entry['image'] == true || entry['albumart'] == true) continue;
    final Object? metadata = entry['metadata'];
    if (metadata is! Map) return null;
    String? raw;
    for (final MapEntry<Object?, Object?> tag in metadata.entries) {
      final Object? key = tag.key;
      if (key is String && key.toUpperCase() == 'DURATION') {
        final Object? value = tag.value;
        if (value is String) raw = value;
        break;
      }
    }
    if (raw == null) return null;
    final int? micros = parseTrackDurationTagMicros(raw);
    if (micros == null || micros <= 0) return null;
    if (end == null || micros > end) end = micros;
  }
  return end;
}

/// 该显示的总时长：[playableEnd] 已知且早于容器报的 [reported] 时取 [playableEnd]，
/// 否则原样返回 [reported]。[reported] 非正（未就绪 / 直播）时不修正。
Duration effectivePlayableDuration({
  required Duration reported,
  required Duration? playableEnd,
}) {
  if (reported <= Duration.zero) return reported;
  if (playableEnd == null || playableEnd <= Duration.zero) return reported;
  return playableEnd < reported ? playableEnd : reported;
}

/// 播放位置越过修正后的末尾 = 统计标签不可信（陈旧 / 不全），应撤销修正。
bool playableEndContradictedByPosition({
  required Duration position,
  required Duration playableEnd,
}) => position > playableEnd;

/// 把一次 load 的「可达末尾」修正挂到 media_kit [PlatformPlayer] 的时长状态上。
///
/// 生命周期 = 一次 load：换集（同一 player 复用）/ 销毁前必须 [dispose]，否则旧片的
/// 修正会盖到新片的时长上。
class VideoPlayableEndCorrection {
  VideoPlayableEndCorrection._(this._platform, this.playableEnd);

  /// 对 [platform] 应用修正。容器时长不长于 [playableEnd]（或还没就绪）时不需要修正，
  /// 返回 null。
  static VideoPlayableEndCorrection? attach({
    required PlatformPlayer platform,
    required Duration playableEnd,
  }) {
    final Duration reported = platform.state.duration;
    if (effectivePlayableDuration(
          reported: reported,
          playableEnd: playableEnd,
        ) ==
        reported) {
      return null;
    }
    final VideoPlayableEndCorrection correction = VideoPlayableEndCorrection._(
      platform,
      playableEnd,
    );
    correction._reportedDuration = reported;
    correction._listen();
    correction._publish(playableEnd);
    return correction;
  }

  final PlatformPlayer _platform;

  /// 音视频实际结束位置（修正后的总时长）。
  final Duration playableEnd;

  /// libmpv 最近一次报的容器时长（撤销修正时还原成它）。
  Duration _reportedDuration = Duration.zero;

  /// 容器报的时长（修正前）。
  Duration get reportedDuration => _reportedDuration;

  bool _active = true;

  /// 修正仍在生效（未被播放位置推翻、未 [dispose]）。
  bool get active => _active;

  final List<StreamSubscription<Duration>> _subs =
      <StreamSubscription<Duration>>[];

  void _listen() {
    _subs
      ..add(
        _platform.stream.duration.listen((Duration d) {
          if (!_active || d == playableEnd) return;
          // libmpv 再报一次容器时长（属性重发）：记下原值，重新盖上修正。
          _reportedDuration = d;
          final Duration effective = effectivePlayableDuration(
            reported: d,
            playableEnd: playableEnd,
          );
          if (effective != d) _publish(effective);
        }),
      )
      ..add(
        _platform.stream.position.listen((Duration p) {
          if (!_active) return;
          if (!playableEndContradictedByPosition(
            position: p,
            playableEnd: playableEnd,
          )) {
            return;
          }
          // 实际播放越过了统计标签给的末尾：标签不可信，还原容器时长。
          _active = false;
          _cancel();
          _publish(_reportedDuration);
        }),
      );
  }

  void _publish(Duration duration) {
    _platform.state = _platform.state.copyWith(duration: duration);
    if (!_platform.durationController.isClosed) {
      _platform.durationController.add(duration);
    }
  }

  void _cancel() {
    for (final StreamSubscription<Duration> s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
  }

  /// 结束本次 load 的修正（不改播放器状态：新片的时长由 libmpv 重新上报）。
  void dispose() {
    _active = false;
    _cancel();
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:fushi/src/platform/widget_links.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

/// 快照里最多带几张「书架」卡（含「继续」那张）。
const int kWidgetShelfLimit = 4;

/// 周图表的天数（最旧 → 今天）。
const int kWidgetWeekDays = 7;

/// 小组件上所有文案（已按 app 内语言本地化）。键名与原生侧
/// `WidgetSnapshot.kt` 的 `labels` 一一对应，改名要两边同步。
class WidgetSnapshotLabels {
  const WidgetSnapshotLabels({
    required this.kindBook,
    required this.kindManga,
    required this.kindVideo,
    required this.resume,
    required this.today,
    required this.streak,
    required this.srsDue,
    required this.srsOff,
    required this.review,
    required this.srsDone,
    required this.recent,
    required this.weekly,
    required this.books,
    required this.manga,
    required this.video,
    required this.lookup,
    required this.openToSetUp,
  });

  final String kindBook;
  final String kindManga;
  final String kindVideo;
  final String resume;
  final String today;
  final String streak;
  final String srsDue;
  final String srsOff;
  final String review;
  final String srsDone;
  final String recent;
  final String weekly;
  final String books;
  final String manga;
  final String video;
  final String lookup;
  final String openToSetUp;

  Map<String, String> toJson() => <String, String>{
    'kind_book': kindBook,
    'kind_manga': kindManga,
    'kind_video': kindVideo,
    'resume': resume,
    'today': today,
    'streak': streak,
    'srsDue': srsDue,
    'srsOff': srsOff,
    'review': review,
    'srsDone': srsDone,
    'recent': recent,
    'weekly': weekly,
    'books': books,
    'manga': manga,
    'video': video,
    'lookup': lookup,
    'openToSetUp': openToSetUp,
  };
}

/// 一条可「继续」的媒体（书 / 漫画 / 视频），数值是未清洗的原始输入。
class WidgetMediaInput {
  const WidgetMediaInput({
    required this.kind,
    required this.id,
    required this.title,
    required this.recentAt,
    this.subtitle = '',
    this.progress = 0,
    this.coverPath = '',
  });

  final WidgetMediaKind kind;

  /// 书 / 漫画 = `MediaItem.mediaIdentifier`，视频 = `VideoBookRow.bookUid`。
  final String id;
  final String title;

  /// 作者；没有就空串。
  final String subtitle;

  /// 进度分数；越界或 NaN 由 [buildWidgetSnapshot] 夹到 0..1。
  final double progress;

  /// 本机封面图文件的绝对路径；调用方已确认存在、可读，不确定就传空串。
  final String coverPath;

  /// 最近活动时刻（epoch 毫秒），只用于排序。
  final int recentAt;
}

/// 今日学习数字（原始值，格式化在 [buildWidgetSnapshot] 里做）。
class WidgetTodayInput {
  const WidgetTodayInput({
    this.ms = 0,
    this.chars = 0,
    this.goalChars = 0,
    this.streak = 0,
  });

  final int ms;
  final int chars;

  /// 每日字数目标；<= 0 = 没设目标。
  final int goalChars;
  final int streak;
}

/// 近 7 天数字（原始值）。
class WidgetWeekInput {
  const WidgetWeekInput({
    this.minutes = const <int>[],
    this.days = const <String>[],
    this.totalMs = 0,
    this.totalChars = 0,
  });

  /// 每天学习分钟数，最旧 → 今天；不足 7 补 0 在**前**，多于 7 取最近 7 个。
  final List<int> minutes;

  /// 每天的星期标签，与 [minutes] 同序；同样补 / 截到 7。
  final List<String> days;
  final int totalMs;
  final int totalChars;
}

/// 夹到 0..1；NaN / 无穷当 0。
double clampWidgetFraction(double value) {
  if (value.isNaN || value.isInfinite) return 0;
  if (value < 0) return 0;
  if (value > 1) return 1;
  return value;
}

/// 把原始输入收成原生侧约定的 JSON 对象（纯函数，不碰 IO / provider）。
///
/// - 关掉的模块（[moduleBooks] 等）：对应的媒体条目先出局，再取「继续」与书架，
///   不会出现「关掉漫画后继续卡还是漫画」。
/// - 「继续」= 按 [WidgetMediaInput.recentAt] 倒序的第一条；书架 = 前
///   [kWidgetShelfLimit] 条（含「继续」那条，排第一）。同时刻稳定按输入顺序。
/// - 进度夹到 0..1；封面路径不为空才带，空串表示没有。
/// - 复习：[srsEnabled] 为 false 时 `due` 恒 0（原生侧据此画「复习未开启」）。
/// - [formatTime] / [formatChars] 由调用方注入（走 i18n 的统计页格式化），这里
///   不直接依赖 slang，单测不用初始化语言。
Map<String, Object?> buildWidgetSnapshot({
  required String day,
  required WidgetSnapshotLabels labels,
  required bool moduleBooks,
  required bool moduleManga,
  required bool moduleVideo,
  required bool moduleLookup,
  required List<WidgetMediaInput> media,
  required WidgetTodayInput today,
  required WidgetWeekInput week,
  required bool srsEnabled,
  required int srsDue,
  required String Function(int ms) formatTime,
  required String Function(int chars) formatChars,
}) {
  bool enabled(WidgetMediaKind kind) => switch (kind) {
    WidgetMediaKind.book => moduleBooks,
    WidgetMediaKind.manga => moduleManga,
    WidgetMediaKind.video => moduleVideo,
  };
  final List<WidgetMediaInput> visible = <WidgetMediaInput>[
    for (final WidgetMediaInput m in media)
      if (enabled(m.kind) && m.id.isNotEmpty) m,
  ];
  // List.sort 不稳定：带上输入序号做平局决胜。
  final List<int> order = <int>[for (int i = 0; i < visible.length; i++) i]
    ..sort((int a, int b) {
      final int byRecent = visible[b].recentAt.compareTo(visible[a].recentAt);
      return byRecent != 0 ? byRecent : a.compareTo(b);
    });
  final List<Map<String, Object?>> shelf = <Map<String, Object?>>[
    for (final int i in order.take(kWidgetShelfLimit)) _mediaJson(visible[i]),
  ];

  final double goal = today.goalChars > 0
      ? clampWidgetFraction(today.chars / today.goalChars)
      : 0;

  return <String, Object?>{
    'day': day,
    'labels': labels.toJson(),
    'modules': <String, bool>{
      'books': moduleBooks,
      'manga': moduleManga,
      'video': moduleVideo,
      'lookup': moduleLookup,
    },
    'continue': shelf.isEmpty ? null : shelf.first,
    'shelf': shelf,
    'today': <String, Object?>{
      'time': formatTime(_nonNegative(today.ms)),
      'chars': formatChars(_nonNegative(today.chars)),
      'goal': goal,
      'streak': _nonNegative(today.streak),
    },
    'week': <String, Object?>{
      'minutes': _fitToWeek<int>(<int>[
        for (final int m in week.minutes) _nonNegative(m),
      ], 0),
      'days': _fitToWeek<String>(week.days, ''),
      'time': formatTime(_nonNegative(week.totalMs)),
      'chars': formatChars(_nonNegative(week.totalChars)),
    },
    'srs': <String, Object?>{
      'enabled': srsEnabled,
      'due': srsEnabled ? _nonNegative(srsDue) : 0,
    },
  };
}

Map<String, Object?> _mediaJson(WidgetMediaInput m) => <String, Object?>{
  'kind': m.kind.wire,
  'id': m.id,
  'title': m.title.trim(),
  'subtitle': m.subtitle.trim(),
  'progress': clampWidgetFraction(m.progress),
  'cover': m.coverPath,
};

int _nonNegative(int value) => value < 0 ? 0 : value;

List<T> _fitToWeek<T>(List<T> values, T filler) {
  if (values.length >= kWidgetWeekDays) {
    return values.sublist(values.length - kWidgetWeekDays);
  }
  return <T>[
    for (int i = values.length; i < kWidgetWeekDays; i++) filler,
    ...values,
  ];
}

/// 把快照 JSON 发给原生侧（Android 桌面小组件）。只在 Android 上生效，其余平台
/// no-op；原生侧存下来并重绘小组件。
///
/// 调用方可以随便高频调，本类按 JSON 全文签名去重，数据没变就不过通道。
class WidgetSnapshotPublisher {
  @visibleForTesting
  WidgetSnapshotPublisher({
    required this.platformSupported,
    MethodChannel channel = FushiChannels.widgets,
  }) : _channel = channel;

  static final WidgetSnapshotPublisher instance = WidgetSnapshotPublisher(
    platformSupported: !kIsWeb && Platform.isAndroid,
  );

  /// 只有 Android 有原生侧；其余平台发了也是 MissingPluginException。
  final bool platformSupported;

  final MethodChannel _channel;

  String? _lastSignature;

  /// 签名没变 / 平台不支持时直接返回；否则返回的 Future 在原生侧应答（或失败）
  /// 后完成，调用方可以不等。
  Future<void> publish(Map<String, Object?> snapshot) async {
    if (!platformSupported) return;
    final String json = jsonEncode(snapshot);
    if (json == _lastSignature) return;
    _lastSignature = json;
    try {
      await _channel.invokeMethod<void>('updateSnapshot', json);
    } on Object catch (error) {
      // 发布失败只影响小组件，不影响 app 本身；清掉签名让下一次触发重试。
      if (_lastSignature == json) _lastSignature = null;
      debugPrint('WidgetSnapshotPublisher: updateSnapshot failed: $error');
    }
  }
}

/// `snapshot.json` 的 Dart 形状，与 Swift `FushiWidgetSnapshot`
/// （`fushi/apple/HomeWidgets/Shared/FushiWidgetSnapshot.swift`）逐字段对应。
///
/// 所有用户可见文字都在这里按 app 内语言排好，扩展只负责排版。
library;

const int kHomeWidgetSnapshotVersion = 1;

class HomeWidgetSnapshot {
  const HomeWidgetSnapshot({
    required this.generatedAt,
    required this.labels,
    this.srs,
    this.study,
    this.continueItems = const <HomeWidgetContinueItem>[],
    this.word,
    this.audiobook,
  });

  final int generatedAt;
  final Map<String, String> labels;
  final HomeWidgetSrsSection? srs;
  final HomeWidgetStudySection? study;
  final List<HomeWidgetContinueItem> continueItems;
  final HomeWidgetWord? word;
  final HomeWidgetContinueItem? audiobook;

  Map<String, Object?> toJson() => <String, Object?>{
    'v': kHomeWidgetSnapshotVersion,
    'at': generatedAt,
    'labels': labels,
    'srs': srs?.toJson(),
    'study': study?.toJson(),
    'continue': <Map<String, Object?>>[
      for (final HomeWidgetContinueItem item in continueItems) item.toJson(),
    ],
    'word': word?.toJson(),
    'audiobook': audiobook?.toJson(),
  };
}

class HomeWidgetSrsEntry {
  const HomeWidgetSrsEntry({
    required this.at,
    required this.due,
    required this.caption,
    required this.inline,
  });

  final int at;
  final int due;
  final String caption;
  final String inline;

  Map<String, Object?> toJson() => <String, Object?>{
    'at': at,
    'due': due,
    'caption': caption,
    'inline': inline,
  };
}

class HomeWidgetSrsSection {
  const HomeWidgetSrsSection({
    required this.timeline,
    required this.newCount,
    required this.learning,
    required this.review,
    required this.url,
  });

  /// 第一项 = 现在；之后是预排的到期节点（升序）。
  final List<HomeWidgetSrsEntry> timeline;
  final int newCount;
  final int learning;
  final int review;
  final String url;

  Map<String, Object?> toJson() => <String, Object?>{
    'timeline': <Map<String, Object?>>[
      for (final HomeWidgetSrsEntry e in timeline) e.toJson(),
    ],
    'newCount': newCount,
    'learning': learning,
    'review': review,
    'url': url,
  };
}

class HomeWidgetStudyDay {
  const HomeWidgetStudyDay({
    required this.streak,
    required this.streakCaption,
    required this.todayLine,
    required this.last7,
  });

  final int streak;
  final String streakCaption;
  final String todayLine;

  /// 近 7 天强度 0…1，最后一格是今天；-1 = 今天还没学。
  final List<double> last7;

  Map<String, Object?> toJson() => <String, Object?>{
    'streak': streak,
    'streakCaption': streakCaption,
    'todayLine': todayLine,
    'last7': last7,
  };
}

class HomeWidgetStudySection {
  const HomeWidgetStudySection({
    required this.today,
    required this.tomorrow,
    required this.midnightAt,
    required this.heat,
    required this.weekValue,
    required this.weekCaption,
    required this.cardsValue,
    required this.cardsCaption,
    required this.url,
  });

  final HomeWidgetStudyDay today;
  final HomeWidgetStudyDay tomorrow;
  final int midnightAt;

  /// 近 16 周 × 7 天（按列：每 7 格一周，最旧在前），每格 0…4 档；最后一格是今天，
  /// -1 = 今天还没学。
  final List<int> heat;
  final String weekValue;
  final String weekCaption;
  final String cardsValue;
  final String cardsCaption;
  final String url;

  Map<String, Object?> toJson() => <String, Object?>{
    'today': today.toJson(),
    'tomorrow': tomorrow.toJson(),
    'midnightAt': midnightAt,
    'heat': heat,
    'weekValue': weekValue,
    'weekCaption': weekCaption,
    'cardsValue': cardsValue,
    'cardsCaption': cardsCaption,
    'url': url,
  };
}

/// 种类值域只给小组件挑图标用（`FushiKindSymbol`）。
enum HomeWidgetItemKind { book, manga, video, audiobook, game }

class HomeWidgetContinueItem {
  const HomeWidgetContinueItem({
    required this.kind,
    required this.id,
    required this.title,
    required this.subtitle,
    required this.url,
    this.progress,
    this.progressLabel,
    this.cover,
  });

  final HomeWidgetItemKind kind;
  final String id;
  final String title;
  final String subtitle;
  final String url;
  final double? progress;
  final String? progressLabel;

  /// 相对 `home_widgets/` 的封面路径（`covers/<hash>.png`）。
  final String? cover;

  HomeWidgetContinueItem withCover(String? cover) => HomeWidgetContinueItem(
    kind: kind,
    id: id,
    title: title,
    subtitle: subtitle,
    url: url,
    progress: progress,
    progressLabel: progressLabel,
    cover: cover,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.name,
    'id': id,
    'title': title,
    'subtitle': subtitle,
    'progress': progress,
    'progressLabel': progressLabel,
    'cover': cover,
    'url': url,
  };
}

class HomeWidgetWord {
  const HomeWidgetWord({
    required this.term,
    required this.meaning,
    required this.url,
    this.reading,
    this.sentence,
    this.source,
  });

  final String term;

  /// 卡片 / 收藏自带的读音字段原样带过去；没有就是 null（不做任何读音推断）。
  final String? reading;
  final String meaning;
  final String? sentence;
  final String? source;
  final String url;

  Map<String, Object?> toJson() => <String, Object?>{
    'term': term,
    'reading': reading,
    'meaning': meaning,
    'sentence': sentence,
    'source': source,
    'url': url,
  };
}

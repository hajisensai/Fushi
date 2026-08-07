/// 阅读统计的本地缓存（Drift/SQLite）。
///
/// 每条记录对应一本书某一天的阅读数据（字数 + 时长）。
/// 复合唯一索引 `(title, dateKey)`。
class ReadingStatistic {
  int? id;

  late String title;

  late String dateKey;

  late int charactersRead;

  /// 阅读时长，单位毫秒。
  late int readingTimeMs;

  late int lastStatisticModified;
}

/// ttu IndexedDB `statistic` store 的本地缓存。
///
/// 每条记录对应一本书某一天的阅读数据（字数 + 时长）。
/// 复合唯一索引 `(title, dateKey)` 镜像 IDB 的 compound key path。
class ReadingStatistic {
  int? id;

  late String title;

  late String dateKey;

  late int charactersRead;

  /// 阅读时长，单位毫秒（ttu IDB 存秒，读取时 ×1000 转换）。
  late int readingTimeMs;

  late int lastStatisticModified;
}

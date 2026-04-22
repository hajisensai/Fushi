import 'package:isar/isar.dart';

part 'reading_statistic_model.g.dart';

/// ttu IndexedDB `statistic` store 的本地缓存。
///
/// 每条记录对应一本书某一天的阅读数据（字数 + 时长）。
/// 复合唯一索引 `(title, dateKey)` 镜像 IDB 的 compound key path，
/// `replace: true` 使 putAll 幂等——同步时不需要 diff 或删除。
@Collection()
class ReadingStatistic {
  Id id = Isar.autoIncrement;

  @Index(composite: [CompositeIndex('dateKey')], unique: true, replace: true)
  late String title;

  late String dateKey;

  late int charactersRead;

  /// 阅读时长，单位毫秒（与 ttu IDB 一致）。
  late int readingTimeMs;

  late int lastStatisticModified;
}

/// 用户在待确认队列里「忽略、不再提示」的作品（反馈 Fbchzxuq6f）。
///
/// 待确认判据是「作品没有规范身份」（见 `video_library_scrape_sweep.dart`）。SP /
/// OVA / 预告片 / 制作花絮这类特典在任何资料源上都**本来就没有条目**，判据对它们
/// 永远成立：库页提醒条永远亮着、待确认队列永远清不空，自动补刮还会每 7 天替它们
/// 联网白查一遍。用户唯一能做的「确认」就是告诉 app「这部不用认」——这里记的就是
/// 这个决定。
///
/// 按作品单元的 `VideoSourceScrapeWork.stableKey` 记（`collection:<id>` /
/// `book:<uid>`，与待确认队列、手动指定同一把键），永久生效直到用户在待确认队列
/// 里撤销。值落在 `preferences` 表的一个键里（JSON 字符串数组），不升 schema：
/// 键里是本机合集自增 id / 书 uid，属于设备本地状态（不进备份导出 / 同步 / Profile
/// 快照，见 app 侧 `SyncRepository.deviceLocalPrefKeys` 与 `ProfileKeys`）。
library;

import 'dart:convert';

import 'package:fushi_core/fushi_core.dart';

/// 已忽略作品的偏好键（值：JSON 字符串数组，元素是作品 stableKey）。
const String kVideoScrapeIgnoredWorksPrefKey = 'video_scrape_ignored_works';

/// 读已忽略的作品 stableKey 集合。值缺失 / 损坏一律当作空集（= 不忽略任何作品：
/// 宁可多提醒，也不静默吞掉待确认作品）。
Future<Set<String>> loadIgnoredVideoScrapeWorks(FushiDatabase database) async =>
    decodeIgnoredVideoScrapeWorks(
      await database.getPref(kVideoScrapeIgnoredWorksPrefKey),
    );

/// [loadIgnoredVideoScrapeWorks] 的纯解码部分。
Set<String> decodeIgnoredVideoScrapeWorks(String? raw) {
  if (raw == null || raw.isEmpty) return <String>{};
  try {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! List<Object?>) return <String>{};
    return <String>{
      for (final Object? key in decoded)
        if (key is String && key.isNotEmpty) key,
    };
  } on FormatException {
    return <String>{};
  }
}

/// 把 [stableKeys] 标为忽略（[ignored] = true）或撤销忽略。读改写在一个事务里，
/// 并发的两次切换不会互相覆盖。集合变空时删键，不留空数组。
Future<void> setVideoScrapeWorksIgnored(
  FushiDatabase database,
  Iterable<String> stableKeys, {
  required bool ignored,
}) => database.transaction(() async {
  final Set<String> keys = await loadIgnoredVideoScrapeWorks(database);
  final int before = keys.length;
  final List<String> changed = stableKeys
      .where((String key) => key.isNotEmpty)
      .toList(growable: false);
  if (ignored) {
    keys.addAll(changed);
  } else {
    keys.removeAll(changed);
  }
  if (keys.length == before) return;
  if (keys.isEmpty) {
    await database.deletePref(kVideoScrapeIgnoredWorksPrefKey);
    return;
  }
  final List<String> sorted = keys.toList()..sort();
  await database.setPref(kVideoScrapeIgnoredWorksPrefKey, jsonEncode(sorted));
});

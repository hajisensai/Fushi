/// 「已装扩展里哪些有新版」——纯函数，扩展页角标与 v101 更新提醒共用同一份判据。
///
/// 抽出来的理由：此前这个判据只活在 `mihon_extensions_page.dart` 的一个 build
/// 方法里，于是「有更新」这件事只在用户主动打开扩展页时才存在。要让它也能投递
/// 成提醒，判据必须先离开 widget。
library;

import 'package:fushi_core/fushi_core.dart' show MangaExtensionRow;

import 'package:fushi/src/media/manga/mihon/mihon_extension_store_client.dart';

/// 一条「这个已装扩展有新版」的事实。
class MihonExtensionUpdate {
  const MihonExtensionUpdate({
    required this.available,
    required this.installed,
  });

  final MihonAvailableExtension available;
  final MangaExtensionRow installed;

  String get packageName => installed.packageName;
  int get versionCode => available.extensionVersionCode;
}

/// 已装扩展中，仓库索引里版本更高的那些。
///
/// 判据是 `>` 而不是 `!=`，与扩展页角标逐字一致（BUG-1996）：两侧同量（DB 列存
/// 的就是 APK 的 `android:versionCode`，索引给的是同一个数），而 `!=` 会在**已装
/// 版本比仓库新**时（本地侧载 / 同包多仓库）误报「有更新」，点下去必得
/// `DOWNGRADE_REJECTED`。
///
/// 同一 packageName 在多个仓库里都有时取**版本号最高**的那条：用户看到的角标与
/// 点下去会装到的版本必须是同一个，否则提醒说 v7、装完还是 v5。
List<MihonExtensionUpdate> mihonExtensionUpdates({
  required Iterable<MihonAvailableExtension> available,
  required Iterable<MangaExtensionRow> installed,
}) {
  final Map<String, MangaExtensionRow> installedByPackage =
      <String, MangaExtensionRow>{
    for (final MangaExtensionRow row in installed) row.packageName: row,
  };
  final Map<String, MihonExtensionUpdate> best =
      <String, MihonExtensionUpdate>{};
  for (final MihonAvailableExtension candidate in available) {
    final MangaExtensionRow? row = installedByPackage[candidate.packageName];
    if (row == null) continue;
    if (candidate.extensionVersionCode <= row.versionCode) continue;
    final MihonExtensionUpdate? current = best[candidate.packageName];
    if (current != null &&
        current.available.extensionVersionCode >=
            candidate.extensionVersionCode) {
      continue;
    }
    best[candidate.packageName] =
        MihonExtensionUpdate(available: candidate, installed: row);
  }
  return best.values.toList(growable: false);
}

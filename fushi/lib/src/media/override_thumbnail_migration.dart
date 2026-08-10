import 'dart:io';

import 'package:drift/drift.dart' show QueryRow;
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// W2-3：override 封面**文件名**的 mediaIdentifier 前缀换代清扫。
///
/// override 封面落盘文件名 = `key.hashCode`（`MediaSource._overrideThumbnailPath`），
/// 规范 key = `<mediaId>/override_thumbnail`；BUG-1317 之前的 legacy key 还把源键
/// 烧进去（`<mediaId>/<srcId>/override_thumbnail`）。v73 把库内 mediaIdentifier 的
/// `hoshi://` 前缀改成 `fushi://` 后，按新 id 现算的规范文件名不再命中旧文件——
/// 本清扫按新 id 反推全部旧形态文件名，就地 rename 到新规范名，一次性终结
/// （顺带把 BUG-1317 读取期收养欠账也归位：旧 legacy 形态一并搬到规范名）。
///
/// 旧字面量（`hoshi://` 前缀、legacy 源键 `reader_ttu`）只允许活在本迁移文件里。
/// 幂等：目标名已存在即跳过；rename 失败逐文件吞掉并整体报「未完成」，由调用方
/// 不落已完成标记、下次启动重试。

/// 清扫完成标记（Drift preferences 表；置位后不再扫）。
const String kOverrideThumbnailPrefixMigratedPrefKey =
    'override_thumbnail_prefix_migrated';

/// 规范 override 封面文件名（与 `MediaSource.getOverrideThumbnailFilename`
/// 的 key 派生逐字节一致）。
String canonicalOverrideThumbnailName(String mediaIdentifier) =>
    '$mediaIdentifier/override_thumbnail'.hashCode.toString();

/// 一个新形态 identifier 对应的全部旧形态文件名，按优先级排列：旧规范形态在
/// 前（BUG-1317 之后写的），三个 legacy 烧源键形态在后（BUG-1317 之前写的；
/// 书族三源的历史持久化源键是 reader_ttu / reader_pdf / reader_manga——前者
/// 已在 W2-1 改名，但烧进 hashCode 的字面量是当年的旧值，永远不变）。
List<String> legacyOverrideThumbnailNames(String newMediaIdentifier) {
  final String oldId = newMediaIdentifier
      .replaceFirst('fushi://book/', 'hoshi://book/')
      .replaceFirst('fushi://srtbook/', 'hoshi://srtbook/');
  return <String>[
    '$oldId/override_thumbnail'.hashCode.toString(),
    for (final String srcId in <String>[
      'reader_ttu',
      'reader_pdf',
      'reader_manga',
    ])
      '$oldId/$srcId/override_thumbnail'.hashCode.toString(),
  ];
}

/// 对全部书族条目做一次清扫。返回 true = 干净完成（可落完成标记）；false =
/// 有 rename 失败（句柄占用等），调用方不落标记、下次启动重试。
Future<bool> migrateOverrideThumbnailPrefixes({
  required FushiDatabase db,
  required Directory thumbnailsDirectory,
}) async {
  if (!thumbnailsDirectory.existsSync()) return true;
  // v80 起最近打开流在 media_open_history（media_id = 旧 media_identifier 语义）。
  final List<QueryRow> rows = await db
      .customSelect(
        'SELECT DISTINCT media_id FROM media_open_history '
        "WHERE media_id LIKE 'fushi://book/%' "
        "OR media_id LIKE 'fushi://srtbook/%'",
      )
      .get();
  bool clean = true;
  for (final QueryRow row in rows) {
    final String id = row.read<String>('media_id');
    final File target = File(
        p.join(thumbnailsDirectory.path, canonicalOverrideThumbnailName(id)));
    if (target.existsSync()) continue;
    for (final String legacyName in legacyOverrideThumbnailNames(id)) {
      final File legacy = File(p.join(thumbnailsDirectory.path, legacyName));
      if (!legacy.existsSync()) continue;
      try {
        legacy.renameSync(target.path);
      } catch (_) {
        clean = false;
      }
      break; // 命中第一个旧形态即定案；后面的更旧形态不再覆盖。
    }
  }
  return clean;
}

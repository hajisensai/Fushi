import 'dart:math';

import 'package:hibiki/src/sync/ttu_models.dart';

/// ッツ Ebook Reader 兼容的文件名生成/解析/sanitize。
///
/// 文件名格式: `{type}_1_6_{timestamp}_{metrics}.json`
/// 文件夹名: sanitized book title（与 ッツ web 实现一致）。
///
/// 注意：hibiki_core 有一份逐字节等价的私有副本（`src/utils/ttu_sanitize.dart`），
/// 供 v38 拆集迁移在 core 内派生视频每集 bookUid（core 不能依赖 app 层）。两份由
/// `video_book_uid_core_parity_test` 守卫；本函数是 app 侧真相源，改了必须同步那份。
String sanitizeTtuFilename(String title) {
  String result = title;
  if (result.endsWith(' ')) {
    result = '${result.substring(0, result.length - 1)}~ttu-spc~';
  }
  if (result.endsWith('.')) {
    result = '${result.substring(0, result.length - 1)}~ttu-dend~';
  }
  result = result.replaceAll('*', '~ttu-star~');
  result = result.replaceAllMapped(
    RegExp(r'[/?\<>\\:|%"]'),
    (match) => match[0]!
        .codeUnits
        .map((c) => '%${c.toRadixString(16).toUpperCase().padLeft(2, '0')}')
        .join(),
  );
  return result;
}

String progressFileName(int timestampMs, double progress) =>
    'progress_1_6_${timestampMs}_$progress.json';

String audioBookFileName(int timestampMs, double positionSec) =>
    'audioBook_1_6_${timestampMs}_$positionSec.json';

/// The ッツ per-book file names that legitimately live ONLY inside a book's
/// folder (`<root>/<sanitizedTitle>/`): the churning progress / statistics /
/// audioBook JSON plus the book cover. Every one starts with its type followed
/// by the `_1_6` schema marker, then `_` (JSON) or `.` (cover extension).
///
/// A file matching this pattern sitting as a *direct child of the sync root* is
/// spill: the old empty-title `ensureBookFolder('')` collapsed `<root>/<''>/`
/// onto the root itself, scattering these files next to real book folders
/// (BUG-619 / TODO-1329 stopped the source). Because their timestamp filenames
/// churn every export and the single-file `findSyncFileByPrefix` dedup only
/// ever tracks one, spilled copies pile up into many (`丢很多份`, TODO-1340).
/// Used to detect and sweep that residue — callers MUST additionally require the
/// entry to be a non-folder direct child of the root (a book's own folder may be
/// named anything, so name alone is not enough).
final RegExp _ttuPerBookFilePattern =
    RegExp(r'^(?:progress|statistics|audioBook|cover)_1_6[._]');

bool isTtuPerBookFileName(String fileName) =>
    _ttuPerBookFilePattern.hasMatch(fileName);

String statisticsFileName(List<TtuStatistics> stats) {
  double readingTime = 0;
  int charactersRead = 0;
  int minSpeed = 0;
  int altMinSpeed = 0;
  int maxSpeed = 0;
  int weightedSum = 0;
  int validDays = 0;
  int lastModified = 0;

  for (final stat in stats) {
    readingTime += stat.readingTimeSec;
    charactersRead += stat.charactersRead;
    minSpeed = minSpeed > 0
        ? min(minSpeed, stat.minReadingSpeed)
        : stat.minReadingSpeed;
    altMinSpeed = altMinSpeed > 0
        ? min(altMinSpeed, stat.altMinReadingSpeed)
        : stat.altMinReadingSpeed;
    maxSpeed = max(maxSpeed, stat.lastReadingSpeed);
    weightedSum += stat.readingTimeSec.toInt() * stat.charactersRead;
    lastModified = max(lastModified, stat.lastStatisticModified);
    if (stat.readingTimeSec > 0) validDays++;
  }

  final double avgTime =
      validDays > 0 ? (readingTime / validDays).ceilToDouble() : 0;
  final double avgWeightedTime =
      charactersRead > 0 ? (weightedSum / charactersRead).ceilToDouble() : 0;
  final double avgChars =
      validDays > 0 ? (charactersRead / validDays).ceilToDouble() : 0;
  final double avgWeightedChars =
      readingTime > 0 ? (weightedSum / readingTime).ceilToDouble() : 0;
  final double lastSpeed = readingTime > 0
      ? (3600.0 * charactersRead / readingTime).ceilToDouble()
      : 0;
  final double avgSpeed =
      avgTime > 0 ? (3600 * avgChars / avgTime).ceilToDouble() : 0;
  final double avgWeightedSpeed = avgWeightedTime > 0
      ? (3600 * avgWeightedChars / avgWeightedTime).ceilToDouble()
      : 0;

  return 'statistics_1_6_'
      '${lastModified}_'
      '${charactersRead}_'
      '${readingTime}_'
      '${minSpeed}_'
      '${altMinSpeed}_'
      '${lastSpeed.toInt()}_'
      '${maxSpeed}_'
      '${avgTime.toInt()}_'
      '${avgWeightedTime.toInt()}_'
      '${avgChars.toInt()}_'
      '${avgWeightedChars.toInt()}_'
      '${avgSpeed.toInt()}_'
      '${avgWeightedSpeed.toInt()}_'
      'na.json';
}

int? parseProgressTimestamp(String fileName) {
  if (!fileName.startsWith('progress_')) return null;
  final parts = fileName.split('_');
  if (parts.length < 5) return null;
  return int.tryParse(parts[3]);
}

/// 从封面文件字节的 magic bytes 推断 MIME type 和扩展名。
({String mimeType, String extension}) detectCoverFormat(List<int> bytes) {
  if (bytes.length >= 4) {
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return (mimeType: 'image/png', extension: 'png');
    }
    if (bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38) {
      return (mimeType: 'image/gif', extension: 'gif');
    }
    if (bytes[0] == 0x42 && bytes[1] == 0x4D) {
      return (mimeType: 'image/bmp', extension: 'bmp');
    }
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46) {
      return (mimeType: 'image/webp', extension: 'webp');
    }
  }
  return (mimeType: 'image/jpeg', extension: 'jpeg');
}

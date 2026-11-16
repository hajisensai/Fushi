import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'package:fushi/src/utils/misc/local_audio_db.dart';

/// Yomitan 本地音频服务器导出的库一律叫 `android.db`（不分语种、不分来源），
/// 拿它当显示名，用户在音频源列表里只能看到一排同名的「android.db」。
const String _kGenericYomitanStem = 'android';

/// 显示名里最多直接列出的子来源个数，其余折成 `+N`。
const int _kMaxListedSources = 3;

/// 新导入本地音频库的默认显示名（纯函数，便于测试）。
///
/// - 文件名是 Yomitan 通用名 `android.db` 时，按库里实际的子来源起名：
///   `daijisen · forvo · jpod +6`（来源按字母序，保证同一份库在任何设备上同名；
///   显示名也是跨设备同步的去重键）；
/// - 其他文件名保留用户自己起的名字，只去掉 `.db` 扩展名；
/// - 读不到来源时退回文件名，绝不给空名。
String localAudioDisplayNameFor(String fileName, List<String> sources) {
  final String stem = p.extension(fileName).toLowerCase() == '.db'
      ? p.basenameWithoutExtension(fileName)
      : fileName;
  final String fallback = stem.trim().isEmpty ? fileName : stem;
  if (stem.toLowerCase() != _kGenericYomitanStem) return fallback;
  final List<String> names =
      sources
          .map((String s) => s.trim())
          .where((String s) => s.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
  if (names.isEmpty) return fallback;
  final String listed = names.take(_kMaxListedSources).join(' · ');
  final int rest = names.length - _kMaxListedSources;
  return rest > 0 ? '$listed +$rest' : listed;
}

/// 读 [dbPath] 的子来源，给出导入时的默认显示名。`SELECT DISTINCT source` 在
/// 没有来源索引的 GB 级库上要整表扫描，放后台 isolate，不卡 UI。
Future<String> suggestLocalAudioDisplayName(String dbPath) async {
  final List<String> sources = await Isolate.run(
    () => LocalAudioDb.listSources(dbPath),
  );
  return localAudioDisplayNameFor(p.basename(dbPath), sources);
}

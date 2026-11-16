import 'dart:convert';

import 'package:fushi_core/fushi_core.dart';

/// 推荐包里本地音频库的公开显示名。键是维护者本机导入时沿用的原始文件名
/// （Yomitan 本地音频服务器的 `android.db` 系列），值是分发给用户看的名字。
/// 磁盘文件名 `local_audio_*.db` 是冻结持久化名，这里只改 `displayName`。
const Map<String, String> kRecommendedPackAudioDisplayNames = <String, String>{
  'android.db': 'Japanese audio',
  'android_english.db': 'English audio',
};

/// 把 `local_audio_dbs` 偏好值（`s:` + JSON 列表）里的 `displayName` 换成公开名。
///
/// 已是公开名的条目原样保留（可重复执行）；出现没登记过的显示名直接抛错，
/// 免得新加的音频库带着原始文件名混进公开包。
String renameRecommendedPackAudioDbs(String prefValue) => _renameAudioEntries(
  prefValue,
  key: 'local_audio_dbs',
  prefix: 's:',
  field: 'displayName',
  applies: (Map<String, Object?> entry) => true,
);

/// 把 `audio_source_configs` 偏好值（`j:` + JSON 列表）里本地音频源的 `label`
/// 换成公开名，与 [renameRecommendedPackAudioDbs] 保持一致。
String renameRecommendedPackAudioSourceConfigs(String prefValue) =>
    _renameAudioEntries(
      prefValue,
      key: 'audio_source_configs',
      prefix: 'j:',
      field: 'label',
      applies: (Map<String, Object?> entry) => entry['kind'] == 'localAudio',
    );

/// 推荐包里需要改写音频库名字的偏好键 → 改写函数。
const Map<String, String Function(String)> _kAudioNamePrefRewriters =
    <String, String Function(String)>{
      'local_audio_dbs': renameRecommendedPackAudioDbs,
      'audio_source_configs': renameRecommendedPackAudioSourceConfigs,
    };

String _renameAudioEntries(
  String prefValue, {
  required String key,
  required String prefix,
  required String field,
  required bool Function(Map<String, Object?> entry) applies,
}) {
  if (!prefValue.startsWith(prefix)) {
    throw StateError('$key 偏好格式异常：缺少 $prefix 前缀');
  }
  final Object? decoded = jsonDecode(prefValue.substring(prefix.length));
  if (decoded is! List<Object?>) {
    throw StateError('$key 偏好格式异常：不是 JSON 列表');
  }
  final Set<String> publicNames = kRecommendedPackAudioDisplayNames.values
      .toSet();
  for (final Object? entry in decoded) {
    if (entry is! Map<String, Object?>) {
      throw StateError('$key 偏好格式异常：条目不是对象');
    }
    if (!applies(entry)) continue;
    final Object? name = entry[field];
    if (name == null) continue;
    if (name is! String) {
      throw StateError('$key 偏好格式异常：$field 不是字符串');
    }
    if (publicNames.contains(name)) continue;
    final String? renamed = kRecommendedPackAudioDisplayNames[name];
    if (renamed == null) {
      throw StateError(
        '推荐包音频库 "$name" 没有公开显示名，'
        '先在 kRecommendedPackAudioDisplayNames 里登记',
      );
    }
    entry[field] = renamed;
  }
  return '$prefix${jsonEncode(decoded)}';
}

/// 净化专供公开分发的数据库副本；绝不能传入用户正在使用的数据库。
///
/// 普通备份按类别保留用户数据，分发包则只允许词典元数据和音频注册项。
/// 从实际 schema 枚举表，保证以后新增的个人数据表也不会自动混入分发包。
Future<void> sanitizeRecommendedPackDatabase(FushiDatabase db) async {
  // 先触发 drift 初始化，再在事务外关闭外键。清空整组非分发数据时不依赖
  // 表的删除顺序；完成后恢复连接原本的外键设置。
  final int foreignKeys =
      (await db.customSelect('PRAGMA foreign_keys').getSingle())
              .data['foreign_keys']
          as int;
  await db.customStatement('PRAGMA foreign_keys = OFF');
  try {
    final List<String> tables =
        (await db
                .customSelect(
                  "SELECT name FROM sqlite_master WHERE type = 'table' "
                  "AND name NOT GLOB 'sqlite_*'",
                )
                .get())
            .map((row) => row.data['name'] as String)
            .toList();
    await db.transaction(() async {
      for (final String table in tables) {
        if (table == 'dictionary_metadata' || table == 'preferences') continue;
        final String quoted = '"${table.replaceAll('"', '""')}"';
        await db.customStatement('DELETE FROM $quoted');
      }
      await db.customStatement(
        'DELETE FROM preferences WHERE key NOT IN '
        "('audio_source_configs', 'local_audio_dbs')",
      );
      for (final MapEntry<String, String Function(String)> rewriter
          in _kAudioNamePrefRewriters.entries) {
        final List<String> values =
            (await db
                    .customSelect(
                      // 键来自上面的常量表，不是外部输入。
                      "SELECT value FROM preferences WHERE key = '${rewriter.key}'",
                    )
                    .get())
                .map((row) => row.read<String>('value'))
                .toList();
        for (final String value in values) {
          await db.customStatement(
            'UPDATE preferences SET value = ? WHERE key = ?',
            <Object>[rewriter.value(value), rewriter.key],
          );
        }
      }
      final bool hasSequence =
          (await db
                  .customSelect(
                    "SELECT name FROM sqlite_master WHERE name = 'sqlite_sequence'",
                  )
                  .get())
              .isNotEmpty;
      if (hasSequence) await db.customStatement('DELETE FROM sqlite_sequence');
      // 新增触发器也可能在清理时向已处理过的表写回数据；遇到这种 schema
      // 变化直接阻止导出，而不是生成表面成功、实际仍有个人内容的包。
      for (final String table in tables) {
        if (table == 'dictionary_metadata' || table == 'preferences') continue;
        final String quoted = '"${table.replaceAll('"', '""')}"';
        final int count =
            (await db
                    .customSelect('SELECT COUNT(*) AS n FROM $quoted')
                    .getSingle())
                .read<int>('n');
        if (count != 0) throw StateError('推荐包净化后表 $table 仍有数据');
      }
    });
    // DELETE 不会抹除空闲页里的原文；公开分发前必须重写数据库并清空 WAL。
    await db.customStatement('VACUUM');
    await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    final violations = await db.customSelect('PRAGMA foreign_key_check').get();
    if (violations.isNotEmpty) {
      throw StateError('推荐包数据库净化后存在外键错误');
    }
  } finally {
    await db.customStatement('PRAGMA foreign_keys = $foreignKeys');
  }
}

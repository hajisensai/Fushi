import 'package:fushi_core/fushi_core.dart';

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

import '../helpers/part_corpus.dart';

/// TODO-585: `sync_settings_schema.dart` 被拆成主库 + `sync_settings_schema/*.part.dart`
/// 一组 part 文件（account / backend_config / interconnect / actions / backup / data_root）。
/// 原来逐文件硬编码读单文件的静态守卫，现在读这份「合并语料」：主库 + 全部 part 文件
/// 按固定顺序拼接。
///
/// part 文件里的 widget/方法/常量都是从主文件原样搬来的（同一 library 的私有作用域），
/// 所以基于方法签名 / 类名 / 字符串切片的守卫逻辑零改写，只把数据源从「单文件」换成
/// 「合并语料」。
///
/// **part 清单从磁盘枚举，不是手写常量**（TODO-2707）：这份清单**实测已经漏过**——
/// `data_root.part.dart` 从落地起就没进手写清单，落在它里面的负向（`isNot`）断言一直
/// 真空通过。枚举 + 排序让新 part 自动进语料；契约由
/// `sync_settings_schema_source_corpus_test.dart` 锁住。
const String _syncSchemaShell = 'lib/src/sync/sync_settings_schema.dart';
const String kSyncSchemaPartDir = 'lib/src/sync/sync_settings_schema';

/// 主库 + 磁盘上全部 `*.part.dart`（按路径排序，保证跨机器/跨次运行顺序确定）。
List<String> syncSettingsSchemaFiles() => partCorpusFiles(
      shell: _syncSchemaShell,
      partDir: kSyncSchemaPartDir,
    );

/// 读「同步设置 schema 合并语料」：主库 + 全部 part 文件拼成单个字符串，供静态守卫
/// 切片/断言。换行统一成 '\n'，与各守卫历史行为一致。
String readSyncSettingsSchemaSource() =>
    readPartCorpus(syncSettingsSchemaFiles());

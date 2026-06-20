import 'dart:io';

/// TODO-585: `sync_settings_schema.dart` 被拆成主库 + `sync_settings_schema/*.part.dart`
/// 五个 part 文件（account / backend_config / interconnect / actions / backup）。原来逐文件
/// 硬编码读单文件的静态守卫，现在读这份「合并语料」：主库 + 全部 part 文件按固定顺序拼接。
///
/// part 文件里的 widget/方法/常量都是从主文件原样搬来的（同一 library 的私有作用域），
/// 所以基于方法签名 / 类名 / 字符串切片的守卫逻辑零改写，只把数据源从「单文件」换成
/// 「合并语料」。新增 part 文件时补进 [_syncSchemaFiles] 即可——尤其是负向（isNot）断言，
/// 必须覆盖全部 part，否则把被禁模式塞进某个 part 就能绕过守卫。
const List<String> _syncSchemaFiles = <String>[
  'lib/src/sync/sync_settings_schema.dart',
  'lib/src/sync/sync_settings_schema/account.part.dart',
  'lib/src/sync/sync_settings_schema/backend_config.part.dart',
  'lib/src/sync/sync_settings_schema/interconnect.part.dart',
  'lib/src/sync/sync_settings_schema/actions.part.dart',
  'lib/src/sync/sync_settings_schema/backup.part.dart',
];

/// 读「同步设置 schema 合并语料」：主库 + 五个 part 文件拼成单个字符串，供静态守卫
/// 切片/断言。换行统一成 '\n'，与各守卫历史行为一致。
String readSyncSettingsSchemaSource() {
  return _syncSchemaFiles
      .map((String path) =>
          File(path).readAsStringSync().replaceAll('\r\n', '\n'))
      .join('\n');
}

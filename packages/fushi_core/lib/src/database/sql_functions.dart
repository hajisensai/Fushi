import 'package:sqlite3/common.dart'
    show AllowedArgumentCount, CommonDatabase, SqliteArguments;

import '../utils/latin1_mojibake.dart';

/// `fushi_unwrap_mojibake(text)`：[unwrapLatin1Mojibake] 的 SQL 版；NULL 进 NULL 出。
const String kSqlUnwrapMojibake = 'fushi_unwrap_mojibake';

/// `fushi_has_mojibake(text)`：[hasLatin1Mojibake] 的 SQL 版，返回 0 / 1；NULL → 0。
const String kSqlHasMojibake = 'fushi_has_mojibake';

/// 给主库连接注册 Fushi 自定义 SQL 函数。在打开连接的 setup 里调用——生产走
/// `NativeDatabase.createInBackground`，setup 跑在 drift 的后台 isolate，函数体
/// 因此也在后台 isolate 执行：「检查数据库」修乱码行时，动辄几十 MB 的乱码书名
/// 从读到剥层到写回都不进 UI isolate（见 `database_check.dart`）。
///
/// 测试库用 `NativeDatabase(file, setup: registerFushiSqlFunctions)` 获得同样的函数。
void registerFushiSqlFunctions(final CommonDatabase db) {
  db.createFunction(
    functionName: kSqlUnwrapMojibake,
    argumentCount: const AllowedArgumentCount(1),
    deterministic: true,
    function: (final SqliteArguments args) {
      final Object? value = args[0];
      return value is String ? unwrapLatin1Mojibake(value) : value;
    },
  );
  db.createFunction(
    functionName: kSqlHasMojibake,
    argumentCount: const AllowedArgumentCount(1),
    deterministic: true,
    function: (final SqliteArguments args) {
      final Object? value = args[0];
      return value is String && hasLatin1Mojibake(value) ? 1 : 0;
    },
  );
}

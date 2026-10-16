/// 打开 Anki 集合 SQLite 的唯一入口：先补上 Anki 自己注册的排序规则。
///
/// Anki 2.1.28 起（schema 15+，`collection.anki21b` / 新 `collection.anki21`）
/// 的 `notetypes` / `fields` / `templates` / `decks` / `tags` 表在 name 列与
/// 唯一索引上用了 `COLLATE unicase`。这个排序规则是 rslib 打开库时用
/// `create_collation("unicase", …)` 现注册的，**标准 SQLite 没有**：不注册的话，
/// 对这些表的任何查询在 prepare 阶段就报
/// `no such collation sequence: unicase`（BUG-3428）。
library;

import 'package:sqlite3/sqlite3.dart';

/// Anki rslib 注册的大小写不敏感排序规则名。
const String ankiUnicaseCollation = 'unicase';

/// `unicase` 的比较函数：大小写折叠后比较，相等再按原串定序。
///
/// rslib 用 `unicase::UniCase::cmp`（Unicode case folding，含 `ß`→`ss` 这类
/// 一对多折叠）。Dart 没有 case-fold API，这里用 `toUpperCase().toLowerCase()`
/// 再手补 `ß`→`ss` 近似：能覆盖 ASCII、拉丁扩展、希腊/西里尔与 `ß`，其余
/// 一对多折叠（如 `ﬁ` 连字）与少数特殊字符（土耳其无点 i、希腊词尾 σ/ς）
/// 与 Anki 不完全一致；另外 Dart 按 UTF-16 码元
/// 定序、Rust 按码点定序，BMP 外字符的相对顺序可能不同。导入只是**读**这些表，
/// 不依赖排序结果，差异只影响 ORDER BY 顺序，不影响能否读出。
///
/// 折叠后相等时返回 0，与 Anki 一致（`Basic` 与 `basic` 视为同名）。
int ankiUnicaseCompare(String? a, String? b) {
  if (a == null || b == null) {
    if (a == b) return 0;
    return a == null ? -1 : 1;
  }
  return _fold(a).compareTo(_fold(b));
}

String _fold(String s) {
  final String lower = s.toUpperCase().toLowerCase();
  // Dart VM 的大小写映射是逐字符的，不做 ß→SS 这类一对多展开；手补最常见的一个。
  return lower.contains('ß') ? lower.replaceAll('ß', 'ss') : lower;
}

/// 给已经打开的 Anki 集合库注册 Anki 的自定义排序规则。必须在第一条查询前调。
void registerAnkiCollations(Database db) {
  db.createCollation(name: ankiUnicaseCollation, function: ankiUnicaseCompare);
}

/// 打开一份 Anki 集合 SQLite 并注册排序规则（默认只读）。
Database openAnkiCollectionDb(
  String path, {
  OpenMode mode = OpenMode.readOnly,
}) {
  final Database db = sqlite3.open(path, mode: mode);
  try {
    registerAnkiCollations(db);
  } on Object {
    db.close();
    rethrow;
  }
  return db;
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// TODO-2587 守卫：`tables.dart` 里 doc 声明的 schema 版本号，必须等于该表/列
/// **真正落地**的那条迁移的版本号。
///
/// 事故背景（PR#689 一次修了 4 处错标）：
///   - `ReadingHourlyLogs.format` doc 写 v65，实际是 v67 迁移；
///   - `VideoScrapeMeta.episodeNumber` 与 `collection_relations` doc 写 v65，
///     实际落 v66。
/// 根因就写在 `database.dart` 的 `if (from < 66)` 块自己的注释里：「原写作 v65，
/// 与 develop 已落地的 Mihon v65 撞号，顺延到 v66」。也就是说 **schema 号在开发
/// 中被顺延/改号时，只改了迁移侧**；表定义侧的 doc 是另一处独立维护的副本，此前
/// 没有任何东西保证两者一致。schema 注释是后人查「这列什么时候加的」的唯一去处，
/// 写错会把人送去看错的迁移阶梯。
///
/// ## 判据（窄而准，宁可漏报不可误报）
///
/// **声明侧**：只认 doc 里**明确写了版本号**的那些。doc 没写版本号的表/列**不**
/// 强制它写——那是另一件事，扩成「所有列都必须标版本」会立刻制造几百条误报，
/// 然后守卫就会被 allowlist 掏空。识别的两类形态见 [_declaredVersion]：
///   - **前缀形**：`schema vNN` / `onUpgrade vNN`（这两个前缀本身就把「NN 是迁移
///     号」说死了，后面跟什么都算声明）；
///   - **标点形**：`vNN` 后面（跳空格）紧跟子句标点，例如 `v67：…` /
///     `（schema v61，BUG-1211）` / `（v66 / TODO-2491）` / `（漫画 OCR，v52）` /
///     `v49（首页活动时间轴）：`。
///
/// 明确**不算**声明（这些是叙事，不是「本列在此落地」）：
///   - `vNN 前` / `vNN 起` / `vNN 迁移统一为` / `自 vNN 起` —— 版本号后跟的是汉字，
///     标点形不命中；
///   - `v54~v64 的自动刮削` —— 区间号两侧被 [_kRangeNeighbours] 显式排除；
///   - `'v12345'`（vndb 条目 id）—— 版本号只收 1~2 位数字，且必须落在
///     `[1, 迁移阶梯最大号]` 区间内。
///
/// 每个 doc 块只取**第一个**够格的版本号：约定是「引入版本写在最前」，后面的多半
/// 是历史叙述。取全部会把叙述也拉进来。
///
/// **落地侧**：不靠注释，只读 `database.dart` `onUpgrade` 阶梯里的**代码**
/// （先 `maskComments` 掩掉注释，否则「原写作 v65」这类注释会直接把索引喂脏）：
///   - `m.createTable(x)` → 表 `x` 落地于本块的 vN；
///   - `m.addColumn(x, x.y)` / `TableMigration(x, newColumns: [x.y])` → 列
///     `x.y` 落地于 vN；
///   - 裸 SQL `ALTER TABLE t ADD COLUMN c` / `CREATE TABLE t`（早期几处历史列名
///     只有裸 SQL 形态）→ 按 snake_case 反查回 Dart 标识符。
/// 列的落地版本 = `addColumn` 版本 ?? 建表版本（随表一起生的列没有单独的 addColumn）。
/// 刻意**不**收 `columnTransformer:` —— 那是**改名**（v57 removed_at→deleted_at），
/// 不是列的诞生地；收了会把一堆老列错标成 v57。
///
/// ## 为什么守在 `hibiki/test/` 而不是 `packages/fushi_core/test/`
///
/// 两个原因，都不是随手放的：
///   1. 共享词法掩码 `test/helpers/source_guard.dart` 属于 `hibiki` 包的 test 根，
///      `hibiki_core` 跨包 import 不到（也不能反向依赖 `hibiki`）。本仓明文禁止
///      手写注释剥离（`test/tools/source_guard_adoption_test.dart`），在 core 包
///      内复制一份掩码实现正是它要防的事。
///   2. `packages/*/test` 只由 CI 的 `Run package tests` 覆盖，本地全量门
///      （`hibiki/` 下的 `flutter_test_failures.dart`）根本跑不到它——这正是
///      BUG-1352 的成因，那条守卫（`package_schema_version_literal_guard_test.dart`）
///      的结论就是「schema 版本号的守卫留在 `hibiki/test/database/`」。本条同理。
///
/// 只校验 `tables.dart`（源），不校验 `database.g.dart`：生成文件里的 doc 是
/// codegen 从 `tables.dart` 逐字复制的**派生副本**，源头改对了它必然跟着对，
/// 单独再断言一遍只会在同一个缺陷上报两次，还把守卫绑死在 codegen 输出格式上。
///
/// flutter test 的 cwd 是 `hibiki` 包根。
void main() {
  const String tablesPath =
      '../packages/fushi_core/lib/src/database/tables.dart';
  const String databasePath =
      '../packages/fushi_core/lib/src/database/database.dart';

  late final _TableModel model;
  late final _MigrationIndex index;
  late final List<_DocDeclaration> declarations;

  setUpAll(() {
    model = _TableModel.parse(File(tablesPath).readAsStringSync());
    index = _MigrationIndex.parse(
      File(databasePath).readAsStringSync(),
      model,
    );
    declarations = model.declarations(maxVersion: index.maxVersion);
  });

  test('tables.dart 结构解析可信（扫不到表/列必须红，不能静默变空集）', () {
    expect(model.tables.length, greaterThan(50),
        reason: '只解析出 ${model.tables.length} 张表定义');
    expect(model.columnCount, greaterThan(200),
        reason: '只解析出 ${model.columnCount} 个列 getter');
    // 访问器命名（类名首字母小写）是落地侧索引的连接键，错了整条守卫就对不上。
    expect(_TableModel.accessorOf('ReadingHourlyLogs'), 'readingHourlyLogs');
  });

  test('迁移阶梯解析出的落地索引本身可信（扫描失效必须红）', () {
    // 阶梯从 v2 一路排到当前 schemaVersion。任何一项塌成 0 都说明解析器坏了，
    // 而不是「仓库真的没有迁移」——那种情况下后面的比对会全绿，是最典型的假绿。
    expect(index.maxVersion, greaterThanOrEqualTo(67),
        reason: '没解析到 v67 及以后的迁移块，onUpgrade 阶梯的形状变了');
    expect(index.tableCreatedAt.length, greaterThan(30),
        reason: 'createTable 只扫到 ${index.tableCreatedAt.length} 张表');
    expect(index.columnAddedAt.length, greaterThan(15),
        reason: 'addColumn/newColumns 只扫到 ${index.columnAddedAt.length} 列');

    // 三条已知锚点，覆盖三种落地形态；解析器一旦漂移，这里先红并指明是哪一种。
    expect(index.tableCreatedAt['collectionRelations'], 66,
        reason: 'createTable 形态');
    expect(index.columnAddedAt['videoScrapeMeta.episodeNumber'], 66,
        reason: 'addColumn 形态');
    expect(index.columnAddedAt['readingHourlyLogs.format'], 67,
        reason: 'TableMigration(newColumns:) 形态');

    // columnTransformer 是**改名**不是诞生：v57 把 removed_at 改叫 deleted_at，
    // 该列真正的诞生地是建表的 v40。收错会让一堆老列被错标成 v57。
    expect(
        index.columnAddedAt.containsKey('collectionMemberTombstones.deletedAt'),
        isFalse,
        reason: 'columnTransformer（改名）不得被当成列的落地点');
  });

  test('tables.dart 里确实有一批 doc 声明了版本号（判据塌成空集必须红）', () {
    expect(declarations.length, greaterThanOrEqualTo(15),
        reason: '只识别出 ${declarations.length} 条版本声明，声明识别器塌了；'
            '守卫会退化成永远绿的摆设');

    final Map<String, _DocDeclaration> bySymbol = <String, _DocDeclaration>{
      for (final _DocDeclaration d in declarations) d.symbol: d,
    };

    // 三种书写形态各留一个锚点：前缀形 / 句首标点形 / 括号内标点形。
    expect(bySymbol['mediaCollections.coverPath']?.version, 61,
        reason: '前缀形 `（schema v61，BUG-1211）`');
    expect(bySymbol['readingHourlyLogs.format']?.version, 67,
        reason: '句首标点形 `v67：…`');
    expect(bySymbol['videoScrapeMeta.episodeNumber']?.version, 66,
        reason: '括号内标点形 `（v66 / TODO-2491）`');

    // 反向锚点：叙述性提法不得被误收，否则守卫会去误伤本来正确的注释。
    // `VideoBookTagMappings.bookUid` 的 doc 只写「v57 起与被引列同名」——那是
    // 改名叙述，该列真正诞生于建表的 v22，误收就会当场误报。
    expect(bySymbol.containsKey('videoBookTagMappings.bookUid'), isFalse,
        reason: '`vNN 起…` 是叙述不是声明，不得被识别成版本声明');
    expect(bySymbol.containsKey('epubBooks.importedAt'), isFalse,
        reason: '`vNN 前是…` / `vNN 迁移统一为…` 是叙述不是声明');
  });

  test('doc 声明的 schema 版本号 == 该表/列真正落地的迁移版本', () {
    final List<String> offenders = <String>[];
    int checked = 0;

    for (final _DocDeclaration d in declarations) {
      final int? actual = index.landedVersionOf(d.symbol);
      if (actual == null) {
        offenders.add('$tablesPath:${d.line}  ${d.symbol} '
            'doc 声明 v${d.version}，但迁移阶梯里根本找不到它的落地点'
            '（createTable / addColumn / newColumns / 裸 SQL 都没有）\n'
            '      doc: ${d.evidence}');
        continue;
      }
      checked++;
      if (actual != d.version) {
        offenders.add('$tablesPath:${d.line}  ${d.symbol} '
            'doc 声明 v${d.version}，实际落地于 v$actual\n'
            '      doc: ${d.evidence}');
      }
    }

    expect(checked, greaterThanOrEqualTo(15),
        reason: '只真正比对了 $checked 条声明，判据塌了');
    expect(offenders, isEmpty,
        reason: 'doc 版本号与迁移阶梯不一致。schema 注释是后人查「这列什么时候加的」'
            '的唯一去处，写错会把人送去看错的迁移块。\n'
            '**改 doc 让它说实话，不要改迁移代码**——迁移号已经发出去了，改它会让'
            '线上库的 user_version 对不上。\n违规位置：\n${offenders.join('\n')}');
  });
}

// ---------------------------------------------------------------------------
// 声明侧：tables.dart 的结构 + doc 版本声明
// ---------------------------------------------------------------------------

/// 一处 doc 版本声明。
class _DocDeclaration {
  const _DocDeclaration({
    required this.symbol,
    required this.version,
    required this.line,
    required this.evidence,
  });

  /// `mediaCollections`（表）或 `mediaCollections.coverPath`（列）。
  final String symbol;
  final int version;

  /// 版本号所在的 1-based 行号。
  final int line;

  /// 出证用的原文片段。
  final String evidence;
}

/// 一段紧贴声明上方的注释块（原文 + 每行的 1-based 行号）。
class _DocBlock {
  const _DocBlock(this.lines, this.firstLine);

  /// 已剥掉 `///` / `//` 前缀的注释正文，自上而下。
  final List<String> lines;

  /// [lines] 第一行在文件里的 1-based 行号。
  final int firstLine;
}

/// `tables.dart` 的结构模型：表类 → 访问器 / 列 getter / 各自的 doc 块。
class _TableModel {
  _TableModel._(this.tables, this._tableDocs, this._columnDocs);

  /// 表类名，按出现顺序。
  final List<String> tables;
  final Map<String, _DocBlock> _tableDocs;

  /// 表类名 → (列 getter 名 → doc 块)。
  final Map<String, Map<String, _DocBlock>> _columnDocs;

  int get columnCount => _columnDocs.values
      .fold(0, (int a, Map<String, _DocBlock> m) => a + m.length);

  /// drift 生成的表访问器名：类名首字母小写。
  static String accessorOf(String className) =>
      className[0].toLowerCase() + className.substring(1);

  /// `ReaderPositions` → `reader_positions`；`ttuCharOffset` → `ttu_char_offset`。
  static String snakeOf(String camel) => camel
      .replaceAllMapped(
          RegExp(r'(?<=[a-z0-9])([A-Z])'), (Match m) => '_${m.group(1)}')
      .toLowerCase();

  /// snake 表名 → 表类名。裸 SQL 反查用。
  Map<String, String> get snakeTables => <String, String>{
        for (final String t in tables) snakeOf(t): t,
      };

  /// 表类名 → (snake 列名 → 列 getter 名)。裸 SQL 反查用。
  Map<String, Map<String, String>> get snakeColumns =>
      <String, Map<String, String>>{
        for (final MapEntry<String, Map<String, _DocBlock>> e
            in _columnDocs.entries)
          e.key: <String, String>{
            for (final String g in e.value.keys) snakeOf(g): g,
          },
      };

  static final RegExp _classLine =
      RegExp(r'^class\s+([A-Za-z_$][A-Za-z0-9_$]*)\s+extends\s+Table\b');
  // 只认 drift 的列类型，天然把 `List<Set<Column>> get uniqueKeys` /
  // `Set<Column> get primaryKey` / `String get tableName` 排除在外。
  static final RegExp _columnLine =
      RegExp(r'^\s*(?:Int|Text|Bool|Real|DateTime|Blob)Column\s+get\s+'
          r'([A-Za-z_$][A-Za-z0-9_$]*)\s*=>');
  static final RegExp _annotationLine = RegExp(r'^\s*@');
  // 剥注释前缀取正文。这不是「注释剥离」（判定谁是注释行走 maskComments），
  // 只是把已确认的注释行的 `///` / `//` 记号去掉。
  static final RegExp _commentMarker = RegExp(r'^\s*/+ ?');

  static _TableModel parse(String src) {
    final List<String> raw = src.split('\n');
    // 谁是「纯注释行」由共享词法掩码判定：掩码后只剩空白、原文却非空 ⇒ 整行是
    // 注释。手写「trimLeft 后以斜杠开头」剥不掉 `/* */` 与行尾注释，本仓明令禁用。
    final List<String> masked = maskComments(src).split('\n');
    final List<bool> isComment = <bool>[
      for (int i = 0; i < raw.length; i++)
        masked[i].trim().isEmpty && raw[i].trim().isNotEmpty,
    ];

    /// 从 [at]（0-based）上方收集紧贴的注释块；[skipAnnotations] 为真时先跳过
    /// `@DataClassName(...)` 这类注解行。
    _DocBlock docAbove(int at, {required bool skipAnnotations}) {
      int j = at - 1;
      if (skipAnnotations) {
        while (j >= 0 &&
            !isComment[j] &&
            _annotationLine.hasMatch(masked[j]) &&
            masked[j].trim().isNotEmpty) {
          j--;
        }
      }
      final List<String> collected = <String>[];
      while (j >= 0 && isComment[j]) {
        collected.add(raw[j].replaceFirst(_commentMarker, ''));
        j--;
      }
      return _DocBlock(collected.reversed.toList(), j + 2);
    }

    final List<String> tables = <String>[];
    final Map<String, _DocBlock> tableDocs = <String, _DocBlock>{};
    final Map<String, Map<String, _DocBlock>> columnDocs =
        <String, Map<String, _DocBlock>>{};

    String? current;
    for (int i = 0; i < masked.length; i++) {
      final RegExpMatch? cls = _classLine.firstMatch(masked[i]);
      if (cls != null) {
        current = cls.group(1)!;
        tables.add(current);
        tableDocs[current] = docAbove(i, skipAnnotations: true);
        columnDocs[current] = <String, _DocBlock>{};
        continue;
      }
      if (current == null) continue;
      final RegExpMatch? col = _columnLine.firstMatch(masked[i]);
      if (col == null) continue;
      columnDocs[current]![col.group(1)!] = docAbove(i, skipAnnotations: false);
    }

    return _TableModel._(tables, tableDocs, columnDocs);
  }

  /// 全部够格的 doc 版本声明。
  List<_DocDeclaration> declarations({required int maxVersion}) {
    final List<_DocDeclaration> out = <_DocDeclaration>[];

    void scan(String symbol, _DocBlock block) {
      for (int i = 0; i < block.lines.length; i++) {
        final int? v = _declaredVersion(block.lines[i], maxVersion: maxVersion);
        if (v == null) continue;
        out.add(_DocDeclaration(
          symbol: symbol,
          version: v,
          line: block.firstLine + i,
          evidence: block.lines[i].trim(),
        ));
        return; // 每块只取第一个够格的版本号。
      }
    }

    for (final String cls in tables) {
      final String accessor = accessorOf(cls);
      scan(accessor, _tableDocs[cls]!);
      for (final MapEntry<String, _DocBlock> e in _columnDocs[cls]!.entries) {
        scan('$accessor.${e.key}', e.value);
      }
    }
    return out;
  }
}

/// 版本号后面（跳空格）出现这些标点，才算「本处落地」的声明。
const String _kDeclarationFollowers = '：:，,、；;）)】]/（(';

/// 区间号的邻居：`v54~v64` 两端都不是声明。
const String _kRangeNeighbours = '~～-–—';

final RegExp _kVersionToken = RegExp(r'(?<![A-Za-z0-9_$])v(\d{1,2})(?![0-9])');

/// [text] 里第一个够格的 schema 版本声明；没有返回 null。
int? _declaredVersion(String text, {required int maxVersion}) {
  for (final RegExpMatch m in _kVersionToken.allMatches(text)) {
    final int version = int.parse(m.group(1)!);
    if (version < 1 || version > maxVersion) continue;

    // 前一个非空白字符：区间号的右端（`v54~v64` 里的 v64）一律不算。
    int p = m.start - 1;
    while (p >= 0 && text[p] == ' ') {
      p--;
    }
    if (p >= 0 && _kRangeNeighbours.contains(text[p])) continue;

    // 后一个非空白字符：区间号的左端（`v54~v64` 里的 v54）一律不算。
    int q = m.end;
    while (q < text.length && text[q] == ' ') {
      q++;
    }
    final String follower = q < text.length ? text[q] : '';
    if (_kRangeNeighbours.contains(follower)) continue;

    // 前缀形：`schema vNN` / `onUpgrade vNN` 把「NN 是迁移号」说死了。
    final String before = text.substring(0, m.start).trimRight();
    if (before.endsWith('schema') || before.endsWith('onUpgrade')) {
      return version;
    }
    // 标点形：版本号后面紧跟子句标点。跟汉字（`v57 前` / `v39 起` /
    // `v57 迁移统一为`）一律是叙述，不算声明。
    if (follower.isNotEmpty && _kDeclarationFollowers.contains(follower)) {
      return version;
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// 落地侧：onUpgrade 阶梯索引
// ---------------------------------------------------------------------------

class _MigrationIndex {
  _MigrationIndex._(this.tableCreatedAt, this.columnAddedAt, this.maxVersion);

  /// drift 表访问器（`mediaCollections`）→ createTable 所在的迁移版本。
  final Map<String, int> tableCreatedAt;

  /// `表访问器.列 getter`（`mediaCollections.coverPath`）→ addColumn 所在版本。
  final Map<String, int> columnAddedAt;

  final int maxVersion;

  /// `符号`（`mediaCollections` 或 `mediaCollections.coverPath`）真正落地的版本。
  ///
  /// 列优先取 addColumn；随表一起生的列没有自己的 addColumn，落地版本即建表版本。
  int? landedVersionOf(String symbol) {
    final int? added = columnAddedAt[symbol];
    if (added != null) return added;
    final int dot = symbol.indexOf('.');
    return tableCreatedAt[dot < 0 ? symbol : symbol.substring(0, dot)];
  }

  static final RegExp _blockHead = RegExp(r'if\s*\(\s*from\s*<\s*(\d+)\s*\)');
  static final RegExp _createTable =
      RegExp(r'\bm\s*\.\s*createTable\(\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*\)');
  static final RegExp _addColumn = RegExp(r'\bm\s*\.\s*addColumn\(\s*'
      r'[A-Za-z_$][A-Za-z0-9_$]*\s*,\s*'
      r'([A-Za-z_$][A-Za-z0-9_$]*)\s*\.\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*\)');
  static final RegExp _newColumns = RegExp(r'newColumns\s*:\s*\[([^\]]*)\]');
  static final RegExp _qualified =
      RegExp(r'([A-Za-z_$][A-Za-z0-9_$]*)\s*\.\s*([A-Za-z_$][A-Za-z0-9_$]*)');
  // 裸 SQL 会被 dart format 折成相邻字符串字面量拼接
  // （`'ALTER TABLE t ' 'ADD COLUMN c ...'`），所以中间容许引号/加号/换行。
  static final RegExp _rawAddColumn = RegExp(
      '''ALTER\\s+TABLE\\s+(\\w+)[\\s'"+]*ADD\\s+COLUMN\\s+(\\w+)''',
      caseSensitive: false);
  static final RegExp _rawCreateTable = RegExp(
      r'CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)',
      caseSensitive: false);

  static _MigrationIndex parse(String databaseSrc, _TableModel model) {
    // 阶梯窗口用结构原语定边界，别用「从 onUpgrade 往后数 N 个字符」——方法体一
    // 变长断言就凭空变假。
    final String ladder =
        methodBody(databaseSrc, 'onUpgrade: (m, from, to) async');
    // 只掩注释、保留字符串：裸 SQL 的表/列名活在字符串里，掩掉就读不到了。
    // 注释必须掩——`// v66（原写作 v65…）` 这类注释里全是版本号与表名，不掩就是
    // 「拿被守卫的那份叙述当判据」，守卫等于自证。
    final String code = maskComments(ladder);

    final Map<String, String> snakeTables = model.snakeTables;
    final Map<String, Map<String, String>> snakeColumns = model.snakeColumns;

    final Map<String, int> tableCreatedAt = <String, int>{};
    final Map<String, int> columnAddedAt = <String, int>{};

    final List<RegExpMatch> heads = _blockHead.allMatches(code).toList();
    int maxVersion = 0;
    for (int i = 0; i < heads.length; i++) {
      final int version = int.parse(heads[i].group(1)!);
      if (version > maxVersion) maxVersion = version;
      final int start = heads[i].end;
      final int end = i + 1 < heads.length ? heads[i + 1].start : code.length;
      final String block = code.substring(start, end);

      void noteTable(String accessor) {
        final int? old = tableCreatedAt[accessor];
        if (old == null || version < old) tableCreatedAt[accessor] = version;
      }

      void noteColumn(String accessor, String getter) {
        final String key = '$accessor.$getter';
        final int? old = columnAddedAt[key];
        if (old == null || version < old) columnAddedAt[key] = version;
      }

      for (final RegExpMatch m in _createTable.allMatches(block)) {
        noteTable(m.group(1)!);
      }
      for (final RegExpMatch m in _addColumn.allMatches(block)) {
        noteColumn(m.group(1)!, m.group(2)!);
      }
      for (final RegExpMatch m in _newColumns.allMatches(block)) {
        for (final RegExpMatch q in _qualified.allMatches(m.group(1)!)) {
          noteColumn(q.group(1)!, q.group(2)!);
        }
      }
      for (final RegExpMatch m in _rawCreateTable.allMatches(block)) {
        final String? cls = snakeTables[m.group(1)!.toLowerCase()];
        if (cls != null) noteTable(_TableModel.accessorOf(cls));
      }
      for (final RegExpMatch m in _rawAddColumn.allMatches(block)) {
        final String? cls = snakeTables[m.group(1)!.toLowerCase()];
        if (cls == null) continue;
        final String? getter = snakeColumns[cls]?[m.group(2)!.toLowerCase()];
        if (getter != null) {
          noteColumn(_TableModel.accessorOf(cls), getter);
        }
      }
    }

    return _MigrationIndex._(tableCreatedAt, columnAddedAt, maxVersion);
  }
}

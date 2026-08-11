// 守卫（P5 MediaKind 地基）：合集/书架媒体种类的**持久化形态**只允许经
// `MediaKind` 派生，不得手写。
//
// 两条纪律，都在 `packages/fushi_core/lib/src/database/media_kind.dart`
// 文件头写死，本守卫把它们从「注释里的君子协定」升级为可执行断言：
//
// 1. **复合键只走 `MediaKind.compositeKey`**。折叠归属 map 的键是
//    `'<dbValue>|<entryKey>'`，历史上散落着手写插值 `'video|' + bookUid`。
//    手写形态一旦与 `dbValue` 漂开（有人改枚举串却漏改字面量），折叠归属
//    表会静默全 miss——合集卡退化成散卡，没有任何报错。
// 2. **落库/拼键绝不用 `.name`**。`MediaKind.epub.name == 'epub'` 当前恰好
//    与 `dbValue` 相同，那是巧合不是契约：`.name` 跟着 Dart 标识符走，
//    改个成员名就换了持久化串（Never break userspace 级事故），而 `dbValue`
//    是显式钉死的。
//
// ## 例外：**迁移体里的字面量必须手写**（BUG-1489）
//
// 上面第 1 条只对**运行时代码**成立。Drift `MigrationStrategy.onUpgrade` 的
// 版本阶梯语义恰好相反：每一步都是「把升到那一版的那一刻、磁盘上真实存在的
// 数据形态，改写成下一版的形态」，它必须**逐字节钉死历史串**。
//
// v83 那步是活的反例：它靠 `WHERE cover_source LIKE 'epub|%'` 认出老行、靠
// `substr(cover_source, 6)`（6 = `len('epub|') + 1`）切出 bookKey。若改成引用
// `MediaKind.epub.dbValue`，将来谁改了枚举串，这段**历史**迁移的行为就跟着变：
// 老库里真实存在的 `'epub|<bookKey>'` 再也匹配不上，bookKey→uid 换键静默不做，
// 而同一步里不带前缀的 shelf_entries / media_collection_items 照常换成了 uid
// ——cover_source 从此永久悬空指向一个已不存在的键。那才是真事故。
//
// 所以这里不是「守卫太严」，是守卫缺一个**登记出口**。出口口径刻意开得很窄
// （四把锁全过才算豁免，见 [_frozenMigrationExemptionAt]），且总数钉死在
// [kFrozenMigrationLiteralCount]：新增一条就得来改这个常量，改不了就是红。
// 同族先例见 `book_format_discipline_guard_test.dart` 的
// `_kFrozenHistoryValueFiles`（那条是整文件粒度，本条精确到行）。
//
// 纯 dart:io 源码扫描，不依赖 Flutter 运行时。扫描范围限 `lib/`（生产代码）：
// 测试里用 `'video|v1'` 之类字面量当**期望值**是合法的，正是它们在证明
// `compositeKey` 的输出逐字节不变。
//
// ## 判据自校验
//
// 禁止型断言在健康仓库里永远零命中，扫盘那条路检验不到判据本身。所以
// [scanCompositeKeyLiterals] 抽成了**纯函数**（吃相对路径 + 源码文本），下面
// 用一组**合成语料**逐把锁点名：少一把锁就必须报违规。合成语料与磁盘枚举
// 零共享，不会两边一起失明。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import '../helpers/scan_scale.dart';

/// 从当前 cwd 向上找含 docs/BUGS.md 的仓库根。
Directory _repoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 6; i++) {
    if (File('${dir.path}/docs/BUGS.md').existsSync()) return dir;
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('找不到含 docs/BUGS.md 的仓库根（从 ${Directory.current.path} 向上）');
}

/// 扫描范围：本仓自有生产代码根（不含 third_party / vendored）。
const List<String> _libRoots = <String>[
  'fushi/lib',
  'packages/fushi_core/lib',
  'packages/fushi_dictionary/lib',
  'packages/fushi_anki/lib',
  'packages/fushi_audio/lib',
  'packages/fushi_platform/lib',
];

/// 手写复合键字面量：以**字面种类串紧跟 `|`** 开头的字符串。
/// DB 行值拼出来的 `'${row.mediaType}|${row.entryKey}'` 不以字面种类开头，
/// 不会误伤（那正是「原样透传未知种类」该走的形态）。
final RegExp _handwrittenCompositeKey =
    RegExp(r'''['"](epub|srt|video|game)\|''');

/// `MediaKind.<member>.name`（直接对枚举成员取 `.name`）。
final RegExp _enumMemberDotName = RegExp(r'\bMediaKind\.[a-zA-Z_]\w*\.name\b');

/// 一个文件里被声明为 `MediaKind` / `MediaKind?` 的标识符（局部变量、字段、
/// 形参、for-in 变量都是同一形态）。
final RegExp _mediaKindDecl = RegExp(r'\bMediaKind\??\s+([a-zA-Z_]\w*)\b');

// ---------------------------------------------------------------------------
// 冻结迁移字面量的登记机制
// ---------------------------------------------------------------------------

/// 登记标记词。必须写在**注释**里（代码里出现这串字符不算数），且必须紧贴被
/// 豁免的语句块上方。
const String kFrozenMigrationLiteralMarker = 'frozen-migration-literal';

/// 允许承载冻结迁移字面量的文件（相对**仓库根**）→ 这个文件凭什么有资格。
///
/// **只减不增**。加一个文件之前先问：那里真是「按版本号阶梯改写老数据」的迁移
/// 体吗？运行时代码永远没有资格——它读写的是当前值域，本来就该走 `compositeKey`。
const Map<String, String> kFrozenMigrationLiteralFiles = <String, String>{
  'packages/fushi_core/lib/src/database/database.dart':
      'Drift MigrationStrategy.onUpgrade 的版本阶梯：每步读/写的都是「升到那一版'
          '那一刻磁盘上真实存在」的串，必须逐字节钉死历史值，不能跟着枚举串漂。',
};

/// 全仓生效的冻结豁免**总条数**（v83 那条 UPDATE 里的 SET 侧 + WHERE 侧共 2 处）。
///
/// 这个显式常量就是闸门：新写一处手写字面量并加上标记，总数变 3，本守卫立刻红，
/// 逼人回到这里说明「为什么又多一条」。
const int kFrozenMigrationLiteralCount = 2;

/// 标记注释块的最大行数。
///
/// 标记必须落在**紧贴**被豁免语句的那段**连续注释块**里（中间隔一行代码或空行
/// 就断开）——这一条才是防「文件头写一次就全文件豁免」的锁；行数上限只是防
/// 有人把半个文件写成一整块注释再把标记埋进去。
const int kFrozenMigrationMarkerWindow = 12;

/// 标记所在注释块里，除标记词之外必须写够的理由字数。
///
/// 光写个 `// frozen-migration-literal` 不算登记——登记的价值全在那句理由上。
const int kFrozenMigrationReasonChars = 40;

/// 迁移阶梯步的形态：`if (from < 83 …)`。
final RegExp _migrationStepGate = RegExp(r'\bfrom\s*<\s*\d+');

/// `onUpgrade` 之外的迁移回调。从违规行往上找阶梯步时先撞见它，说明这行压根
/// 不在升级阶梯里（`onCreate` 建的是当前版本的库，没有「历史串」一说）。
final RegExp _nonUpgradeSection =
    RegExp(r'\b(onCreate|onCreateAll|beforeOpen|onDowngrade)\s*:');

/// 一次扫描的结果：未登记的违规 + 已登记且四把锁全过的豁免。
class CompositeKeyScan {
  const CompositeKeyScan({required this.violations, required this.exemptions});

  /// `<相对路径>:<行号>: <原文行>`。
  final List<String> violations;

  /// 同上格式；条数受 [kFrozenMigrationLiteralCount] 钉死。
  final List<String> exemptions;
}

/// 每行起始的字符偏移表（[lineStart].length == 行数）。
List<int> _lineStarts(String source) {
  final List<int> starts = <int>[0];
  for (int i = 0; i < source.length; i++) {
    if (source[i] == '\n') starts.add(i + 1);
  }
  return starts;
}

/// 偏移 → 0-based 行号（二分）。
int _lineOf(List<int> lineStart, int offset) {
  int lo = 0;
  int hi = lineStart.length - 1;
  while (lo < hi) {
    final int mid = (lo + hi + 1) >> 1;
    if (lineStart[mid] <= offset) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo;
}

/// 被豁免语句的**锚点行**：从命中位置沿「注释+字符串全掩」的串往回走，跳过被
/// 掩成空白的串内容与空白，落在第一个真代码字符上，取它所在的行。
///
/// 为什么不能只按行往上找「第一行有代码的行」：SQL 写在多行三引号串里，串的
/// **收尾行**往往同时带着 `''');` 这段真代码（合成语料就是这么写的），按行判断
/// 会把锚点钉死在违规行自己身上，标记再怎么写都挂不上。按字符回溯则总能落到
/// 承载它的那条 `await customStatement(` 上——同一条 SQL 里的多处字面量因此共用
/// **同一个**标记，而不是每行都得贴一遍。
int _anchorLine(String structural, List<int> lineStart, int matchOffset) {
  int i = matchOffset;
  while (i > 0 && structural[i - 1].trim().isEmpty) {
    i--;
  }
  return _lineOf(lineStart, i > 0 ? i - 1 : 0);
}

/// 锚点是否真落在 `onUpgrade` 的某个版本阶梯步里。
bool _insideMigrationStep(List<String> structural, int anchor) {
  for (int j = anchor; j >= 0; j--) {
    if (_nonUpgradeSection.hasMatch(structural[j])) return false;
    if (_migrationStepGate.hasMatch(structural[j])) return true;
  }
  return false;
}

/// 紧贴锚点上方的**连续注释块**的起始行；块为空时返回 [anchor]（空区间）。
///
/// 判「这行是纯注释」用的是掩码差：掩码后为空、原文非空 ⇒ 整行处在注释词法态。
/// 不用 `trimLeft().startsWith('//')`——那会放过块注释与行尾注释。
int _markerBlockTop(List<String> raw, List<String> code, int anchor) {
  bool isCommentOnly(int j) =>
      code[j].trim().isEmpty && raw[j].trim().isNotEmpty;

  int top = anchor;
  while (top > 0 &&
      anchor - top < kFrozenMigrationMarkerWindow &&
      isCommentOnly(top - 1)) {
    top--;
  }
  return top;
}

/// 注释块 `[top, anchor)` 里除标记词之外的实字数。
int _reasonChars(List<String> raw, int top, int anchor) {
  final StringBuffer text = StringBuffer();
  for (int j = top; j < anchor; j++) {
    text.write(raw[j]);
  }
  return text
      .toString()
      .replaceAll(kFrozenMigrationLiteralMarker, '')
      .replaceAll(RegExp(r'[/\s*]'), '')
      .length;
}

/// 四把锁：文件已登记 + 锚点在升级阶梯步内 + 紧贴的注释块里有注释态标记 +
/// 该块写够理由。任何一把没过就不是豁免，照旧算违规。
bool _frozenMigrationExemptionAt(
  String rel,
  List<String> raw,
  List<String> code,
  List<String> structural,
  int anchor,
) {
  if (!kFrozenMigrationLiteralFiles.containsKey(rel)) return false;
  if (!_insideMigrationStep(structural, anchor)) return false;
  final int top = _markerBlockTop(raw, code, anchor);
  bool marked = false;
  for (int j = top; j < anchor; j++) {
    if (raw[j].contains(kFrozenMigrationLiteralMarker) &&
        !code[j].contains(kFrozenMigrationLiteralMarker)) {
      marked = true;
      break;
    }
  }
  if (!marked) return false;
  return _reasonChars(raw, top, anchor) >= kFrozenMigrationReasonChars;
}

/// 判据本体：吃**相对仓库根的路径**与源码文本，不碰磁盘。
///
/// 注释换成**等长空白**（共享原语），文档里举例说明该格式的那些行不算违规。
/// 掩码不改行数，三个列表下标一一对应，`i + 1` 仍是原文真实行号；报错文案里
/// 要给人看的是**原文**行（掩码行的注释段已变空白）。
CompositeKeyScan scanCompositeKeyLiterals(String rel, String source) {
  final List<String> raw = source.split('\n');
  final String masked = maskCommentsAndScriptLines(source);
  // 结构侧额外把字符串内容也掩掉：三引号 SQL 的串内容由此全变空白，
  // 锚点回溯才找得到承载它的那条 `await customStatement(`。
  final String structural = maskCommentsAndStrings(source);
  final List<String> code = masked.split('\n');
  final List<String> structuralLines = structural.split('\n');
  final List<int> lineStart = _lineStarts(source);
  final List<String> violations = <String>[];
  final List<String> exemptions = <String>[];
  for (final RegExpMatch m in _handwrittenCompositeKey.allMatches(masked)) {
    final int line = _lineOf(lineStart, m.start);
    final String at = '$rel:${line + 1}: ${raw[line].trim()}';
    final int anchor = _anchorLine(structural, lineStart, m.start);
    if (_frozenMigrationExemptionAt(rel, raw, code, structuralLines, anchor)) {
      exemptions.add(at);
    } else {
      violations.add(at);
    }
  }
  return CompositeKeyScan(violations: violations, exemptions: exemptions);
}

/// 收集扫描根下的全部 .dart 文件（跳过生成物 `.g.dart` / `.freezed.dart`）。
List<File> _dartFiles(Directory root) {
  final List<File> files = <File>[];
  for (final String rel in _libRoots) {
    final Directory dir = Directory('${root.path}/$rel');
    if (!dir.existsSync()) continue;
    for (final FileSystemEntity e in dir.listSync(recursive: true)) {
      if (e is! File) continue;
      final String path = e.path.replaceAll('\\', '/');
      if (!path.endsWith('.dart')) continue;
      if (path.endsWith('.g.dart') || path.endsWith('.freezed.dart')) continue;
      files.add(e);
    }
  }
  return files;
}

String _relative(Directory root, File f) =>
    f.path.substring(root.path.length + 1).replaceAll('\\', '/');

// ---------------------------------------------------------------------------
// 合成语料（判据自校验专用，与磁盘枚举零共享）
// ---------------------------------------------------------------------------

/// 三引号，避免在本文件的字符串字面量里嵌同种引号。
const String _q3 = '"""';

const String _kRegisteredPath =
    'packages/fushi_core/lib/src/database/database.dart';
const String _kRuntimePath =
    'fushi/lib/src/pages/implementations/home_video_page.dart';

/// 合成一段「迁移体里写着 `'epub|'` 前缀」的源码。
///
/// [comment] 是插在 `customStatement(` 之上的注释行；[insideStep] 为 false 时
/// 去掉 `if (from < 83)` 这层版本门（模拟「标记贴在非迁移代码上」）。
String _migrationCorpus({
  required List<String> comment,
  bool insideStep = true,
}) {
  final List<String> lines = <String>[
    'MigrationStrategy get migration => MigrationStrategy(',
    '      onUpgrade: (m, from, to) async {',
    if (insideStep) '        if (from < 83) {',
    ...comment,
    '          await customStatement($_q3',
    "          UPDATE media_collections SET cover_source = 'epub|' ||",
    '            (SELECT eb.uid FROM epub_books eb)',
    "          WHERE cover_source LIKE 'epub|%'$_q3);",
    if (insideStep) '        }',
    '      },',
    '    );',
  ];
  return lines.join('\n');
}

/// 合格的标记注释块：标记词 + 一段真正的理由。
const List<String> _kGoodMarkerComment = <String>[
  '          // frozen-migration-literal：v83 阶梯认的是老库里真实存在的',
  "          // 'epub|' 前缀，引用 dbValue 会让这段历史迁移跟着枚举串漂，",
  '          // 老库的 bookKey→uid 换键会静默不做，cover_source 永久悬空。',
];

/// 只有标记词、没有理由。
const List<String> _kBareMarkerComment = <String>[
  '          // frozen-migration-literal',
];

void main() {
  final Directory root = _repoRoot();

  CompositeKeyScan scanAll() {
    final List<String> violations = <String>[];
    final List<String> exemptions = <String>[];
    for (final File f in _dartFiles(root)) {
      final CompositeKeyScan scan =
          scanCompositeKeyLiterals(_relative(root, f), f.readAsStringSync());
      violations.addAll(scan.violations);
      exemptions.addAll(scan.exemptions);
    }
    return CompositeKeyScan(violations: violations, exemptions: exemptions);
  }

  test('扫描规模哨兵：6 个生产 lib 根确实都被枚举到了', () {
    expectScanScale(_dartFiles(root).length,
        what: '6 个生产 lib 根下的 .dart（已排除生成物）', atLeast: 850, measured: 1034);
  });

  test('lib/ 不得手写 <kind>|... 复合键字面量（只走 MediaKind.compositeKey）', () {
    final List<String> violations = scanAll().violations;
    expect(
      violations,
      isEmpty,
      reason: '复合键必须由 MediaKind.compositeKey(entryKey) 派生。手写字面量会在'
          '有人改动 dbValue 时静默漂开（折叠归属 map 全 miss，合集卡退化成散卡'
          '且无任何报错）。\n'
          '唯一例外是 Drift onUpgrade 的版本阶梯（那里必须钉死历史串），走 '
          '$kFrozenMigrationLiteralMarker 标记登记，并同步改 '
          'kFrozenMigrationLiteralCount。违规：\n${violations.join('\n')}',
    );
  });

  test('冻结迁移豁免：总数必须等于登记的显式常量', () {
    final List<String> exemptions = scanAll().exemptions;
    expect(
      exemptions.length,
      kFrozenMigrationLiteralCount,
      reason: '冻结迁移字面量的条数变了。多出来的必须逐条确认「它真的是在改写老库里'
          '已存在的数据形态」，确认后把 kFrozenMigrationLiteralCount 改成新值；'
          '少了说明那处迁移被删/改写，把常量减回去。当前实际：\n'
          '${exemptions.join('\n')}',
    );
  });

  test('冻结迁移豁免：登记文件不得虚挂（必须真的还有生效豁免）', () {
    final Map<String, int> byFile = <String, int>{};
    for (final File f in _dartFiles(root)) {
      final String rel = _relative(root, f);
      if (!kFrozenMigrationLiteralFiles.containsKey(rel)) continue;
      byFile[rel] =
          scanCompositeKeyLiterals(rel, f.readAsStringSync()).exemptions.length;
    }
    for (final String path in kFrozenMigrationLiteralFiles.keys) {
      expect(File('${root.path}/$path').existsSync(), isTrue,
          reason: '$path 不存在（登记表里的路径拼错了或文件已挪走）');
      expect(
        byFile[path] ?? 0,
        greaterThan(0),
        reason: '$path 已经没有任何生效的冻结豁免了，请把它从 '
            'kFrozenMigrationLiteralFiles 删掉——清单只减不增，虚挂条目会让下一个'
            '人以为这里还有豁免在用。',
      );
    }
  });

  group('判据自校验（合成语料）', () {
    test('登记文件 + 迁移步 + 带理由的标记 ⇒ 判为豁免', () {
      final CompositeKeyScan scan = scanCompositeKeyLiterals(
        _kRegisteredPath,
        _migrationCorpus(comment: _kGoodMarkerComment),
      );
      expect(scan.violations, isEmpty);
      expect(scan.exemptions, hasLength(2));
    });

    test('同一段迁移，去掉标记 ⇒ 判为违规（守卫仍在抓这个形态）', () {
      final CompositeKeyScan scan = scanCompositeKeyLiterals(
        _kRegisteredPath,
        _migrationCorpus(comment: const <String>[]),
      );
      expect(scan.violations, hasLength(2));
      expect(scan.exemptions, isEmpty);
    });

    test('普通注释（无标记词）不能当豁免用', () {
      final CompositeKeyScan scan = scanCompositeKeyLiterals(
        _kRegisteredPath,
        _migrationCorpus(comment: const <String>[
          '          // 这里必须钉死历史串，别改成 dbValue，理由见 BUG-1489 正文。',
        ]),
      );
      expect(scan.violations, hasLength(2));
    });

    test('只有标记词、没写理由 ⇒ 不算登记', () {
      final CompositeKeyScan scan = scanCompositeKeyLiterals(
        _kRegisteredPath,
        _migrationCorpus(comment: _kBareMarkerComment),
      );
      expect(scan.violations, hasLength(2));
    });

    test('标记不在迁移阶梯步里 ⇒ 不算登记', () {
      final CompositeKeyScan scan = scanCompositeKeyLiterals(
        _kRegisteredPath,
        _migrationCorpus(comment: _kGoodMarkerComment, insideStep: false),
      );
      expect(scan.violations, hasLength(2));
    });

    test('未登记文件里贴同样的标记 ⇒ 照样违规（口子没开大）', () {
      final CompositeKeyScan scan = scanCompositeKeyLiterals(
        _kRuntimePath,
        _migrationCorpus(comment: _kGoodMarkerComment),
      );
      expect(scan.violations, hasLength(2));
    });

    test('运行时代码里的 \'video|\' + uid ⇒ 违规（即便贴了标记）', () {
      const String corpus = '''
// frozen-migration-literal：理由写得再长也没用，这里不是迁移体，只是普通运行时代码。
final String key = 'video|' + bookUid;
''';
      expect(scanCompositeKeyLiterals(_kRuntimePath, corpus).violations,
          hasLength(1));
      expect(scanCompositeKeyLiterals(_kRegisteredPath, corpus).violations,
          hasLength(1));
    });

    test('标记与语句之间隔了代码行 ⇒ 不算登记（不能文件头写一次全文件豁免）', () {
      final List<String> detached = <String>[
        ..._kGoodMarkerComment,
        "          await customStatement('PRAGMA foreign_keys = ON');",
      ];
      final CompositeKeyScan scan = scanCompositeKeyLiterals(
        _kRegisteredPath,
        _migrationCorpus(comment: detached),
      );
      expect(scan.violations, hasLength(2));
    });

    test('注释块超过行数上限 ⇒ 标记被挤出块外，不算登记', () {
      final List<String> bloated = <String>[
        ..._kGoodMarkerComment,
        for (int i = 0; i < kFrozenMigrationMarkerWindow; i++)
          '          // 无关说明行 $i，把标记挤出紧贴语句的那一段。',
      ];
      final CompositeKeyScan scan = scanCompositeKeyLiterals(
        _kRegisteredPath,
        _migrationCorpus(comment: bloated),
      );
      expect(scan.violations, hasLength(2));
    });

    test('DB 行值拼出来的键不算手写（原样透传未知种类）', () {
      const String corpus = r'''
final String key = '${row.mediaType}|${row.entryKey}';
''';
      expect(
          scanCompositeKeyLiterals(_kRuntimePath, corpus).violations, isEmpty);
    });
  });

  test('lib/ 不得对 MediaKind 取 .name 落库或拼键（只用 dbValue）', () {
    final List<String> violations = <String>[];
    for (final File f in _dartFiles(root)) {
      final String rel = _relative(root, f);
      // 这一条此前压根没剥注释：`media_kind.dart` 文件头一旦把「`MediaKind.epub.name`
      // 当前恰好等于 dbValue」这句反例写成代码形态，守卫就会对着自己的文档报违规。
      // 统一走等长掩码，把注释这个洞一次堵死。
      final String content = maskCommentsAndScriptLines(f.readAsStringSync());
      if (!content.contains('MediaKind')) continue;

      for (final RegExpMatch m in _enumMemberDotName.allMatches(content)) {
        violations.add('$rel: ${m.group(0)}');
      }

      // 声明为 MediaKind 的标识符，其后不得出现 `<ident>.name`。
      final Set<String> names = <String>{
        for (final RegExpMatch m in _mediaKindDecl.allMatches(content))
          m.group(1)!,
      };
      for (final String ident in names) {
        if (RegExp(r'\b' + ident + r'\.name\b').hasMatch(content)) {
          violations.add('$rel: $ident.name（$ident 声明为 MediaKind）');
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason: 'MediaKind 的持久化串只有 dbValue 一个真相源。`.name` 跟着 Dart '
          '标识符走——重命名枚举成员就换了落库值域，旧数据全部失配。'
          '违规：\n${violations.join('\n')}',
    );
  });
}

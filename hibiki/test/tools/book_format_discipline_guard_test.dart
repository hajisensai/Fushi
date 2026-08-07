/// 守卫：`EpubBooks.format` 的取值纪律。
///
/// ## 守什么
///
/// `format` 是阅读器路由的**唯一真相源**：`reader_hibiki_source.dart` 按它三态分流，
/// 未知值会**全部 fallback 到 EPUB 阅读器**——不是静默隐身，是用错阅读器打开、在解析
/// 路径出错。列上没有 CHECK 约束（为什么没加见 `BookFormat` 的文档：SQLite 加 CHECK
/// 要重建核心书表，风险大于收益），所以纪律必须由**类型 + 本守卫**兜住：
///
/// 1. **落库入口不得收裸 String**。`updateEpubBookFormat` 是唯一不受常量约束的写入
///    口，必须收 [BookFormat]，让「写进未知值」在编译期就不可表达。
/// 2. **不得再出现裸字符串字面量的 format 落库**（`format: Value('manga')` 这类），
///    一律走 `BookFormat.<x>.dbValue`。
/// 3. **不得再用裸字符串比较 format**（`book.format == 'manga'`），一律走枚举——
///    裸比较正是「PDF 被漏掉」那类 bug 的温床（见 tracking 两个调用点）。
/// 4. **落库串逐字节冻结**。存量持久化名不追改，改了就是让老库里的行读不回来。
///
/// ## 变异实测打在哪
///
/// 这几条的**真值在手写源码里**（不是 drift 生成文件——本守卫不涉及 CHECK 约束，
/// 生成的 `CREATE TABLE` 里没有本守卫断言的东西）。所以变异要改 `lib/`：把 DAO 参数
/// 换回 `String`、把某处改回裸字面量、把某处改回裸字符串比较、改掉 dbValue。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/source_guard.dart';
import '../helpers/scan_scale.dart';

/// DAO 所在文件（相对 `hibiki/`，故要跳出去一层）。
const String kDaoFile =
    '../packages/fushi_core/lib/src/database/database.dart';

/// 枚举定义文件。
const String kEnumFile =
    '../packages/fushi_core/lib/src/database/book_format.dart';

/// 本守卫自身：正文里写满了被禁的字面量当反例，不能扫自己。
const String kSelfPath = 'test/tools/book_format_discipline_guard_test.dart';

/// 迁移测试豁免：它们往库里塞的是**老版本磁盘上真实存在过的字面量**，是被测对象
/// 本身，不是新写的落库点。这里若改成 `BookFormat.pdf.dbValue`，将来谁把 dbValue
/// 改了，迁移测试会跟着一起变、于是永远绿——反而测不出「老库读不回来」。
/// 值的冻结由本文件的 `dbValue 逐字节冻结` 一条单独钉住。
///
/// **只有这一类豁免**；不是每出现一个新违规就往里塞一条。
const List<String> _kFrozenHistoryValueFiles = <String>[
  'test/database/migration_v51_pdf_format_test.dart',
  'test/database/migration_v53_manga_reading_mode_test.dart',
];

/// 读取并把注释换成**等长空白**后的代码文本（共享 `maskComments`）。
///
/// 结构断言一律走它：讲「此前是什么写法、为什么改」的注释是资产，但注释里出现
/// `format == 'manga'` 不该算违规，反过来注释也不能冒充真声明。
///
/// 旧写法是「丢掉整行 `//`」，两个洞：`/* required BookFormat format */` 这类块
/// 注释一概放行（把要求型断言骗绿），行尾注释也漏剪。掩码与原文逐字节等长，故
/// 下面 `indexOf` + `substring` 切签名的窗口语义不变。
String _codeOf(String path) => maskComments(File(path).readAsStringSync());

/// 扫 [roots] 下所有 .dart 的非注释行，返回命中 [pattern] 的 `文件:行号`。
///
/// 跳过 drift 生成文件：`database.g.dart` 里 `format: Value(format)` 这类是生成器
/// 按表定义产出的搬运代码，不是人写的落库点，禁它只会逼人去改生成文件。
///
/// 剥离用 `maskCommentsAndScriptLines`（等长空白）：它是旧行式剥离与 Dart 词法
/// 掩码的**并集**——既补上块注释 / 行尾注释两个洞，又保留旧行为里「三引号 JS/CSS
/// 语料中整行 `//` 也算注释」这一条，扫 `lib/src/reader/` 时不会凭空多出命中。
/// 掩码等长且不改行数，`i + 1` 仍是原文真实行号。
/// [_codeHits] 的枚举面，单独抽出来只为了让「扫描规模哨兵」能断言**同一条**扫描路径。
/// 哨兵另写一份枚举只能证明「磁盘上有文件」，证明不了守卫真的读到了它们。
List<File> _scannedDartFiles(List<String> roots) {
  final List<File> files = <File>[];
  for (final String root in roots) {
    final Directory dir = Directory(root);
    if (!dir.existsSync()) continue;
    for (final FileSystemEntity e in dir.listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final String rel = e.path.replaceAll(r'\', '/');
      if (rel.endsWith('.g.dart') || rel.endsWith(kSelfPath)) continue;
      if (_kFrozenHistoryValueFiles.any(rel.endsWith)) continue;
      files.add(e);
    }
  }
  return files;
}

List<String> _codeHits(List<String> roots, RegExp pattern) {
  final List<String> hits = <String>[];
  for (final File e in _scannedDartFiles(roots)) {
    final String rel = e.path.replaceAll(r'\', '/');
    final List<String> lines =
        maskCommentsAndScriptLines(e.readAsStringSync()).split('\n');
    for (int i = 0; i < lines.length; i++) {
      if (pattern.hasMatch(lines[i])) hits.add('$rel:${i + 1}');
    }
  }
  return hits;
}

void main() {
  const List<String> roots = <String>[
    'lib',
    'test',
    '../packages/fushi_core/lib',
  ];

  test('扫描规模哨兵：三个扫描根确实都被枚举到了', () {
    expectScanScale(_scannedDartFiles(roots).length,
        what: 'lib/ + test/ + hibiki_core/lib 下的 .dart（已排除生成物与冻结文件）',
        atLeast: 2500,
        measured: 3163);
  });

  test('落库入口收 BookFormat 而非裸 String（未知值编译期不可表达）', () {
    final String dao = _codeOf(kDaoFile);
    final int at = dao.indexOf('Future<void> updateEpubBookFormat(');
    expect(at, isNonNegative, reason: '找不到 updateEpubBookFormat');
    // 只看签名那一段。注意不能用「第一个 `{`」切——那是具名参数块的开括号，会把
    // 整个参数表切掉、断言恒假（本守卫自己先踩过一次）。切到函数体的 `}) {`。
    final int bodyAt = dao.indexOf('}) {', at);
    expect(bodyAt, isNonNegative, reason: '找不到 updateEpubBookFormat 的签名结尾');
    final String signature = dao.substring(at, bodyAt);
    expect(signature.contains('required BookFormat format'), isTrue,
        reason: 'format 落库入口必须收 BookFormat：收裸 String 就等于把「写进未知值」'
            '留到运行期，而未知值会让阅读器路由静默 fallback 到 EPUB。');
    expect(signature.contains('String format'), isFalse,
        reason: '不得退回裸 String 参数');
  });

  test('不得用裸字符串字面量落库 format', () {
    // 形如 `format: Value('manga')` / `format: const Value("pdf")`。
    final RegExp bare = RegExp(
      r'''format:\s*(const\s+)?Value\s*\(\s*['"]''',
    );
    expect(
      _codeHits(roots, bare),
      isEmpty,
      reason: '落库 format 请用 `BookFormat.<x>.dbValue`，别写裸字面量——'
          '裸字面量绕开枚举，拼错一个字母就是一本永远用错阅读器打开的书。',
    );
  });

  test('不得用裸字符串比较 format', () {
    // 形如 `book.format == 'manga'` / `source.format != "pdf"`。
    final RegExp bare = RegExp(
      r'''\.format\s*[!=]=\s*['"]''',
    );
    expect(
      _codeHits(roots, bare),
      isEmpty,
      reason: '请用 `BookFormat.parseOrEpub(x.format)` 再比枚举。裸比较正是'
          '「只挡了 manga、漏掉 pdf」那类 bug 的温床（tracking 两个调用点即为此坏过）。',
    );
  });

  test('dbValue 逐字节冻结（改了就是让老库的行读不回来）', () {
    expect(BookFormat.epub.dbValue, 'epub');
    expect(BookFormat.pdf.dbValue, 'pdf');
    expect(BookFormat.manga.dbValue, 'manga');
    expect(BookFormat.values.length, 3,
        reason: '新增格式要同步 reader_hibiki_source 的路由与 isPagedImageBook 判据');
  });

  test('按页翻的书判据覆盖 pdf 与 manga（章计数下游全靠它排除）', () {
    expect(BookFormat.pdf.isPagedImageBook, isTrue);
    expect(BookFormat.manga.isPagedImageBook, isTrue);
    expect(BookFormat.epub.isPagedImageBook, isFalse);
  });

  test('未知值按 epub 回退（与路由层实际行为一致）', () {
    expect(BookFormat.tryParse('cbz'), isNull);
    expect(BookFormat.tryParse(null), isNull);
    expect(BookFormat.parseOrEpub('cbz'), BookFormat.epub);
    expect(BookFormat.parseOrEpub(null), BookFormat.epub);
  });

  test('枚举文件写明了「为什么没加 CHECK 约束」（别让后人当遗漏又去重建书表）', () {
    final String src = File(kEnumFile).readAsStringSync();
    expect(src.contains('ALTER TABLE ADD CONSTRAINT'), isTrue);
    expect(src.contains('user_version=60'), isTrue,
        reason: '生产库实证是「值不值得补 CHECK」的判断依据，要留在代码里');
  });
}

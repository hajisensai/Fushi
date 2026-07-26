// 守卫（P5 MediaKind 地基）：合集/书架媒体种类的**持久化形态**只允许经
// `MediaKind` 派生，不得手写。
//
// 两条纪律，都在 `packages/hibiki_core/lib/src/database/media_kind.dart`
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
// 纯 dart:io 源码扫描，不依赖 Flutter 运行时。扫描范围限 `lib/`（生产代码）：
// 测试里用 `'video|v1'` 之类字面量当**期望值**是合法的，正是它们在证明
// `compositeKey` 的输出逐字节不变。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
  'hibiki/lib',
  'packages/hibiki_core/lib',
  'packages/hibiki_dictionary/lib',
  'packages/hibiki_anki/lib',
  'packages/hibiki_audio/lib',
  'packages/hibiki_platform/lib',
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

void main() {
  final Directory root = _repoRoot();

  test('lib/ 不得手写 <kind>|... 复合键字面量（只走 MediaKind.compositeKey）', () {
    final List<String> violations = <String>[];
    for (final File f in _dartFiles(root)) {
      final String rel = _relative(root, f);
      final List<String> lines = f.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        final String line = lines[i];
        // 跳过纯注释行（文档里举例说明该格式是合法的）。
        final String trimmed = line.trimLeft();
        if (trimmed.startsWith('//')) continue;
        if (_handwrittenCompositeKey.hasMatch(line)) {
          violations.add('$rel:${i + 1}: ${line.trim()}');
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason: '复合键必须由 MediaKind.compositeKey(entryKey) 派生。手写字面量会在'
          '有人改动 dbValue 时静默漂开（折叠归属 map 全 miss，合集卡退化成散卡'
          '且无任何报错）。违规：\n${violations.join('\n')}',
    );
  });

  test('lib/ 不得对 MediaKind 取 .name 落库或拼键（只用 dbValue）', () {
    final List<String> violations = <String>[];
    for (final File f in _dartFiles(root)) {
      final String rel = _relative(root, f);
      final String content = f.readAsStringSync();
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

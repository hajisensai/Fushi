// 生成 native/fushi_compute/src/parse/study_char_table.rs：学习统计「字数」口径
// （countStudyChars）的逐码点分类表。
//
// 用法（仓库根）：
//   dart native/fushi_compute/tool/gen_study_char_table.dart          重新生成
//   dart native/fushi_compute/tool/gen_study_char_table.dart --check  只比对，不一致退出 1
//
// **分类规则只在这里定义一次**（运行时只有 Rust 查表）。改规则 = 改本文件 + 重新生成 +
// 把 `kChapterCharCountCaliber`（packages/fushi_engine/lib/epub/epub_book.dart）+1。
//
// 注意：表按**运行本脚本的 Dart SDK 的 Unicode 数据**生成。换 SDK 后重新生成可能让少数
// 新收录码点改类（例如新增文字），那同样是口径变化，按上一条处理；不打算改口径就别重生成。
//
// 四类（与 Rust `StudyCharClass` 同值）：
//   0 = 断词且不计（标点 / 括号 / 空白 / 符号 / 未分配）
//   1 = 透明（组合记号 \p{M}、ZWNJ / ZWJ、词内撇号）：不计数也不断词
//   2 = 每码点计 1（\p{L}/\p{N} 且 Script_Extensions 属于不用空格分词的文字）
//   3 = 连续串计 1（其余 \p{L}/\p{N}）
// 判定顺序不可交换：先透明，再 \p{L}/\p{N}，最后看脚本（理由见 study_char_count.dart）。
import 'dart:io';
import 'dart:typed_data';

/// 不用空格分词的文字：这些脚本里一个码点就是一个学习单位。
const List<String> _noSpaceScripts = <String>[
  'Han',
  'Hiragana',
  'Katakana',
  'Hangul',
  'Bopomofo',
  'Yi',
  'Thai',
  'Lao',
  'Khmer',
  'Myanmar',
  'Tibetan',
];

final RegExp _transparent = RegExp(r"[\p{M}‌‍'’ʼ]", unicode: true);
final RegExp _letterOrNumber = RegExp(r'[\p{L}\p{N}]', unicode: true);
final RegExp _noSpaceScript = RegExp(
  '[${_noSpaceScripts.map((String s) => '\\p{Script_Extensions=$s}').join()}]',
  unicode: true,
);

int _classOf(int cp) {
  final String ch = String.fromCharCode(cp);
  if (_transparent.hasMatch(ch)) return 1;
  if (_letterOrNumber.hasMatch(ch)) return _noSpaceScript.hasMatch(ch) ? 2 : 3;
  return 0;
}

/// 32 位 FNV-1a，覆盖 0..=0x10FFFF 每个码点的类字节；Rust 测试用同一算法核对表。
int _fnv1a(Uint8List bytes) {
  int hash = 0x811c9dc5;
  for (final int b in bytes) {
    hash ^= b;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}

String _render() {
  final Uint8List classes = Uint8List(0x110000);
  for (int cp = 0; cp < classes.length; cp++) {
    classes[cp] = _classOf(cp);
  }
  final StringBuffer rows = StringBuffer();
  int count = 0;
  int start = 0;
  int previous = classes[0];
  void flush(int end) {
    if (previous == 0) return;
    rows.writeln(
      '    (0x${start.toRadixString(16).toUpperCase()}, '
      '0x${end.toRadixString(16).toUpperCase()}, $previous),',
    );
    count++;
  }

  for (int cp = 1; cp < classes.length; cp++) {
    if (classes[cp] != previous) {
      flush(cp - 1);
      start = cp;
      previous = classes[cp];
    }
  }
  flush(classes.length - 1);
  final String digest = _fnv1a(classes).toRadixString(16).padLeft(8, '0');
  return '''
// 由 native/fushi_compute/tool/gen_study_char_table.dart 生成，不要手改。
// 规则与重新生成的纪律见该脚本文件头。

/// 非 0 类的码点区间（闭区间、升序、互不重叠）；不在表里的码点属第 0 类。
pub(super) static STUDY_CHAR_RANGES: [(u32, u32, u8); $count] = [
$rows];

/// 0..=0x10FFFF 逐码点类字节的 32 位 FNV-1a（生成时的 Dart 正则口径）。
#[cfg(test)]
pub(super) const STUDY_CHAR_TABLE_FNV1A: u32 = 0x$digest;
''';
}

void main(List<String> args) {
  final bool check = args.contains('--check');
  final String scriptDir = File(Platform.script.toFilePath()).parent.path;
  final File target = File('$scriptDir/../src/parse/study_char_table.rs');
  final String rendered = _render();
  if (check) {
    final bool same =
        target.existsSync() && target.readAsStringSync() == rendered;
    stdout.writeln(same ? 'study_char_table.rs up to date' : 'OUT OF DATE');
    exitCode = same ? 0 : 1;
    return;
  }
  target.parent.createSync(recursive: true);
  target.writeAsStringSync(rendered);
  stdout.writeln('wrote ${target.path}');
}

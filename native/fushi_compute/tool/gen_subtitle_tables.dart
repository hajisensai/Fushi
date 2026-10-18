// 生成 native/fushi_compute/src/parse/subtitle/tables.rs：字幕解析（ffc_parse_subtitle_*）
// 需要与 Dart 运行时逐位一致的两张 Unicode 表。
//
// 用法（仓库根）：
//   dart native/fushi_compute/tool/gen_subtitle_tables.dart          重新生成
//   dart native/fushi_compute/tool/gen_subtitle_tables.dart --check  只比对，不一致退出 1
//
// 1. 字素簇（grapheme cluster）分类与状态机：**原样取自本仓锁定的 `package:characters`**
//    （pubspec.lock，当前 1.4.1）的 `low` / `high` / `move`。字幕 markup 的 span 下标与
//    `\N` 换行下标以 `String.characters` 为准（旧 Dart 实现），Rust 侧照搬同一张表与同一个
//    自动机，所以下标逐位一致。升级 package:characters 后重新生成并核对差异。
// 2. `String.toLowerCase()`：取自**运行本脚本的 Dart SDK**（逐码点映射，实测与上下文无关、
//    不改变 UTF-16 长度；生成时断言这两条）。ASS 段头 / 列名 / 样式名比较用它。
//
// 两张表的 32 位 FNV-1a 摘要写进生成文件，Rust 单测与 Dart 回归测试各自核对。
// ignore_for_file: implementation_imports
import 'dart:io';

import 'package:characters/src/grapheme_clusters/constants.dart';
import 'package:characters/src/grapheme_clusters/table.dart';

int _fnv(int hash, int byte) =>
    ((hash ^ (byte & 0xff)) * 0x01000193) & 0xffffffff;

/// 码点 [cp] 的前向字素类别（与 `Breaks.step` 的取类规则一致：BMP 走 `low`，补充平面走
/// `high`）。代理码元本身按 `low` 取（尾代理落单时 package:characters 也这样取）。
int _category(int cp) {
  if (cp <= 0xFFFF) return low(cp);
  final int v = cp - 0x10000;
  return high(v >> 10, v & 0x3FF);
}

String _render() {
  // 字素类别：区间表（跳过默认的 categoryOther）。
  final StringBuffer catRows = StringBuffer();
  int catCount = 0;
  int catHash = 0x811c9dc5;
  int start = 0;
  int previous = _category(0);
  void flushCat(int end) {
    if (previous == categoryOther) return;
    catRows.writeln(
      '    (0x${start.toRadixString(16).toUpperCase()}, '
      '0x${end.toRadixString(16).toUpperCase()}, $previous),',
    );
    catCount++;
  }

  for (int cp = 0; cp < 0x110000; cp++) {
    final int c = _category(cp);
    catHash = _fnv(catHash, c);
    if (cp == 0) continue;
    if (c != previous) {
      flushCat(cp - 1);
      start = cp;
      previous = c;
    }
  }
  flushCat(0x10FFFF);

  // 状态机：每行 automatonRowLength 项，覆盖全部前向状态。
  final StringBuffer moveRows = StringBuffer();
  int moveHash = 0x811c9dc5;
  final int rows = stateLimit ~/ automatonRowLength;
  for (int row = 0; row < rows; row++) {
    final List<int> entries = <int>[];
    for (int cat = 0; cat < automatonRowLength; cat++) {
      final int v = cat < categoryCount
          ? move(row * automatonRowLength, cat)
          : 0;
      entries.add(v);
      moveHash = _fnv(moveHash, v);
      moveHash = _fnv(moveHash, v >> 8);
    }
    moveRows.writeln('    ${entries.join(', ')},');
  }

  // toLowerCase：逐码点映射。
  final StringBuffer lowerRows = StringBuffer();
  int lowerCount = 0;
  int lowerHash = 0x811c9dc5;
  for (int cp = 0; cp < 0x110000; cp++) {
    if (cp >= 0xD800 && cp <= 0xDFFF) continue;
    final String s = String.fromCharCode(cp);
    final String l = s.toLowerCase();
    if (l.length != s.length || l.runes.length != 1) {
      throw StateError('toLowerCase(U+${cp.toRadixString(16)}) changes length');
    }
    final int lc = l.runes.single;
    if (lc != cp) {
      lowerRows.writeln(
        '    (0x${cp.toRadixString(16).toUpperCase()}, '
        '0x${lc.toRadixString(16).toUpperCase()}),',
      );
      lowerCount++;
      for (final int b in <int>[cp, cp >> 8, cp >> 16, lc, lc >> 8, lc >> 16]) {
        lowerHash = _fnv(lowerHash, b);
      }
    }
  }
  // 上下文无关性抽查：希腊语词尾 sigma 不特殊处理。
  if ('ΑΣ'.toLowerCase() != 'ασ') {
    throw StateError('toLowerCase is context sensitive on this SDK');
  }

  String hex(int v) => '0x${v.toRadixString(16).padLeft(8, '0')}';
  return '''
// 由 native/fushi_compute/tool/gen_subtitle_tables.dart 生成，不要手改。
// 来源与重新生成的纪律见该脚本文件头。

/// 字素簇前向类别中**非 categoryOther(2)** 的码点区间（闭区间、升序、互不重叠）。
pub(super) static GRAPHEME_CATEGORY_RANGES: [(u32, u32, u8); $catCount] = [
$catRows];

/// 前向自动机：`move(state, cat) = GRAPHEME_MOVE[(state & !3) + cat]`。
pub(super) static GRAPHEME_MOVE: [u16; ${rows * automatonRowLength}] = [
$moveRows];

/// Dart `String.toLowerCase()` 中改变取值的码点映射（升序）。
pub(super) static LOWERCASE_MAP: [(u32, u32); $lowerCount] = [
$lowerRows];

/// 0..=0x10FFFF 逐码点字素类别字节的 32 位 FNV-1a。
#[cfg(test)]
pub(super) const GRAPHEME_CATEGORY_FNV1A: u32 = ${hex(catHash)};
/// 状态机全部项（每项低、高字节）的 32 位 FNV-1a。
#[cfg(test)]
pub(super) const GRAPHEME_MOVE_FNV1A: u32 = ${hex(moveHash)};
/// 小写映射表（每对 cp / lower 各 3 字节）的 32 位 FNV-1a。
#[cfg(test)]
pub(super) const LOWERCASE_MAP_FNV1A: u32 = ${hex(lowerHash)};
''';
}

void main(List<String> args) {
  final bool check = args.contains('--check');
  final String scriptDir = File(Platform.script.toFilePath()).parent.path;
  final File target = File('$scriptDir/../src/parse/subtitle/tables.rs');
  final String rendered = _render();
  if (check) {
    final bool same =
        target.existsSync() && target.readAsStringSync() == rendered;
    stdout.writeln(same ? 'subtitle tables.rs up to date' : 'OUT OF DATE');
    exitCode = same ? 0 : 1;
    return;
  }
  target.parent.createSync(recursive: true);
  target.writeAsStringSync(rendered);
  stdout.writeln('wrote ${target.path}');
}

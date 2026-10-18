// 生成 native/fushi_compute/src/parse/anki_media/dart_lower_table.rs：Dart `String.toLowerCase`
// 的逐码点映射表（Anki 媒体引用扫描 `ffc_parse_anki_*` 的大小写折叠口径）。
//
// 用法（仓库根）：
//   dart native/fushi_compute/tool/gen_dart_lower_table.dart          重新生成
//   dart native/fushi_compute/tool/gen_dart_lower_table.dart --check  只比对，不一致退出 1
//
// 为什么不用 Rust 的 `to_lowercase`：Dart VM 的 toLowerCase 是**逐码点的简单映射**（不看上下文：
// 词尾 Σ 照样折成 σ；U+0130 折成单个 `i`，长度不变），Rust 的 `str::to_lowercase` 是完整映射
// （U+0130 → `i` + U+0307、词尾 σ → ς），Unicode 版本也未必相同。旧 Dart 实现
// （`MediaNameMatcher`，packages/fushi_anki/lib/src/anki_media_dedup.dart）在折叠后的码元下标上
// 切子串查表，口径必须逐码点一致，所以直接冻结运行本脚本的 Dart SDK 的映射。
//
// 表的不变式（脚本断言）：每个码点折成恰好一个码点，且 BMP 内外不交叉（UTF-16 长度不变）。
// 孤立代理码元不在表里，原样保留（与 Dart 一致）。
import 'dart:io';

const String _outPath =
    'native/fushi_compute/src/parse/anki_media/dart_lower_table.rs';

void main(List<String> args) {
  final bool check = args.contains('--check');
  final List<(int, int)> pairs = <(int, int)>[];
  int hash = 0x811c9dc5;
  for (int cp = 0; cp <= 0x10FFFF; cp++) {
    int lower = cp;
    if (cp < 0xD800 || cp > 0xDFFF) {
      final List<int> runes = String.fromCharCode(
        cp,
      ).toLowerCase().runes.toList();
      if (runes.length != 1) {
        stderr.writeln('U+${cp.toRadixString(16)} lowers to ${runes.length}');
        exit(2);
      }
      lower = runes.single;
      if ((cp > 0xFFFF) != (lower > 0xFFFF)) {
        stderr.writeln('U+${cp.toRadixString(16)} crosses the BMP boundary');
        exit(2);
      }
      if (lower != cp) pairs.add((cp, lower));
    }
    hash = _fnv(hash, lower);
  }

  final StringBuffer out = StringBuffer()
    ..writeln(
      '// 由 native/fushi_compute/tool/gen_dart_lower_table.dart 生成，不要手改。',
    )
    ..writeln('// 口径与重新生成的纪律见该脚本文件头。')
    ..writeln()
    ..writeln('/// Dart `toLowerCase` 会改变的码点 → 折叠结果（按码点升序）；不在表里的码点原样保留。')
    ..writeln(
      'pub(super) static DART_LOWER_PAIRS: [(u32, u32); ${pairs.length}] = [',
    );
  for (final (int cp, int lower) in pairs) {
    out.writeln('    (0x${_hex(cp)}, 0x${_hex(lower)}),');
  }
  out
    ..writeln('];')
    ..writeln()
    ..writeln('/// 0..=0x10FFFF 每个码点折叠结果的 u32 小端四字节做 32 位 FNV-1a（代理码元按自身）。')
    ..writeln('#[cfg(test)]')
    ..writeln(
      'pub(super) const DART_LOWER_TABLE_FNV1A: u32 = 0x${hash.toRadixString(16)};',
    );

  final File file = File(_outPath);
  final String text = out.toString();
  if (check) {
    if (!file.existsSync() || file.readAsStringSync() != text) {
      stderr.writeln('$_outPath is stale; rerun without --check');
      exit(1);
    }
    stdout.writeln('$_outPath is up to date (${pairs.length} pairs)');
    return;
  }
  file.writeAsStringSync(text);
  stdout.writeln(
    'wrote $_outPath (${pairs.length} pairs, fnv 0x${hash.toRadixString(16)})',
  );
}

String _hex(int value) => value.toRadixString(16).toUpperCase();

int _fnv(int hash, int value) {
  for (int shift = 0; shift < 32; shift += 8) {
    hash ^= (value >> shift) & 0xFF;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

// Anki 来源日志的 HLC（铁律 C）与 Rust 唯一实现对拍：同一份向量
// native/fushi_fsrs/src/anki_source_hlc_vectors.json 由 Rust `anki_import_rules.rs` 的单测与这里共用。
// 新代内核在日志投影（`store/gen4/cache.rs` `log_body`）与写回包（`logHlcs`）里按 Rust 那份派生；导入器
// （fushi_engine `srs_apkg_import.dart`）写日志时用的是这里的两个函数，两边必须逐字相同。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

const String _vectorsInRepo =
    'native/fushi_fsrs/src/anki_source_hlc_vectors.json';

/// 从 packages/fushi_srs（`dart test` 的工作目录）或仓库根找。
File _vectorsFile() {
  for (final String p in <String>['../../$_vectorsInRepo', _vectorsInRepo]) {
    final File f = File('${Directory.current.path}/$p');
    if (f.existsSync()) return f;
  }
  throw StateError('$_vectorsInRepo not found from ${Directory.current.path}');
}

void main() {
  test('srsImportedRevlogHlc / srsImportAnchorHlc match the Rust vectors', () {
    final Map<String, Object?> root =
        jsonDecode(_vectorsFile().readAsStringSync()) as Map<String, Object?>;
    final List<Map<String, Object?>> vectors =
        (root['vectors']! as List<Object?>).cast<Map<String, Object?>>();
    int checked = 0;
    for (final Map<String, Object?> v in vectors) {
      final String? want = v['hlc'] as String?;
      // hlc 为 null 的是「不是 Anki 来源」，Dart 没有对应的函数（排序键用操作自己的 HLC）。
      if (want == null) continue;
      expect(v['origin'], srsAnkiWriterId, reason: '$v');
      final Hlc got = v['kind'] == 'importAnchor'
          ? srsImportAnchorHlc(v['at']! as int)
          : srsImportedRevlogHlc(v['ankiId']! as int);
      expect(got.encode(), want, reason: '$v');
      checked++;
    }
    expect(checked, greaterThanOrEqualTo(6));
  });
}

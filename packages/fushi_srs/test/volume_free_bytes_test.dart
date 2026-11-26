// `ffsrs_volume_free_bytes`（自动备份第五期：写备份前查卷的可用空间）的真实 FFI 调用。要真实原生库
// （FUSHI_FSRS_LIB，缺省本仓 prebuilt/）；库加载失败直接判红，不 skip。
@TestOn('vm')
library;

import 'dart:io';

import 'package:fushi_srs/src/ffi/ffi_fsrs_engine.dart';
import 'package:fushi_srs/src/ffi/fushi_fsrs_library.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('真实目录 / 文件 / 还不存在的子路径都取得到正数；空串为 null', () {
    expect(FushiFsrs.instance, isNotNull, reason: 'fushi_fsrs 原生库缺失');
    final Directory tmp = Directory.systemTemp.createTempSync('fushi_volfree_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final File file = File(p.join(tmp.path, 'f.bin'))..writeAsStringSync('x');
    expect(FfiFsrsEngine.volumeFreeBytes(tmp.path), greaterThan(0));
    expect(FfiFsrsEngine.volumeFreeBytes(file.path), greaterThan(0));
    // 备份目录还没建：往上找到存在的上级目录再问。
    expect(
      FfiFsrsEngine.volumeFreeBytes(p.join(tmp.path, 'not', 'yet', 'made')),
      greaterThan(0),
    );
    expect(FfiFsrsEngine.volumeFreeBytes(''), isNull);
  });
}

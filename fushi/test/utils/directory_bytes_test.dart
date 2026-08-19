import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/directory_bytes.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi_dir_bytes_');
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  test('目录不存在返回 0', () async {
    final Directory missing = Directory(p.join(root.path, 'nope'));
    expect(await measureDirectoryBytes(missing), 0);
  });

  test('空目录返回 0', () async {
    expect(await measureDirectoryBytes(root), 0);
  });

  test('递归累加子目录里的每个文件', () async {
    File(p.join(root.path, 'a.bin')).writeAsBytesSync(List<int>.filled(100, 1));
    final Directory nested = Directory(p.join(root.path, 'sub', 'deep'))
      ..createSync(recursive: true);
    File(p.join(nested.path, 'b.bin'))
        .writeAsBytesSync(List<int>.filled(23, 1));

    expect(await measureDirectoryBytes(root), 123);
  });

  test('任何扩展名都算，包含未完成的 .part', () async {
    File(p.join(root.path, 'encoder_model.onnx'))
        .writeAsBytesSync(List<int>.filled(7, 1));
    File(p.join(root.path, 'encoder_model.onnx.part'))
        .writeAsBytesSync(List<int>.filled(11, 1));

    expect(await measureDirectoryBytes(root), 18);
  });
}

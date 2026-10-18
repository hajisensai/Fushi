// 原生 Rust crate 的许可登记：静态链进 App 的 crate 若许可要求随发行物附声明，必须在
// assets/licenses/ 下有文本、并登记进 AppModel.injectAssetLicenses（App 的开源许可页）。
//
// jpeg-encoder（native/fushi_compute）是 `(MIT OR Apache-2.0) AND IJG`：只发可执行文件时，
// IJG 要求文档写明「this software is based in part on the work of the Independent JPEG
// Group」。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'jpeg-encoder license (with the IJG acknowledgement) is on the licenses page',
    () {
      final String text = File(
        'assets/licenses/jpeg-encoder.txt',
      ).readAsStringSync();
      expect(
        text.toLowerCase(),
        contains(
          'this software is based in part on the work of the independent jpeg group',
        ),
      );
      expect(text, contains('Permission is hereby granted, free of charge'));

      final String appModel = File(
        'lib/src/models/app_model.dart',
      ).readAsStringSync();
      final int start = appModel.indexOf('Future<void> injectAssetLicenses()');
      expect(start, isNonNegative);
      final int end = appModel.indexOf('];', start);
      expect(appModel.substring(start, end), contains("'jpeg-encoder'"));
    },
  );

  test(
    'fushi_compute still links jpeg-encoder (drop the license entry with it)',
    () {
      final String cargo = File(
        '../native/fushi_compute/Cargo.toml',
      ).readAsStringSync();
      expect(cargo, contains('jpeg-encoder'));
    },
  );
}

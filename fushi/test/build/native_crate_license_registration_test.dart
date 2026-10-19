// 原生 Rust crate 的许可登记：静态链进 App 的 crate 若许可要求随发行物附声明，必须在
// assets/licenses/ 下有文本、并经开源许可页的资产许可注册（asset_licenses.dart）收录。
//
// jpeg-encoder（native/fushi_compute）是 `(MIT OR Apache-2.0) AND IJG`：只发可执行文件时，
// IJG 要求文档写明「this software is based in part on the work of the Independent JPEG
// Group」。注册不再是手写名字清单：`registerAssetLicenses` 按资产清单枚举顶层
// `assets/licenses/*.txt`，这里用同一套函数核对 jpeg-encoder 真被收进去。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/asset_licenses.dart';

void main() {
  test(
    'jpeg-encoder license (with the IJG acknowledgement) is on the licenses page',
    () async {
      const String key = '${kAssetLicenseDir}jpeg-encoder.txt';
      final String text = File(key).readAsStringSync();
      expect(
        text.toLowerCase(),
        contains(
          'this software is based in part on the work of the independent jpeg group',
        ),
      );
      expect(text, contains('Permission is hereby granted, free of charge'));

      // 资产清单要真的带上这个目录（pubspec 漏声明时清单里根本没有这个 key）。
      final String pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('- $kAssetLicenseDir\n'));

      final List<LicenseEntry> entries = await loadAssetLicenseEntries(
        assetKeys: <String>[key],
        loadString: (String k) async => File(k).readAsStringSync(),
      );
      final LicenseEntry entry = entries.singleWhere(
        (LicenseEntry e) => e.packages.contains('jpeg-encoder'),
      );
      expect(
        entry.paragraphs.map((LicenseParagraph p) => p.text).join('\n'),
        contains('Independent JPEG Group'),
      );

      final String appModel = File(
        'lib/src/models/app_model.dart',
      ).readAsStringSync();
      final int start = appModel.indexOf('Future<void> injectAssetLicenses()');
      expect(start, isNonNegative);
      expect(
        appModel.substring(start, appModel.indexOf('\n  }\n', start)),
        contains('registerAssetLicenses('),
      );
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

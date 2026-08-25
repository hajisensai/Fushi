import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 「下载」设置分类里那条直达下载页的导航项，副标题此前写的是
/// `download_settings`（「下载设置」）——与本分类的 summary 同一个词，用户看到的
/// 就是「下载设置里面还有一个下载设置」。它打开的是下载**页**（任务 / 资源 /
/// 订阅），副标题必须说这个。用源码断言（零 harness 依赖）。
void main() {
  test('downloads.open_page subtitle names the page, not "download settings"',
      () {
    final String src = File('lib/src/settings/settings_schema_downloads.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final int itemStart = src.indexOf("id: 'downloads.open_page'");
    expect(itemStart, isNonNegative);
    final int itemEnd = src.indexOf('onTap:', itemStart);
    expect(itemEnd, greaterThan(itemStart));
    final String item = src.substring(itemStart, itemEnd);
    expect(item, contains('subtitle: t.settings_downloads_open_page_hint'));
    expect(item, isNot(contains('t.download_settings')));
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：Windows WebView2 拦截域假失败已在 fork 引擎层根治
/// （packages/flutter_inappwebview_windows，NavigationCompleted 依据「主框架
/// 已注入 2xx」纠正 IsSuccess=FALSE）。阅读器页不得再用 Dart 层
/// `Platform.isWindows && host==kHost` 事后补偿特例掩盖该假失败。
void main() {
  test('reader onReceivedError 不再含 Windows 拦截域事后补偿特例', () {
    final File source = File(
      'lib/src/pages/implementations/reader_hibiki_page.dart',
    );
    expect(source.existsSync(), isTrue,
        reason: '阅读器页源文件应存在；测试需在 hibiki/ 目录下运行');
    final String code = source.readAsStringSync();

    // 特例的特征：onReceivedError 分支内同时判 Platform.isWindows 与拦截域 host。
    final bool hasWindowsHostSpecialCase =
        code.contains('Platform.isWindows') &&
            code.contains('request.url.host == ReaderHibikiSource.kHost');
    expect(hasWindowsHostSpecialCase, isFalse,
        reason: 'Windows 拦截域假失败应由 fork 引擎层根治，阅读器页不得重新引入特例');
  });
}

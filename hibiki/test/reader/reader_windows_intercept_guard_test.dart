import 'package:flutter_test/flutter_test.dart';
import '../pages/reader_hibiki_page_source_corpus.dart';

/// 守卫：Windows WebView2 拦截域假失败已在 fork 引擎层根治
/// （packages/flutter_inappwebview_windows，NavigationCompleted 依据「主框架
/// 已注入 2xx」纠正 IsSuccess=FALSE）。阅读器页不得再用 Dart 层
/// `Platform.isWindows && host==kHost` 事后补偿特例掩盖该假失败。
void main() {
  test('reader onReceivedError 不再含 Windows 拦截域事后补偿特例', () {
    // TODO-589 batch8: onReceivedError(在 _buildWebView 内)已搬到
    // reader_hibiki/webview.part.dart，改读「主壳 + 全部 part」合并语料，
    // 否则负向守卫会因被守的代码搬出读取范围而无意义地恒过。
    final String code = readReaderPageSource();
    expect(code.contains('InAppWebView('), isTrue,
        reason: '合并语料应含 reader WebView 构建；测试需在 hibiki/ 目录下运行');

    // 特例的特征：onReceivedError 分支内同时判 Platform.isWindows 与拦截域 host。
    final bool hasWindowsHostSpecialCase =
        code.contains('Platform.isWindows') &&
            code.contains('request.url.host == ReaderHibikiSource.kHost');
    expect(hasWindowsHostSpecialCase, isFalse,
        reason: 'Windows 拦截域假失败应由 fork 引擎层根治，阅读器页不得重新引入特例');
  });
}

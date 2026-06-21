import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

// 守卫：阅读器两种底栏（有声书播放条 / 设置条）必须绑定独立的
// reverseReaderBottomBar，而不是首页导航栏的 reverseNavigationBar。
void main() {
  test(
      'reader bottom bars bind reverseReaderBottomBar, not reverseNavigationBar',
      () {
    final String src = readReaderPageSource();

    // 有声书播放条 reversed: 与设置条 reversed 局部变量都应来自新键。
    expect(src.contains('appModel.reverseReaderBottomBar'), isTrue,
        reason: 'reader bottom bars must read the dedicated reader pref');
    // 确认旧键不再驱动阅读器底栏（reader 页里不应再出现 reverseNavigationBar）。
    expect(src.contains('reverseNavigationBar'), isFalse,
        reason:
            'reader bottom bars must be decoupled from the nav-bar reverse');
  });
}

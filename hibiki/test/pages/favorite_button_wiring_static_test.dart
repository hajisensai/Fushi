import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// 收藏按钮端到端接线守卫：查词弹窗（书内阅读 + 视频共用同一套 DictionaryPageMixin）
// 新增「☆/★」收藏按钮，落库/计入统计的来源由 dictionarySourceType 区分。任一环节
// 断链都会让收藏静默失效，故源码扫描锁定 JS→webview handler→layer 透传→mixin→
// 视频页来源覆写整条链路。
void main() {
  test('popup.js 渲染收藏按钮并经 favoriteEntry/favoriteCheck 回调 Dart', () {
    final String js = File('assets/popup/popup.js').readAsStringSync();
    expect(js, contains('function createFavoriteButton('), reason: '缺收藏按钮工厂');
    expect(js, contains("className: 'favorite-button'"));
    expect(js, contains("'favoriteEntry'"),
        reason: '点击应切换收藏（favoriteEntry bridge）');
    expect(js, contains("callHandler('favoriteCheck'"), reason: '初始状态应查询是否已收藏');
    expect(js, contains('buttonsContainer.appendChild(createFavoriteButton('),
        reason: '收藏按钮要挂进 header 按钮容器');
  });

  test('popup.css 定义 .favorite-button 样式', () {
    final String css = File('assets/popup/popup.css').readAsStringSync();
    expect(css, contains('.favorite-button'));
    expect(css, contains('.favorite-button.favorited'));
  });

  test('webview 注册 favoriteEntry / favoriteCheck handler', () {
    final String src =
        File('lib/src/pages/implementations/dictionary_popup_webview.dart')
            .readAsStringSync();
    expect(src, contains("handlerName: 'favoriteEntry'"));
    expect(src, contains("handlerName: 'favoriteCheck'"));
    expect(src, contains('onFavoriteEntry'));
    expect(src, contains('onFavoriteCheck'));
  });

  test('layer 透传 onFavoriteEntry / onFavoriteCheck 到 webview', () {
    final String src =
        File('lib/src/pages/implementations/dictionary_popup_layer.dart')
            .readAsStringSync();
    expect(src, contains('onFavoriteEntry: onFavoriteEntry'));
    expect(src, contains('onFavoriteCheck: onFavoriteCheck'));
  });

  test('mixin 默认书籍来源、提供收藏 handler 并把成功制卡计入统计', () {
    final String src =
        File('lib/src/pages/implementations/dictionary_page_mixin.dart')
            .readAsStringSync();
    expect(src, contains('String get dictionarySourceType => kStatSourceBook'),
        reason: '默认归书籍统计');
    expect(src, contains('Future<bool> onFavoriteEntry('));
    expect(src, contains('Future<bool> onFavoriteCheck('));
    expect(src, contains('_recordMined()'), reason: '制卡成功应计入统计');
    expect(src, contains('addMiningCount('));
    expect(src, contains('onFavoriteEntry: onFavoriteEntry'),
        reason: 'mixin 要把收藏 handler 接进 layer');
  });

  test('视频页把来源覆写为 video（收藏/制卡落视频统计）', () {
    final String src =
        File('lib/src/pages/implementations/video_hibiki_page.dart')
            .readAsStringSync();
    expect(
        src, contains('String get dictionarySourceType => kStatSourceVideo'));
  });
}

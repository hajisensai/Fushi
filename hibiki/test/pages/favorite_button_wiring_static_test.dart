import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// 收藏按钮已按用户要求从查词弹窗移除（音频按钮旁 / 加号旁的「☆/★」）。
// 这里改成「不得回归」的负向守卫：popup.js 不再渲染收藏按钮，popup.css 不再保留其样式。
// 后端 favoriteEntry/favoriteCheck 接线（webview handler→layer→mixin→视频来源覆写）
// 仍保留供其它入口（收藏夹页）使用，故下方接线守卫继续校验后端未断链。
void main() {
  test('popup.js 不再渲染收藏按钮', () {
    final String js = File('assets/popup/popup.js').readAsStringSync();
    expect(js, isNot(contains('createFavoriteButton')), reason: '收藏按钮工厂应已删除');
    expect(js, isNot(contains("className: 'favorite-button'")),
        reason: '不应再创建 favorite-button 元素');
  });

  test('popup.css 不再保留 .favorite-button 样式', () {
    final String css = File('assets/popup/popup.css').readAsStringSync();
    expect(css, isNot(contains('.favorite-button')), reason: '收藏按钮样式应已删除');
  });

  test('后端仍注册 favoriteEntry / favoriteCheck handler（供收藏夹页等其它入口）', () {
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
    expect(src, contains('recordMined()'), reason: '制卡成功应计入统计');
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

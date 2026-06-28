import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// 收藏按钮（音频按钮旁的「☆/★」）曾被 894fe165d 顺手删除，导致 FavoriteWords 表
// 没有写入入口、getAllFavoriteWords 恒空、收藏夹「全部收藏词」导出为空（TODO-913）。
// 已复活：与 BUG-123（reader_content_styles.dart 竖排选区 rt/rp 遮罩）无任何耦合，
// 复活 ☆ 不回归 BUG-123（ruby_highlight_guard_test.dart 仍绿）。
// 这里改成正向守卫：popup.js 必须渲染收藏按钮并调 favoriteEntry/favoriteCheck 桥，
// popup.css 必须保留其样式；下方接线守卫继续校验后端未断链。
void main() {
  test('popup.js 渲染收藏按钮并接 favoriteEntry / favoriteCheck 桥', () {
    final String js = File('assets/popup/popup.js').readAsStringSync();
    expect(js, contains('createFavoriteButton'), reason: '收藏按钮工厂必须存在');
    expect(js, contains("className: 'favorite-button'"),
        reason: '必须创建 favorite-button 元素');
    expect(js, contains("'favoriteEntry'"),
        reason: '点击应调 favoriteEntry 桥写入 FavoriteWords');
    expect(js, contains("callHandler('favoriteCheck'"),
        reason: '初始态应查 favoriteCheck 设 ☆/★');
    expect(js, contains('buttonsContainer.appendChild(createFavoriteButton('),
        reason: '收藏按钮要挂进词条头');
  });

  test('popup.css 保留 .favorite-button 样式', () {
    final String css = File('assets/popup/popup.css').readAsStringSync();
    expect(css, contains('.favorite-button'), reason: '收藏按钮样式必须存在');
    expect(css, contains('.favorite-button.favorited'),
        reason: '已收藏态（★ 金色）样式必须存在');
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

  test('BaseSourcePage（阅读器/有声书弹窗宿主）也接 favorite handler 并接进 layer', () {
    // TODO-948②：阅读器 EPUB 弹窗走 BaseSourcePage._buildPopupLayer（不经
    // DictionaryPageMixin），曾因这里漏传 onFavoriteEntry / onFavoriteCheck 导致
    // 收藏按钮点击无反应。本守卫防回归再漏接线。
    final String src =
        File('lib/src/pages/base_source_page.dart').readAsStringSync();
    expect(src, contains('String get dictionarySourceType => kStatSourceBook'),
        reason: '阅读器/有声书默认归书籍统计');
    expect(src, contains('Future<bool> onFavoriteFromPopup('),
        reason: '基类必须提供收藏切换 handler');
    expect(src, contains('Future<bool> onFavoriteCheckFromPopup('),
        reason: '基类必须提供收藏状态查询 handler');
    expect(src, contains('addFavoriteWord('),
        reason: '收藏必须真写穿 FavoriteWords 表，而非 UI 假动作');
    expect(src, contains('onFavoriteEntry: onFavoriteFromPopup'),
        reason: '_buildPopupLayer 必须把收藏写入 handler 接进 layer');
    expect(src, contains('onFavoriteCheck: onFavoriteCheckFromPopup'),
        reason: '_buildPopupLayer 必须把收藏查询 handler 接进 layer');
  });

  test('视频页把来源覆写为 video（收藏/制卡落视频统计）', () {
    final String src =
        File('lib/src/pages/implementations/video_hibiki_page.dart')
            .readAsStringSync();
    expect(
        src, contains('String get dictionarySourceType => kStatSourceVideo'));
  });
}

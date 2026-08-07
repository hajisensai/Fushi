// 浏览器扩展查词弹窗两处 app-parity 回归守卫（用户报「浏览器上多列不生效 + 滑动关闭没反应」）：
//
//  1) 多列词典：server 的 browserExtensionThemeColors() 早已随 theme 下发 --dict-columns，但
//     content.js 把每个 theme key setProperty 到 shadow 内的 #entries-container，而 popup.js 的
//     masonry dictColumns() / updateEffectiveDictColumns() 从 document.documentElement 读
//     --dict-columns（in-app 时那就是弹窗自身文档）。扩展里 documentElement 是宿主页 html，读不到
//     → 恒 1 列（连 CSS grid 也因 effective 算成 1 而单列）。修法：content.js 额外把 --dict-columns
//     落到 document.documentElement，让 masonry 读数 / effective 收敛 / grid 继承三条路径命中。
//
//  2) 滑动关闭：app 的 enableSwipeToClose 偏好此前未随 theme 下发，扩展浮动弹窗也没有任何拖手势
//     （只 mousedown 点外部关窗）。修法：browserExtensionThemeColors() 下发 --fushi-swipe-close
//     ('1'/'0')，content.js 据此在弹窗宿主上启用水平拖关手势（设置项文案即「水平滑动关闭查词弹窗」）。
//
// 纯源码不变量（CI 只跑 .dart）。两 content.js 镜像的字节一致由
// browser_extension_dict_media_mirror_guard_test.dart 另行守卫；真实手感待桌面/真机复测。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('browser extension dict-columns + swipe-close app parity', () {
    test('browserExtensionThemeColors 下发 --dict-columns 与 --fushi-swipe-close',
        () {
      final String src =
          File('lib/src/models/app_model.dart').readAsStringSync();
      expect(src, contains('browserExtensionThemeColors()'),
          reason: 'app_model.dart 应存在 browserExtensionThemeColors()');
      // 多列：列数（popupDictionaryColumns）随 theme 下发。
      expect(src, contains("'--dict-columns': '\$popupDictionaryColumns'"),
          reason: 'theme 必须下发 --dict-columns（扩展多列布局的列数来源）');
      // 滑动关闭：把 enableSwipeToClose 偏好以 '1'/'0' 随 theme 下发给 content.js。
      expect(src, contains("'--fushi-swipe-close'"),
          reason: 'theme 必须下发 --fushi-swipe-close 供 content.js 决定是否启用拖关手势');
      expect(
          RegExp(r'ReaderFushiSource\.instance\.enableSwipeToClose\s*\?\s*'
                  "'1'\\s*:\\s*'0'")
              .hasMatch(src),
          isTrue,
          reason: '--fushi-swipe-close 值必须取自 enableSwipeToClose 偏好（1/0）');
    });

    test(
        'content.js 把 --dict-columns 落到 document.documentElement（masonry 才读得到）',
        () {
      final String js =
          File('assets/browser_extension/content.js').readAsStringSync();
      // 从 theme 取列数并写到宿主页 documentElement：这是让 popup.js masonry/effective 读到的关键。
      expect(js, contains("theme['--dict-columns']"),
          reason: 'content.js 必须从下发的 theme 读 --dict-columns');
      expect(
          RegExp(r'document\.documentElement\.style\.setProperty\(\s*'
                  r"'--dict-columns'")
              .hasMatch(js),
          isTrue,
          reason: 'content.js 必须把 --dict-columns 写到 document.documentElement，'
              '否则 popup.js masonry 从 documentElement 读不到 → 恒单列（用户报的多列不生效）');
    });

    test('content.js 读 --fushi-swipe-close 并装水平拖关手势', () {
      final String js =
          File('assets/browser_extension/content.js').readAsStringSync();
      // 偏好门控标志：只有开启才真正关窗。
      expect(js, contains("theme['--fushi-swipe-close']"),
          reason: 'content.js 必须读 app 下发的 --fushi-swipe-close 偏好');
      expect(js, contains('fushiSwipeCloseEnabled'),
          reason: '必须有门控标志 fushiSwipeCloseEnabled（关时纯 no-op）');
      // 手势安装函数存在、挂在弹窗宿主上、并调 fushiRemoveContainer 关窗。
      expect(js, contains('function fushiInstallSwipeClose('),
          reason: '必须有水平拖关手势安装函数 fushiInstallSwipeClose');
      expect(js, contains('fushiInstallSwipeClose(fushiHost)'),
          reason: '手势必须挂到弹窗宿主 fushiHost 上');
      // 水平主导判据 + 过阈才关（避免竖向滚动/选区误触）。
      expect(js, contains('FUSHI_SWIPE_CLOSE_THRESHOLD'),
          reason: '必须有水平拖关阈值常量');
      expect(js, contains('fushiRemoveContainer()'),
          reason: '过阈后必须调 fushiRemoveContainer() 真正关窗');
      // pointer（桌面鼠标）+ touch（移动浏览器）双家族，且 pointer 路径排除 touch 避免双触发。
      expect(js, contains("addEventListener('pointerdown'"),
          reason: '桌面鼠标走 pointer 路径');
      expect(js, contains("addEventListener('touchstart'"),
          reason: '移动浏览器走 touch 路径');
    });
  });
}

// BUG-5414 备注：制卡重放宿主页（WebVideoFushiPage）的全屏态原来是一个布尔、每拍站点快照
// 直接覆盖——Fushi 全屏键进窗口全屏后下一拍 `fs=false` 就改回「没全屏」，站点自己进全屏又只藏
// app bar、不收桌面顶栏。这里钉住拆开后的两位各自只随自己的来源变。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/web_video_host_fullscreen.dart';

import '../../helpers/source_guard.dart';

void main() {
  group('WebVideoHostFullscreen', () {
    test('Fushi 全屏键进窗口全屏后，站点快照 fs=false 不把它改回', () {
      final WebVideoHostFullscreen fs = WebVideoHostFullscreen();
      expect(fs.toggleWindow(), isTrue);
      // 页面并不在 DOM 全屏：每拍快照都报 false。
      expect(fs.reportSite(false), isFalse);
      expect(fs.reportSite(false), isFalse);
      expect(fs.window, isTrue);
      expect(fs.chromeHidden, isTrue);
      expect(fs.toggleWindow(), isFalse);
      expect(fs.chromeHidden, isFalse);
    });

    test('站点自己进 / 退 DOM 全屏：只动站点那一位，页面 chrome 随之收起 / 回来', () {
      final WebVideoHostFullscreen fs = WebVideoHostFullscreen();
      expect(fs.reportSite(true), isTrue);
      expect(fs.site, isTrue);
      expect(fs.window, isFalse, reason: '站点全屏不是 runner 的窗口全屏');
      expect(fs.chromeHidden, isTrue);
      expect(fs.reportSite(true), isFalse, reason: '同值不重建');
      expect(fs.reportSite(false), isTrue);
      expect(fs.chromeHidden, isFalse);
    });

    test('两种全屏叠着时退掉站点全屏，窗口全屏仍在', () {
      final WebVideoHostFullscreen fs = WebVideoHostFullscreen()
        ..toggleWindow()
        ..reportSite(true);
      fs.reportSite(false);
      expect(fs.window, isTrue);
      expect(fs.chromeHidden, isTrue);
    });
  });

  test('宿主页接线：快照只报站点全屏，桌面顶栏随站点全屏收起，Esc 分来源退', () {
    final String src = maskComments(
      File(
        'lib/src/pages/implementations/web_video_fushi_page.dart',
      ).readAsStringSync(),
    );
    expect(src, contains('_fullscreen.reportSite(state.fullscreen)'));
    expect(src, isNot(contains('_fullscreen = state.fullscreen')));
    expect(
      src,
      contains(
        'FushiTitleBarContentFullscreenScope(\n'
        '        enabled: _fullscreen.site,',
      ),
    );
    expect(src, contains('final bool enter = _fullscreen.toggleWindow();'));
    expect(src, contains('appBar: _fullscreen.chromeHidden'));
    expect(src, contains('document.exitFullscreen'));
  });
}

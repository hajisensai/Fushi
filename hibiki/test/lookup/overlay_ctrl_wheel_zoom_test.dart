// BUG-1139 守卫 —— app 外查词浮窗（瞬态覆盖窗 + 常驻剪贴板面板）的 Ctrl+滚轮缩放。
//
// 原症状：Ctrl+滚轮落到 WebView2 自带的页面缩放上，而覆盖窗整条几何链（host 报的
// bbox/shellRects → Dart 的窗口物理尺寸 → C++ 的 window region）全按 zoom=1 的 CSS px
// 算，ZoomFactor 不在任何一环里 —— 内容按 z 放大绘制，窗口/region 仍是 z=1 的尺寸，
// 卡片被窗口边缘竖着切掉、region 外露出底下的应用（用户报「左边是空的」）。
//
// 三段守卫，对应三段根因修复：
//   (1) 纯函数：净档数 → 新字号的折算与夹紧（唯一真值仍是 steppedPopupZoomFontSize）。
//   (2) 分发：popupZoomFontStep 被吞掉且只在字号真变时才触发重渲。
//   (3) 源码：C++ 关掉原生缩放并复位持久 ZoomFactor；app 外注入装了 Ctrl+滚轮监听且
//       **不**就地改 zoom；in-app 注入不装（避免与 _zoomWheelJs 双装）；两个表面都接线。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/lookup/overlay_bridge_handlers.dart';

/// 与 DictionaryPopupWebViewState 的 _popupZoomFontMin/_popupZoomFontMax 同源。
const double _min = 8.0;
const double _max = 72.0;

File _repoFile(String relative) {
  // 测试 cwd = hibiki/（flutter test 的包根）。仓库根是它的上一级。
  final File inPackage = File(relative);
  if (inPackage.existsSync()) return inPackage;
  return File('../$relative');
}

void main() {
  group('BUG-1139 (1) 净档数折算成词典字号', () {
    test('每档 ±1，方向与滚轮一致', () {
      expect(zoomFontSizeAfterSteps(16, 1), 17);
      expect(zoomFontSizeAfterSteps(16, -1), 15);
      expect(zoomFontSizeAfterSteps(16, 4), 20);
      expect(zoomFontSizeAfterSteps(16, -4), 12);
    });

    test('0 档原样返回（rAF 合帧后净档数可能抵消为 0）', () {
      expect(zoomFontSizeAfterSteps(16, 0), 16);
    });

    test('双侧夹死在 8..72，且顶到边界后继续同向滚返回原值', () {
      expect(zoomFontSizeAfterSteps(70, 10), _max);
      expect(zoomFontSizeAfterSteps(10, -10), _min);
      // 已在边界：返回原值 —— 调用方据此跳过整栈重渲。
      expect(zoomFontSizeAfterSteps(_max, 3), _max);
      expect(zoomFontSizeAfterSteps(_min, -3), _min);
    });
  });

  group('BUG-1139 (2) popupZoomFontStep 分发', () {
    test('非本 handler 不拦截（调用方继续自己的分发）', () {
      bool rerendered = false;
      final bool handled = maybeHandleOverlayZoomFontStep(
        model: null,
        handler: 'tapOutside',
        message: const <String, Object?>{
          'args': <Object?>[1]
        },
        onFontSizeChanged: () => rerendered = true,
      );
      expect(handled, isFalse);
      expect(rerendered, isFalse);
    });

    test('本 handler 恒被吞掉；无 model 时不重渲（不炸、不空转）', () {
      bool rerendered = false;
      final bool handled = maybeHandleOverlayZoomFontStep(
        model: null,
        handler: 'popupZoomFontStep',
        message: const <String, Object?>{
          'args': <Object?>[1]
        },
        onFontSizeChanged: () => rerendered = true,
      );
      expect(handled, isTrue);
      expect(rerendered, isFalse);
    });
  });

  group('BUG-1139 (3) 源码守卫', () {
    test('C++ 覆盖窗关掉 WebView2 原生缩放并复位持久 ZoomFactor', () {
      final String cpp =
          _repoFile('hibiki/windows/runner/global_lookup_window.cpp')
              .readAsStringSync();
      expect(cpp.contains('put_IsZoomControlEnabled(FALSE)'), isTrue,
          reason: '原生 Ctrl+滚轮缩放必须关掉：几何链看不见 ZoomFactor');
      expect(cpp.contains('put_ZoomFactor(1.0)'), isTrue,
          reason: 'WebView2 缩放档位按 origin 持久记忆，只关控制不复位则老用户仍是坏的');
      // 两者都必须在 ConfigureWebView 内 —— 它是两条创建路径 + BUG-693 自愈重建的
      // 唯一漏斗，写在别处会漏掉某个 surface。
      final int configureAt =
          cpp.indexOf('void GlobalLookupWindow::ConfigureWebView()');
      expect(configureAt, greaterThan(0));
      expect(cpp.indexOf('put_IsZoomControlEnabled(FALSE)'),
          greaterThan(configureAt),
          reason: '必须落在 ConfigureWebView 这个唯一漏斗里');
      expect(cpp.indexOf('put_ZoomFactor(1.0)'), greaterThan(configureAt),
          reason: '必须落在 ConfigureWebView 这个唯一漏斗里');
    });

    test('app 外注入装 Ctrl+滚轮监听，回传净档数，且不就地改 zoom', () {
      final String dart = _repoFile(
              'hibiki/lib/src/pages/implementations/popup_settings_injection.dart')
          .readAsStringSync();
      final int start = dart.indexOf('_globalLookupZoomWheelJs = ');
      expect(start, greaterThan(0), reason: 'app 外 Ctrl+滚轮注入常量必须存在');
      final int end = dart.indexOf("''';", start);
      expect(end, greaterThan(start));
      final String js = dart.substring(start, end);

      expect(js.contains('e.ctrlKey'), isTrue, reason: '只拦 Ctrl+滚轮，普通滚动不受影响');
      expect(js.contains('preventDefault'), isTrue);
      expect(js.contains("callHandler('popupZoomFontStep'"), isTrue,
          reason: '走 Dart 改词典字号这条唯一真值链');
      expect(js.contains('requestAnimationFrame'), isTrue,
          reason: '快滚必须合帧，否则一次滚动打出十几次 Dart 往返 + 整栈重渲');
      // 红线：app 外**不能**就地改 documentElement.style.zoom —— CSS zoom 下
      // body.scrollHeight 不含 z，host 的 measureContentHeight 会把卡片高度系统性
      // 报小 z 倍，等于把几何链的老毛病换个地方复发。
      expect(js.contains('style.zoom'), isFalse,
          reason: 'app 外禁止就地 CSS zoom（几何链按未缩放 CSS px 测量）');

      // 只装给 app 外：in-app 三个表面由 dictionary_popup_webview 的 _zoomWheelJs
      // 装同名 guard 的另一套，双装会一档滚两级。
      expect(
          RegExp(r'options\.globalLookup\s*\?\s*_globalLookupZoomWheelJs\s*:\s*')
              .hasMatch(dart),
          isTrue,
          reason: 'Ctrl+滚轮注入必须由 globalLookup 门控');
    });

    test('host 测高把 iframe layout px 换算回 host CSS px（③ 几何闭环）', () {
      // 行为级断言在 node harness（global_lookup_host_test.mjs 的 Z1，负向验证过：
      // 去掉换算即 exit 1）。那个 harness 不在 CI 里跑，所以这里补一条 CI 可见的
      // 源码守卫，防止有人把换算删掉后 CI 依然全绿。
      final String host = _repoFile('hibiki/assets/popup/global_lookup_host.js')
          .readAsStringSync();
      expect(host.contains('function frameContentZoom('), isTrue,
          reason: '缺 zoom 读取：iframe 的 documentElement.style.zoom 是唯一来源');
      expect(host.contains('layoutPx * frameContentZoom(record)'), isTrue,
          reason: 'measureContentHeight 必须把 layout px 乘回 z，'
              '否则 z>1 时 window region 比内容矮 1/z，卡片底部又被裁');
      // 换算必须落在 measureContentHeight 内 —— 它是 measureAndReport 唯一的
      // 内容高度来源（bbox maxBottom + shellRects 都吃它）。
      final int measureAt = host.indexOf('function measureContentHeight(');
      expect(measureAt, greaterThan(0));
      expect(host.indexOf('layoutPx * frameContentZoom(record)'),
          greaterThan(measureAt),
          reason: '换算必须在 measureContentHeight 里，别散到调用方');
    });

    test('瞬态覆盖窗与剪贴板面板都接了这根 handler（两表面绝不漂开）', () {
      for (final String path in <String>[
        'hibiki/lib/src/lookup/global_lookup_controller.dart',
        'hibiki/lib/src/lookup/clipboard_panel_controller.dart',
      ]) {
        final String src = _repoFile(path).readAsStringSync();
        expect(src.contains('maybeHandleOverlayZoomFontStep('), isTrue,
            reason: '$path 必须接 Ctrl+滚轮缩放，否则两个 app 外表面行为分叉');
        expect(src.contains('onFontSizeChanged:'), isTrue,
            reason: '$path 必须在字号变化后重渲，几何才跟得上新排版');
      }
    });
  });
}

// BUG-2284 回归守卫：查词弹窗「瞬时滚动」（lookup.popup_instant_scroll）必须真的
// 改变滚动行为，以及对齐 Hoshi Reader Android 的「紧凑释义」开关必须真的下发。
//
// 原始 bug：开关打开后用户看不出任何差别。两条独立原因——
//   ① 唯一的消费点是 fushiCaret._scrollWindowBy 的
//      `behavior: instantScroll ? 'instant' : 'auto'`，而弹窗全链路没有任何
//      `scroll-behavior: smooth`（popup.css 只有 overscroll-behavior-y），所以
//      'auto' 本来就是瞬时的 —— 三元的两个分支等价，开关等于没接线；
//   ② 用户实际在滚的是滚轮，而 popup.js 的 wheel 监听器（BUG-260/870/1026 那条
//      比例滚动链路）从来不读这个偏好。
// 设置项的说明文案写的是「按固定距离瞬时跳动」，所以修法是把偏好下发成
// window.__fushiPopupInstantScroll，由 wheel 监听器改走固定步长跳跃 + 手势合并。
//
// 本守卫钉死的是「开关 → 行为」这条线上每一段的存在性，任何一段被摘掉都会让开关
// 重新退化成空开关（而单测里没有真 WebView，滚动本身无法直接断言）。
//
// flutter test cwd 是 fushi 包根。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const List<String> popupCopies = <String>[
    'assets/popup/popup.js', // in-app 渲染器（真源）
    'assets/browser_extension/vendor/popup.js', // 扩展 bundle 镜像
    '../tools/browser-extension/vendor/popup.js', // 扩展 tools 镜像
  ];

  group('BUG-2284 popup instant-scroll guard', () {
    for (final String path in popupCopies) {
      test('[$path] 滚轮按 __fushiPopupInstantScroll 走固定步长瞬跳', () {
        final String src = File(path).readAsStringSync();

        // ① 偏好真的被滚轮路径消费（此前只有 fushiCaret 读它）。
        expect(
          src,
          contains('window.__fushiPopupInstantScroll'),
          reason: 'wheel 监听器必须读 window.__fushiPopupInstantScroll，否则开关对滚轮无效',
        );

        // ② 瞬时分支必须**先于**比例滚动的 factor 计算，否则事件已被比例路径消费。
        final int instantAt = src.indexOf(
          'if (window.__fushiPopupInstantScroll)',
        );
        final int factorAt = src.indexOf('const factor = (coarseMouseNotch');
        expect(
          instantAt,
          greaterThanOrEqualTo(0),
          reason: '瞬时分支必须在 wheel 监听器里',
        );
        expect(
          factorAt,
          greaterThan(instantAt),
          reason: '瞬时分支必须在比例滚动 factor 之前吃掉事件',
        );

        // ③ 步长是「视口的固定比例」，不是 delta 的函数——这正是设置文案承诺的
        //    「按固定距离瞬时跳动」。
        expect(src, contains('POPUP_EINK_WHEEL_VIEWPORT_FRACTION'));
        expect(src, contains('function popupEinkWheelExtent('));
        final String instantBranch = src.substring(instantAt, factorAt);
        expect(
          instantBranch.contains('deltaPx *'),
          isFalse,
          reason: '瞬时分支不得按 delta 比例缩放——那就退化回连续滚动了',
        );

        // ④ 手势合并：触控板一次惯性滑动发几十帧，不合并会直接跳到底。
        expect(src, contains('POPUP_EINK_WHEEL_COOLDOWN_MS'));
        expect(
          instantBranch,
          contains('_popupEinkWheelAt'),
          reason: '瞬时分支必须有冷却窗口，否则一次 fling 连跳到底',
        );

        // ⑤ 滚动目标仍按表面解析（BUG-688：扩展滚 shadow host，in-app 滚 window）。
        expect(instantBranch, contains('scroller.scrollBy('));
        expect(instantBranch, contains('window.scrollBy('));
      });
    }

    test('偏好经 popup_settings_injection 下发到 in-app 三种弹窗', () {
      final String src = File(
        'lib/src/pages/implementations/popup_settings_injection.dart',
      ).readAsStringSync();
      expect(
        src,
        contains(
          r'window.__fushiPopupInstantScroll = ${appModel.popupInstantScroll};',
        ),
        reason: 'in-app 弹窗必须在 head 注入里下发该偏好',
      );
      // 静态段有 memo（BUG-717 ③）：偏好不进命中判据 = 改了设置也不重建注入串，
      // 开关要等到别的输入变化才生效。
      expect(
        src,
        contains('cached.popupInstantScroll == appModel.popupInstantScroll &&'),
        reason: '静态段 memo 命中判据必须含该偏好，否则改设置不重新注入',
      );
      expect(
        src,
        contains('cached.compactGlossaries == appModel.compactGlossaries &&'),
        reason: '静态段 memo 命中判据必须含紧凑释义，否则改设置不重新注入',
      );
    });

    test('偏好经 theme 通道下发到浏览器扩展弹窗', () {
      final String appModel = File(
        'lib/src/models/app_model.dart',
      ).readAsStringSync();
      expect(
        appModel,
        contains("'--fushi-instant-scroll': popupInstantScroll ? '1' : '0',"),
        reason: '扩展弹窗只有 theme 这一条下发通道（与 --fushi-wheel-speed 同法）',
      );
      for (final String path in <String>[
        'assets/browser_extension/content.js',
        '../tools/browser-extension/content.js',
        'assets/browser_extension/side-panel.js',
        '../tools/browser-extension/side-panel.js',
      ]) {
        expect(
          File(path).readAsStringSync(),
          contains(
            "window.__fushiPopupInstantScroll = theme['--fushi-instant-scroll'] === '1';",
          ),
          reason: '$path 必须把 theme 下发的值落到 popup.js 读的同名全局',
        );
      }
    });

    test('caret 注入带守卫：未定义的 fushiCaret 不得中止整条注入串', () {
      final String src = File(
        'lib/src/reader/reader_caret_scripts.dart',
      ).readAsStringSync();
      expect(
        src,
        contains(
          "'window.fushiCaret && window.fushiCaret.setInstantScroll(\$enabled)'",
        ),
        reason: '该调用被拼进 _pushResults 的整条 evaluateJavascript；裸调用在 fushiCaret '
            '尚未落地时抛 TypeError，会连带吃掉后面的 __fushiRenderToken / renderPopup()',
      );
    });
  });

  group('对齐 Hoshi Reader Android：紧凑释义开关', () {
    test('渲染器的 window.compactGlossaries 有唯一写入点', () {
      // popup.js 的 createDictionaryBlock 一直按这个全局产出紧凑释义 CSS，但在
      // BUG-2284 之前全 app 没有任何地方给它赋值（恒 undefined = 死代码）。
      final String injection = File(
        'lib/src/pages/implementations/popup_settings_injection.dart',
      ).readAsStringSync();
      expect(
        injection,
        contains(r'window.compactGlossaries = ${appModel.compactGlossaries};'),
      );
      final String popup = File('assets/popup/popup.js').readAsStringSync();
      expect(
        popup,
        contains('window.compactGlossaries ?'),
        reason: '渲染器侧的消费点还在（两侧同时存在才叫接线完成）',
      );
    });

    test('设置项存在且落到已登记的偏好键', () {
      expect(
        File('lib/src/settings/settings_schema_lookup.dart').readAsStringSync(),
        contains("id: 'lookup.compact_glossaries',"),
      );
      expect(
        File('lib/src/models/preferences_repository.dart').readAsStringSync(),
        contains("getPref('popup_compact_glossaries', defaultValue: false)"),
        reason: '默认 false = 保持存量用户观感不变（Android 那边默认 true）',
      );
      expect(
        File('lib/src/models/preference_keys.dart').readAsStringSync(),
        contains("'popup_compact_glossaries',"),
        reason: '新键必须登记进 kKnownPreferenceKeys（preference_keys_guard 会红）',
      );
    });
  });
}

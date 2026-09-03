import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_settings.dart';

/// BUG-1828：阅读器大图的**点击命中区必须等于用户看得见的那张图**。
///
/// 命中判据在 `webview.part.dart` 的 `_fushiBlockImageUrl`：
/// ```js
/// var wrapper = target.closest ? target.closest('.block-img-wrapper') : null;
/// if (!wrapper) return null;
/// ```
/// 判的是「命中元素在不在这个居中容器里」，而 `.block-img-wrapper` 是 `display:flex` +
/// 居中的**纯布局盒**，横向撑满整列。实测（1364px CSS 视口、真实用户设置）：
/// wrapper 横跨 0→1364，`svg.block-img` 34.5→1329.5，真正画出来的 `<image>` 只有
/// 407→957 —— **整页 40% 是图，60% 是留白，却全部算「点中图片」**。
///
/// 后果：每一次点击都走 `onImageTap`（弹图片查看器），`onTapEmpty` 永远触发不到 →
/// 底栏唤不出来。整章只有一张图的章节（封面 / 插图页 / BOOK☆WALKER 尾页）里全页无一处
/// 例外，用户被关死在页内（用户报告：「点击空白的地方，进入到图片里面了，而没有出现底栏」）。
///
/// 修法不是给 5 个命中点各补坐标参数，而是**让纯布局盒不参与命中**：一条 CSS 不变量同时
/// 管住 tap / touch / contextmenu / 右键四条路径。本测试锁这条不变量。
Future<ReaderSettings> _defaultSettings() async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final ReaderSettings settings = ReaderSettings(db);
  await settings.refreshFromDb();
  return settings;
}

/// 取出 [selector] 那条规则的**声明块**（`{...}` 内部），让断言带左边界——
/// 裸 `css.contains('pointer-events: none')` 会被任何一条别的规则假阳性满足。
String _ruleBody(String css, String selector) {
  final int selIdx = css.indexOf('\n$selector {');
  expect(selIdx, isNonNegative, reason: '样式表里找不到规则：$selector');
  final int open = css.indexOf('{', selIdx);
  final int close = css.indexOf('}', open);
  expect(close, isNonNegative, reason: '规则未闭合：$selector');
  return css.substring(open + 1, close);
}

void main() {
  group('BUG-1828：命中区 = 图片本身', () {
    late String css;

    setUp(() async {
      final ReaderSettings settings = await _defaultSettings();
      css = ReaderContentStyles.css(settings: settings);
    });

    test('.block-img-wrapper 是纯布局盒，不参与命中', () {
      expect(
        _ruleBody(css, '.block-img-wrapper'),
        contains('pointer-events: none !important;'),
        reason: 'wrapper 撑满整列却只是居中用；它可命中 ⇒ 图两侧留白被判成点中图片 ⇒ '
            'onTapEmpty 永远触发不到 ⇒ 底栏唤不出来（BUG-1828）',
      );
    });

    test('img.block-img 可命中（盒子等于图片，无 letterbox）', () {
      final String body = _ruleBody(css, 'img.block-img');
      expect(body, contains('pointer-events: auto !important;'));
      // 之所以整个盒子都能点，是因为它用 max-* + auto 收缩到图片本身。
      expect(body, contains('max-width:'));
      expect(body, contains('max-height:'));
      expect(
        body,
        contains('width: auto'),
        reason: 'img.block-img 一旦改成定值 width/height 就会像 svg 那样 letterbox，'
            '届时命中区必须跟着收窄到实际画面',
      );
    });

    test('svg.block-img 盒子不参与命中，只有内部 <image> 可命中', () {
      final String svgBody = _ruleBody(css, 'svg.block-img');
      expect(
        svgBody,
        contains('pointer-events: none !important;'),
        reason: 'svg.block-img 是**定值**盒（下面的断言锁住这一点），内部 <image> 按 '
            'xMidYMid meet 在盒内 letterbox，盒子远宽于画面（实测 1295px vs 549px）',
      );
      // 定值盒是 letterbox 的成因，也是必须拆出内部 <image> 规则的理由。
      expect(svgBody, contains('width: var(--fushi-image-max-width'));
      expect(svgBody, contains('height: var(--fushi-image-max-height'));

      expect(
        _ruleBody(css, 'svg.block-img image'),
        contains('pointer-events: auto !important;'),
        reason: '<image> 的边框盒才是 meet 之后画面所占的矩形，命中区必须落在它上面',
      );
    });

    test('命中区不变量与 JS 判据保持耦合', () {
      final String js = File(
        'lib/src/pages/implementations/reader_fushi/webview.part.dart',
      ).readAsStringSync();
      expect(
        js,
        contains("closest('.block-img-wrapper')"),
        reason: 'JS 判据仍以 .block-img-wrapper 归属判「点中图片」，'
            '所以 CSS 必须让这个盒子不可命中；若判据改走别的容器/几何，'
            '本测试与上面三条不变量都要一起重审',
      );
    });
  });
}

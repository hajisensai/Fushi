import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_fushi_card_view.dart';
import 'package:fushi/src/srs/srs_review_layout.dart';
import 'package:material_ui/material_ui.dart';

/// 复习卡面「卡面图片大小」与 WebView 卡点图放大：
/// - 设置 → 注入卡面的 CSS（经 hostCss 走原地换主题，不重放卡片）；
/// - 页内点图脚本 [kSrsCardImageTapScript]（node + 最小 DOM 桩，跑生产常量本身）；
/// - 原生 Fushi 卡片的图片尺寸上限 [srsPictureLimits] 读同一个设置。
void main() {
  SrsCardFaceDocument doc(String hostCss) => SrsCardFaceDocument.of(
    SrsCardFace(
      cardId: 'c1',
      showingAnswer: false,
      bodyHtml: '<img src="a.png">',
      css: 'img{max-height:80px}',
      languageCode: 'ja',
      onBridgeKey: (_) {},
      hostCss: hostCss,
    ),
    dark: false,
    background: const Color(0xFFFFFFFF),
    foreground: const Color(0xFF000000),
    accent: const Color(0xFF6750A4),
    onAccent: const Color(0xFFFFFFFF),
    mediaUrlPrefix: 'https://srs.local/media/',
    themedScrollbar: true,
  );

  group('srsReviewImageSizeCss', () {
    test('原样不注入；另两档压过牌组的 max-height 并保持比例', () {
      expect(srsReviewImageSizeCss(SrsReviewImageSize.original), isEmpty);
      final String fit = srsReviewImageSizeCss(SrsReviewImageSize.fitWidth);
      expect(fit, startsWith('.card img{'));
      expect(fit, contains('max-width:100%!important'));
      expect(fit, contains('max-height:none!important'));
      expect(fit, contains('height:auto!important'));
      expect(fit, isNot(contains('{width:')), reason: '适应宽度不放大小图');
      final String large = srsReviewImageSizeCss(SrsReviewImageSize.large);
      expect(large, contains('.card img{width:100%!important'));
      expect(large, contains('max-height:${kSrsReviewLargeImageMaxVh}vh'));
      expect(large, contains('object-fit:contain'));
    });

    test('wire 名冻结，未知值回落原样', () {
      expect(
        SrsReviewImageSize.values.map((SrsReviewImageSize v) => v.wire),
        <String>['original', 'fit_width', 'large'],
      );
      expect(SrsReviewImageSize.fromWire('bogus'), SrsReviewImageSize.original);
      expect(SrsReviewImageSize.fromWire(null), SrsReviewImageSize.original);
      expect(SrsReviewImageSize.fromWire('large'), SrsReviewImageSize.large);
    });

    test('切换档位只走原地换主题，不重放卡片', () async {
      final List<String> evaluated = <String>[];
      final SrsCardFaceSync sync = SrsCardFaceSync(
        evaluate: (String source) async {
          evaluated.add(source);
          return true;
        },
        reloadShell: () {},
      );
      sync.shellLoaded();
      sync.update(doc(''));
      final String large = srsReviewImageSizeCss(SrsReviewImageSize.large);
      sync.update(doc(large));
      await Future<void>.delayed(Duration.zero);
      expect(evaluated, hasLength(2));
      expect(evaluated.last, contains('__fushiSrsSetTheme'));
      expect(
        evaluated.last,
        contains('max-height:${kSrsReviewLargeImageMaxVh}vh!important'),
      );
      expect(evaluated.last, isNot(contains('__fushiSrsSetCard(')));
    });
  });

  group('kSrsCardImageTapScript', () {
    Future<void> runJs(String body) async {
      final Directory dir = Directory.systemTemp.createTempSync('srs-img-tap-');
      try {
        final File script = File('${dir.path}/verify.js')
          ..writeAsStringSync('''
const assert = require('assert');
const calls = [];
globalThis.window = {
  flutter_inappwebview: { callHandler(name, v){ calls.push([name, v]); } },
};
const listeners = [];
globalThis.document = {
  addEventListener(type, fn, capture){ listeners.push([type, fn, capture]); },
};
// 最小元素桩：closest 按祖先链上的「选择器 → 是否命中」表查。
function el(tag, src, matches){
  return { tagName: tag, currentSrc: src, src: src,
    closest(sel){ return matches[sel] ? {} : null; } };
}
function click(target, opts){
  const e = Object.assign({ target, button: 0, defaultPrevented: false }, opts || {});
  for (const [type, fn] of listeners) if (type === 'click') fn(e);
}
$kSrsCardImageTapScript
$kSrsCardImageTapScript
$body
''');
        final ProcessResult result = await Process.run(
          'node',
          <String>[script.path],
          runInShell: Platform.isWindows,
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      } finally {
        dir.deleteSync(recursive: true);
      }
    }

    test('卡面里的图回传 currentSrc；模板自己处理的点击不抢；脚本幂等', () async {
      await runJs(r'''
assert.equal(listeners.length, 1, '注入两次只挂一个监听');
assert.equal(listeners[0][2], undefined, '冒泡阶段：模板的点击先处理');
const src = 'https://srs.local/media/pic%201.png';
click(el('IMG', src, { '.card': true }));
assert.deepEqual(calls, [['onSrsImageTap', src]]);
calls.length = 0;
click(el('IMG', src, { '.card': true, 'a[href],button,[onclick]': true }));
click(el('IMG', src, { '.card': true }), { defaultPrevented: true });
click(el('IMG', src, { '.card': true }), { button: 2 });
click(el('IMG', src, {}));
click(el('DIV', src, { '.card': true }));
click(el('IMG', '', { '.card': true }));
assert.deepEqual(calls, [], '链接 / onclick 里的图、已拦截、右键、卡外、非图、无地址都不回传');
''');
    });
  });

  group('srsPictureLimits', () {
    test('原样 = 旧上限（220 / 矮视口 120，视口高于 520 才铺满）', () {
      final SrsPictureLimits tall = srsPictureLimits(
        SrsReviewImageSize.original,
        viewport: 800,
      );
      expect(tall.maxHeight, 220);
      expect(tall.fillWidth, isTrue);
      expect(tall.maxFillHeight, 800 * kSrsPictureFillMaxViewportFraction);
      final SrsPictureLimits short = srsPictureLimits(
        SrsReviewImageSize.original,
        viewport: 500,
      );
      expect(short.maxHeight, 120);
      expect(short.fillWidth, isFalse);
    });

    test('档位越大，上限单调变大；放大档矮视口也铺满', () {
      for (final double viewport in <double>[500, 800]) {
        final List<SrsPictureLimits> l = SrsReviewImageSize.values
            .map(
              (SrsReviewImageSize s) => srsPictureLimits(s, viewport: viewport),
            )
            .toList();
        for (int i = 1; i < l.length; i++) {
          expect(
            l[i].maxHeight,
            greaterThan(l[i - 1].maxHeight),
            reason: 'viewport=$viewport #$i',
          );
          expect(l[i].maxFillHeight, greaterThan(l[i - 1].maxFillHeight));
        }
      }
      final SrsPictureLimits large = srsPictureLimits(
        SrsReviewImageSize.large,
        viewport: 500,
      );
      expect(large.fillWidth, isTrue);
      expect(large.maxHeight, 500 * kSrsReviewLargeImageMaxVh / 100);
    });
  });
}

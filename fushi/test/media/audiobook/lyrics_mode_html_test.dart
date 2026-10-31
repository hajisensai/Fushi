import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi/src/media/audiobook/lyrics_mode_html.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';

void main() {
  group('LyricsModeHtml', () {
    test('ready bridge reports the document load generation', () {
      final String html = LyricsModeHtml.generate(
        cues: <AudioCue>[_cue(0)],
        currentIndex: 0,
        backgroundColor: 'rgba(255,255,255,1.00)',
        textColor: 'rgba(0,0,0,1.00)',
        accentColor: 'rgba(255,220,0,1.00)',
        fontSize: 20,
      );

      expect(html, contains('window.__fushiLyricsLoadGeneration = 0;'));
      expect(html, contains("callHandler('onLyricsReady', 0)"));
    });

    // BUG-1815/1809: generation token 是「这份文档是不是我刚发的那一份」的唯一
    // 机制（webview.part.dart 的 _finalizeLyricsDocumentIfReady 靠它丢弃过期
    // finalize）。只测默认值 0 等于什么都没测——把两处 `$loadGeneration` 写死成
    // 0 也照样绿。必须用一个非默认值把插值真正钉死。
    test(
      'load generation is interpolated, not hard-coded to the default 0',
      () {
        final String html = LyricsModeHtml.generate(
          cues: <AudioCue>[_cue(0)],
          currentIndex: 0,
          loadGeneration: 7,
          backgroundColor: 'rgba(255,255,255,1.00)',
          textColor: 'rgba(0,0,0,1.00)',
          accentColor: 'rgba(255,220,0,1.00)',
          fontSize: 20,
        );

        expect(html, contains('window.__fushiLyricsLoadGeneration = 7;'));
        expect(html, contains("callHandler('onLyricsReady', 7)"));
        // 两处都不得残留默认值（写死成 0 的复发形态）。
        expect(
          html,
          isNot(contains('window.__fushiLyricsLoadGeneration = 0;')),
        );
        expect(html, isNot(contains("callHandler('onLyricsReady', 0)")));
      },
    );

    test(
      'includes reader selection highlight styles in the standalone page',
      () {
        final String html = LyricsModeHtml.generate(
          cues: <AudioCue>[_cue(0)],
          currentIndex: 0,
          backgroundColor: 'rgba(255,255,255,1.00)',
          textColor: 'rgba(0,0,0,1.00)',
          accentColor: 'rgba(255,220,0,1.00)',
          fontSize: 20,
        );

        expect(html, contains('::highlight(fushi-selection)'));
        expect(html, contains('.fushi-dict-highlight'));
      },
    );

    test('current cue tap uses selection without disabling native selection', () {
      final String html = LyricsModeHtml.generate(
        cues: <AudioCue>[_cue(0)],
        currentIndex: 0,
        backgroundColor: 'rgba(255,255,255,1.00)',
        textColor: 'rgba(0,0,0,1.00)',
        accentColor: 'rgba(255,220,0,1.00)',
        fontSize: 20,
      );

      // BUG-280: tap-to-lookup now fires from the raw pointer-up/touch-end path
      // (see _lyTapEnd) instead of the synthesized DOM 'click', so it still
      // calls fushiSelection.selectText.
      expect(html, contains('window.fushiSelection.selectText('));
      expect(html, isNot(contains('-webkit-user-select: none;')));
      expect(html, isNot(contains('user-select: none;')));
      expect(html, isNot(contains('var _longPressed')));
    });

    // BUG-280: 歌词模式查完一个词后无法继续查下一句。原因是 #lc 用 DOM 'click'
    // 触发查词，而 click 只在「pointerdown→up 全程未被宿主层认领」时由浏览器合成；
    // 当 Flutter 端弹窗可见时整屏有一层 translucent 手势屏障会认领点按 → WebView 收
    // 不到 click → 只关弹窗不发新查词。修复=对齐阅读器正文，用原始 pointerup/touchend
    // （passive:false）+ 小位移门控触发查词，使屏障在场时 WebView 仍能拿到点按。
    test(
      'lyrics tap uses raw pointer/touch (not synthesized click) for lookup',
      () {
        final String html = LyricsModeHtml.generate(
          cues: <AudioCue>[_cue(0), _cue(1)],
          currentIndex: 0,
          backgroundColor: 'rgba(255,255,255,1.00)',
          textColor: 'rgba(0,0,0,1.00)',
          accentColor: 'rgba(255,220,0,1.00)',
          fontSize: 20,
        );

        // Raw pointer-up / touch-end listeners on #lc drive the lookup so the
        // gesture reaches the WebView even when the Flutter dismiss barrier is up.
        expect(html, contains("_lc.addEventListener('pointerup'"));
        expect(html, contains("_lc.addEventListener('touchend'"));
        // Lookup must NOT be wired to the synthesized 'click' event (the broken
        // path the dismiss barrier swallowed).
        expect(html, isNot(contains("addEventListener('click'")));
        // touchend / pointerup register passive:false so preventing/handling the
        // gesture is allowed (mirrors the reader content gesture handlers).
        expect(html, contains('{passive: false}'));
      },
    );

    // BUG-017: the active cue used `max-width: 92vw` while `.cue.current` was
    // scaled by `transform: scale(1.15)`. Scaling a near-full-width box past
    // 100vw made the highlighted line spill off both screen edges (clipped by
    // `overflow-x: hidden`). The cue width must be expressed relative to the
    // container content box AND discount the scale factor so the scaled box
    // never exceeds the available width.
    test(
      'active cue width reserves headroom for its scale (no edge clipping)',
      () {
        final String html = LyricsModeHtml.generate(
          cues: <AudioCue>[_cue(0)],
          currentIndex: 0,
          backgroundColor: 'rgba(255,255,255,1.00)',
          textColor: 'rgba(0,0,0,1.00)',
          accentColor: 'rgba(255,220,0,1.00)',
          fontSize: 20,
        );

        final String cueRule = _cssBlock(html, '.cue {');
        final String currentRule = _cssBlock(html, '.cue.current {');

        // The current cue is enlarged via transform scale, keyed off a shared
        // variable so the width headroom below stays in lock-step with it.
        expect(currentRule, contains('transform: scale(var(--cue-scale))'));
        expect(html, contains('--cue-scale:'));

        // Width must be relative to the container content box (100%), never a
        // viewport-fixed value that ignores both the scale and the margins.
        expect(cueRule, contains('max-width: calc(100% / var(--cue-scale)'));
        expect(cueRule, isNot(contains('92vw')));
        expect(cueRule, isNot(contains('max-width: 100vw')));
      },
    );

    // The lyrics page is a standalone document (not ReaderContentStyles), so it
    // needs its own themed scrollbar or it shows the default grey bar over the
    // themed background. The classic WebView2 scrollbar honours
    // ::-webkit-scrollbar; the standard props cover overlay engines.
    test(
      'scrollbar is themed to the cue text colour with a transparent track',
      () {
        final String html = LyricsModeHtml.generate(
          cues: <AudioCue>[_cue(0), _cue(1)],
          currentIndex: 0,
          backgroundColor: 'rgba(18,18,18,1.00)',
          textColor: 'rgba(255,255,255,0.87)',
          accentColor: 'rgba(255,220,0,1.00)',
          fontSize: 20,
        );

        expect(html, contains('::-webkit-scrollbar-thumb'));
        final String thumbRule = _cssBlock(html, '::-webkit-scrollbar-thumb {');
        expect(thumbRule, contains('background-color: rgba(255,255,255,0.87)'));

        final String trackRule = _cssBlock(html, '::-webkit-scrollbar-track {');
        expect(trackRule, contains('background: transparent'));

        final String rootRule = _cssBlock(html, 'html, body {');
        expect(rootRule, contains('scrollbar-width: thin;'));
        expect(
          rootRule,
          contains('scrollbar-color: rgba(255,255,255,0.87) transparent;'),
        );
      },
    );

    test(
      'live style update repaints the scrollbar thumb to the new text colour',
      () {
        final String html = LyricsModeHtml.generate(
          cues: <AudioCue>[_cue(0)],
          currentIndex: 0,
          backgroundColor: 'rgba(255,255,255,1.00)',
          textColor: 'rgba(0,0,0,0.87)',
          accentColor: 'rgba(255,220,0,1.00)',
          fontSize: 20,
        );

        // __lyricsUpdateStyle must patch the scrollbar rules, not just .cue, so
        // changing theme while in lyrics mode recolours the bar without reload.
        expect(
          html,
          contains("r.selectorText === '::-webkit-scrollbar-thumb'"),
        );
        expect(html, contains("r.selectorText === 'html, body'"));
        expect(html, contains("setProperty('scrollbar-color'"));
      },
    );

    // TODO-907: vertical lyrics mode is a separate `vertical` flag (default
    // false = horizontal, backward-compatible). Horizontal output must NOT
    // carry the vertical writing-mode; vertical output must.
    test('default (horizontal) page has no vertical writing-mode', () {
      final String html = LyricsModeHtml.generate(
        cues: <AudioCue>[_cue(0)],
        currentIndex: 0,
        backgroundColor: 'rgba(255,255,255,1.00)',
        textColor: 'rgba(0,0,0,1.00)',
        accentColor: 'rgba(255,220,0,1.00)',
        fontSize: 20,
      );

      expect(html, isNot(contains('writing-mode: vertical-rl')));
      expect(html, contains('var __lyricsVertical = false;'));
      final String rootRule = _cssBlock(html, 'html, body {');
      expect(rootRule, contains('overflow-x: hidden;'));
    });

    test('vertical mode emits vertical-rl writing-mode and horizontal scroll', () {
      final String html = LyricsModeHtml.generate(
        cues: <AudioCue>[_cue(0), _cue(1)],
        currentIndex: 0,
        backgroundColor: 'rgba(255,255,255,1.00)',
        textColor: 'rgba(0,0,0,1.00)',
        accentColor: 'rgba(255,220,0,1.00)',
        fontSize: 20,
        vertical: true,
      );

      // The body switches to vertical-rl (top-to-bottom, right-to-left) and
      // scrolls horizontally; the JS axis flag must follow.
      final String rootRule = _cssBlock(html, 'html, body {');
      expect(rootRule, contains('writing-mode: vertical-rl;'));
      expect(rootRule, contains('overflow-x: auto;'));
      expect(rootRule, contains('overflow-y: hidden;'));
      expect(html, contains('var __lyricsVertical = true;'));

      // The flex main axis follows writing-mode: under vertical-rl `column` is
      // the block axis (right-to-left), so each cue is its own column. `row`
      // would be the inline axis (top-to-bottom) and squash every cue into one
      // screen height — the original TODO-907 layout that never rendered.
      final String containerRule = _cssBlock(html, '.lyrics-container {');
      expect(containerRule, contains('flex-direction: column;'));
      expect(containerRule, isNot(contains('flex-direction: row;')));

      // Scrolling is delta/incremental to dodge vertical-rl's negative scrollX
      // coordinate, not absolute scrollTo. BUG-784: the delta is applied to the
      // real overflow container's scrollLeft (vertical mode = horizontal scroll),
      // not window.scrollBy (which no-ops because body, not html, is the scroller).
      expect(html, contains('s.scrollLeft += d'));
      expect(html, contains('_lyricsScrollByAxis'));
    });

    // 竖排专属 .cue 几何：宽度上限换行内方向（长句折列而不是被裁）、句间距走
    // 左右、放大原点 / 收藏星标按竖排挪；横排文档一个字节都不带。
    group('vertical cue geometry', () {
      String build({required bool vertical, LyricsHtmlTheme? theme}) {
        return LyricsModeHtml.generate(
          cues: <AudioCue>[_cue(0), _cue(1)],
          currentIndex: 0,
          backgroundColor: 'rgba(255,255,255,1.00)',
          textColor: 'rgba(0,0,0,1.00)',
          accentColor: 'rgba(255,220,0,1.00)',
          fontSize: 20,
          vertical: vertical,
          theme: theme,
        );
      }

      LyricsHtmlTheme theme(bool alignStart) => LyricsHtmlTheme(
        textColor: const Color(0xFFFFFFFF),
        currentColor: const Color(0xFFFFFFFF),
        accentColor: const Color(0x4DFFFFFF),
        selectionTextColor: const Color(0xFFFFFFFF),
        contextOpacities: const <double>[0.46, 0.36, 0.3, 0.26],
        browsingOpacity: 0.6,
        deselectedScale: 0.96,
        anchorY: 0.46,
        edgeFade: 0.08,
        alignStart: alignStart,
        contextBlurPx: 0,
        rowRadius: 16,
      );

      test('vertical page caps the inline size and swaps cue spacing', () {
        final String html = build(vertical: true);
        final String cueRule = _cssBlock(html, '.lyrics-container > .cue {');
        expect(cueRule, contains('max-width: none;'));
        expect(
          cueRule,
          contains('max-inline-size: calc(100% / var(--cue-scale) - 1%);'),
        );
        expect(cueRule, contains('padding: 8px 12px;'));
        expect(
          cueRule,
          contains('transform-origin: var(--ly-origin-v, center);'),
        );
        final String themedRule = _cssBlock(
          html,
          'body.ly-themed .lyrics-container > .cue {',
        );
        expect(themedRule, contains('margin: 0 2px;'));
        final String starRule = _cssBlock(
          html,
          '.lyrics-container > .cue.favorited::before {',
        );
        expect(starRule, contains('bottom: -2px;'));
        expect(starRule, contains('left: 50%;'));
      });

      test('vertical overrides never use a bare .cue selector', () {
        // __lyricsUpdateStyle rewrites rules by selectorText; a second bare
        // `.cue` rule would be rewritten as if it were the base rule.
        final String html = build(vertical: true);
        expect(
          RegExp(r'^\.cue \{', multiLine: true).allMatches(html).length,
          1,
        );
      });

      test('horizontal page carries none of the vertical geometry', () {
        final String html = build(vertical: false);
        expect(html, isNot(contains('.lyrics-container > .cue')));
        expect(html, isNot(contains('max-inline-size')));
        final String containerRule = _cssBlock(html, '.lyrics-container {');
        expect(containerRule, contains('flex-direction: column;'));
      });

      test(
        'theme exposes a vertical transform origin (top when start-aligned)',
        () {
          expect(
            LyricsModeHtml.themeVars(theme(true)).vars['--ly-origin-v'],
            'center top',
          );
          expect(
            LyricsModeHtml.themeVars(theme(false)).vars['--ly-origin-v'],
            'center',
          );
          final String html = build(vertical: true, theme: theme(true));
          expect(html, contains('--ly-origin-v: center top;'));
          expect(html, contains('ly-vertical'));
        },
      );

      test('vertical wheel is projected onto horizontal scroll', () {
        final String html = build(vertical: true);
        // 竖排：纵向滚轮取反投影到横轴（往下滚 = 往后读 = scrollLeft 变小）。
        expect(html, contains('raw = -e.deltaY;'));
        expect(html, contains('if (__lyricsVertical) s.scrollLeft = v;'));
        // BUG-3282：投影量累加进目标位置、按帧平滑逼近（不再一格瞬移）。
        expect(html, contains('_lyWheelTarget += px;'));
      });

      // BUG-3282：滚轮平滑的逐帧函数在真 JS 引擎里跑：单调逼近、有限帧内精确
      // 落到目标，两个方向都成立。无 node 时 skip。
      test(
        'wheel easing step converges monotonically onto the target',
        () async {
          final String? node = _resolveNode();
          if (node == null) {
            markTestSkipped('node not found on PATH');
            return;
          }
          const String sig = 'function __lyricsWheelStep(';
          final String fn = '$sig${_fnSource(build(vertical: true), sig)}';
          final Directory dir = Directory.systemTemp.createTempSync(
            'lyrics_wheel_step',
          );
          final File js = File('${dir.path}${Platform.pathSeparator}harness.js')
            ..writeAsStringSync('$fn\n$_wheelHarness');
          try {
            final ProcessResult r = await Process.run(node, <String>[js.path]);
            expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
            expect('${r.stdout}', contains('WHEEL_OK 2'));
          } finally {
            dir.deleteSync(recursive: true);
          }
        },
      );
    });

    // 滚动居中纯函数在真 JS 引擎里跑：只产生增量、从不写绝对 scrollLeft，所以
    // vertical-rl 的两种 scrollLeft 约定（Chromium 85+ / WKWebView 的「起点 0、往左
    // 为负」，老 Chromium WebView 的「起点 max、往左变小」）下都把当前句居中，滚轮
    // 往下读也都往左走。无 node 时 skip。
    test(
      'center delta centers the cue under both RTL scrollLeft conventions',
      () async {
        final String? node = _resolveNode();
        if (node == null) {
          markTestSkipped('node not found on PATH');
          return;
        }
        final String html = LyricsModeHtml.generate(
          cues: <AudioCue>[_cue(0)],
          currentIndex: 0,
          backgroundColor: 'rgba(255,255,255,1.00)',
          textColor: 'rgba(0,0,0,1.00)',
          accentColor: 'rgba(255,220,0,1.00)',
          fontSize: 20,
          vertical: true,
        );
        const String sig = 'function __lyricsCenterDeltaFor(';
        final String fn = '$sig${_fnSource(html, sig)}';
        final Directory dir = Directory.systemTemp.createTempSync(
          'lyrics_center_delta',
        );
        final File js = File('${dir.path}${Platform.pathSeparator}harness.js')
          ..writeAsStringSync('$fn\n$_centerHarness');
        try {
          final ProcessResult r = await Process.run(node, <String>[js.path]);
          expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
          expect('${r.stdout}', contains('CENTER_OK 4'));
        } finally {
          dir.deleteSync(recursive: true);
        }
      },
    );

    // TODO-1080: an over-long sentence can be taller (vertical-rl) or wider than
    // the screen and gets clipped by the body's overflow-hidden. The page must
    // ship a measure-then-shrink pass (__lyricsFitCues) that overrides only an
    // overflowing cue's inline font-size, keeping every fitting cue at the base.
    group('over-long cue auto-shrink (TODO-1080)', () {
      String buildHtml({bool vertical = false, double fontSize = 24}) {
        return LyricsModeHtml.generate(
          cues: <AudioCue>[_cue(0), _cue(1)],
          currentIndex: 0,
          backgroundColor: 'rgba(255,255,255,1.00)',
          textColor: 'rgba(0,0,0,1.00)',
          accentColor: 'rgba(255,220,0,1.00)',
          fontSize: fontSize,
          vertical: vertical,
        );
      }

      test('base cue font-size flows from the --cue-font-size custom prop', () {
        final String html = buildHtml(fontSize: 30);
        // The base size is a custom prop so JS can shrink one cue without
        // beating it via a fixed .cue font-size.
        expect(html, contains('--cue-font-size: 30.0px;'));
        final String cueRule = _cssBlock(html, '.cue {');
        expect(cueRule, contains('font-size: var(--cue-font-size);'));
        // No fixed px font-size baked onto the .cue rule itself.
        expect(cueRule, isNot(contains('font-size: 30.0px')));
      });

      test('ships a measure-then-shrink fit pass over all cues', () {
        final String html = buildHtml();
        expect(html, contains('function __lyricsFitCues()'));
        expect(html, contains('window.__lyricsFitCues = __lyricsFitCues;'));
        // The pass is invoked on initial load before scroll positioning.
        expect(html, contains('__lyricsFitCues();'));
        // Only overflowing cues get an inline override; fitting cues are cleared.
        expect(html, contains("el.style.fontSize = ''"));
        expect(html, contains('function _lyricsFitCue('));
      });

      test('shrink is clamped to a readable minimum floor', () {
        final String html = buildHtml();
        expect(html, contains('__LYRICS_MIN_FONT_PX = 12'));
        expect(html, contains('Math.max(__LYRICS_MIN_FONT_PX'));
      });

      test(
        'fit measures the constraining axis (height vertical, width horizontal)',
        () {
          final String html = buildHtml();
          // Scale-independent layout-box extents (offsetHeight/offsetWidth), not
          // getBoundingClientRect which would fold in the .current scale.
          expect(
            html,
            contains('__lyricsVertical ? el.offsetHeight : el.offsetWidth'),
          );
          // Available extent is discounted by --cue-scale so a cue that fits
          // un-scaled but overflows once enlarged still fits.
          expect(html, contains('/ scale'));
        },
      );

      test(
        'live style update retargets the base var and re-fits (no reload)',
        () {
          final String html = buildHtml();
          // Font-size live update writes the --cue-font-size prop (not a fixed
          // .cue font-size) so the refit re-measures against the new base.
          expect(
            html,
            contains(
              "root.style.setProperty('--cue-font-size', fontSize + 'px')",
            ),
          );
          // __lyricsUpdateStyle re-runs the fit pass after mutating base/margins.
          final String updateFn = _fnBody(
            html,
            'window.__lyricsUpdateStyle = function',
          );
          expect(updateFn, contains('__lyricsFitCues();'));
        },
      );

      test('re-fits on viewport resize (rotation / window resize)', () {
        final String html = buildHtml();
        expect(html, contains("window.addEventListener('resize'"));
        expect(html, contains('__lyricsFitCues()'));
      });

      // BUG-3416：iOS 一进歌词模式就是竖排时不显示。歌词 WKWebView 在就绪前被
      // Flutter 设为透明，视口是 0×0；旧的逐句「清空→测量」让每句都强制一次整页
      // 布局，竖排零视口下每字一列，600 句卡死 WebContent 主线程十几秒（真机更久），
      // 就绪握手 / resize / 切横排的 loadData 全排在它后面。真 JS 里跑：零视口不量
      // 不写不定位；有视口时常数次强制布局；初始居中等到真实视口才做且只做一次。
      test(
        'fit pass skips a zero viewport and batches reads (BUG-3416)',
        () async {
          final String? node = _resolveNode();
          if (node == null) {
            markTestSkipped('node not found on PATH');
            return;
          }
          final String html = buildHtml(vertical: true);
          final String fns = <String>[
            'function __lyricsHasViewport(',
            'function _lyricsFitCue(',
            'function __lyricsFitCues(',
            'function _lyInitialPosition(',
          ].map((String sig) => '$sig${_fnSource(html, sig)}').join('\n');
          final Directory dir = Directory.systemTemp.createTempSync(
            'lyrics_fit_viewport',
          );
          final File js = File('${dir.path}${Platform.pathSeparator}harness.js')
            ..writeAsStringSync('$_fitHarnessPrelude\n$fns\n$_fitHarness');
          try {
            final ProcessResult r = await Process.run(node, <String>[js.path]);
            expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
            expect('${r.stdout}', contains('FIT_OK'));
          } finally {
            dir.deleteSync(recursive: true);
          }
        },
      );
    });

    // BUG-844: 歌词是独立文档，正文 setup 脚本（含 mousemove→onShiftHover 与
    // window.__hoverAutoLookup）不注入到这里，导致歌词模式此前完全不支持悬停查词，
    // 只能点击查词。这里守卫悬停查词监听已镜像正文语义、且 selectText 重写透传
    // fromHover（否则悬停命中空白误 fire onTapEmpty、同词悬停被 toggle）。
    group('shift / auto hover lookup parity (BUG-844)', () {
      String buildHtml() {
        return LyricsModeHtml.generate(
          cues: <AudioCue>[_cue(0), _cue(1)],
          currentIndex: 0,
          backgroundColor: 'rgba(255,255,255,1.00)',
          textColor: 'rgba(0,0,0,1.00)',
          accentColor: 'rgba(255,220,0,1.00)',
          fontSize: 20,
        );
      }

      test('ships a document mousemove listener that fires onShiftHover', () {
        final String html = buildHtml();
        // Hover lookup must live in the lyrics document itself (the reader setup
        // script is not injected here), mirroring webview.part.dart's listener.
        expect(html, contains("document.addEventListener('mousemove'"));
        expect(
          html,
          contains("window.flutter_inappwebview.callHandler('onShiftHover'"),
        );
      });

      test(
        'hover is gated on the lookup key or the __hoverAutoLookup toggle',
        () {
          final String html = buildHtml();
          // Same gate as the reader body: the configured lookup key held (setting
          // 「悬停查词按键」, pushed as window.__fushiHoverKey, Shift by default)
          // OR the "hover to look up" setting on; neither → reset the throttle
          // anchor and bail.
          expect(
            html,
            contains(
              "!e[window.__fushiHoverKey || 'shiftKey'] && "
              '!window.__hoverAutoLookup',
            ),
          );
        },
      );

      test('hover honours the 8px (64 px^2) movement throttle', () {
        final String html = buildHtml();
        // Identical movement threshold to the reader body so a stationary cursor
        // does not re-fire a lookup every mousemove.
        expect(html, contains('dx * dx + dy * dy < 64'));
      });

      test('selectText override forwards fromHover (all args, not just 3)', () {
        final String html = buildHtml();
        // The override must pass the 4th fromHover arg through, otherwise a hover
        // over blank space fires onTapEmpty and a same-word re-hover toggles the
        // selection off. Forward the whole arguments object.
        expect(
          html,
          contains('origSelectText.apply(window.fushiSelection, arguments)'),
        );
        // The broken 3-arg forwarding must be gone.
        expect(
          html,
          isNot(
            contains(
              'origSelectText.call(window.fushiSelection, x, y, maxLen)',
            ),
          ),
        );
      });
    });

    // BUG-852: 听力沉浸模糊只盖 .cue.current，前后文（.cue.near-* 与远处 .cue）照样
    // 清晰可读、可预读，沉浸失效。修复=把 blur 门控从 .cue.current 放宽到整个 .cue，
    // 逐句 hover / 点击（.revealed）才显形，与视频字幕整篇遮罩语义一致。
    group('BUG-852 listening blur hides all cues (not just current)', () {
      String buildBlurHtml() => LyricsModeHtml.generate(
        cues: <AudioCue>[_cue(0), _cue(1), _cue(2), _cue(3), _cue(4)],
        currentIndex: 2,
        backgroundColor: 'rgba(255,255,255,1.00)',
        textColor: 'rgba(0,0,0,1.00)',
        accentColor: 'rgba(255,220,0,1.00)',
        fontSize: 20,
        blur: true,
      );

      test('blur filter is gated on all .cue, not .cue.current only', () {
        final String html = buildBlurHtml();

        // The blur must be applied through `body.lyrics-blur .cue { ... }` so it
        // covers the current cue AND all preceding/following cues.
        final String blurRule = _cssBlock(html, 'body.lyrics-blur .cue {');
        expect(blurRule, contains('filter: blur(8px)'));

        // Regression guard: the blur must NOT be re-narrowed to only the current
        // cue — that was the bug (前后文暴露).
        expect(html, isNot(contains('body.lyrics-blur .cue.current {')));
        expect(html, isNot(contains('body.lyrics-blur .cue.current:hover')));
      });

      test(
        'any cue reveals (unblurs) on hover or .revealed, not current-only',
        () {
          final String html = buildBlurHtml();

          // Reveal selectors must match any cue, so tapping/hovering a non-current
          // (前后文) line unblurs it just like the current line.
          expect(html, contains('body.lyrics-blur .cue:hover'));
          expect(html, contains('body.lyrics-blur .cue.revealed'));
        },
      );

      test('runtime blur toggle still only flips the body class', () {
        final String html = buildBlurHtml();
        // The live toggle drives blur purely via the body.lyrics-blur class, so
        // the broadened CSS selector governs which cues blur — no per-cue JS.
        expect(html, contains("document.body.classList.add('lyrics-blur')"));
        expect(html, contains("document.body.classList.remove('lyrics-blur')"));
      });
    });
  });
}

/// Returns the body of the first CSS rule whose declaration starts with
/// [selectorWithBrace] (e.g. `.cue {`), i.e. the text between `{` and `}`.
String _cssBlock(String css, String selectorWithBrace) {
  final int start = css.indexOf(selectorWithBrace);
  expect(start, isNonNegative, reason: 'missing rule: $selectorWithBrace');
  final int open = css.indexOf('{', start);
  final int close = css.indexOf('}', open);
  expect(close, isNonNegative, reason: 'unterminated rule: $selectorWithBrace');
  return css.substring(open + 1, close);
}

/// Returns the source of a JS function assignment starting at [signature]
/// (e.g. `window.__lyricsUpdateStyle = function`), spanning from its opening
/// brace to the matching closing brace via depth counting.
String _fnBody(String src, String signature) {
  final int start = src.indexOf(signature);
  expect(start, isNonNegative, reason: 'missing fn: $signature');
  final int open = src.indexOf('{', start);
  int depth = 0;
  for (int i = open; i < src.length; i++) {
    final String ch = src[i];
    if (ch == '{') depth++;
    if (ch == '}') {
      depth--;
      if (depth == 0) return src.substring(open + 1, i);
    }
  }
  fail('unterminated fn: $signature');
}

/// `(args) { body }` of a JS function declaration starting at [signature].
String _fnSource(String src, String signature) {
  final int start = src.indexOf(signature);
  expect(start, isNonNegative, reason: 'missing fn: $signature');
  final int open = src.indexOf('{', start);
  final String args = src.substring(start + signature.length, open);
  return '$args{${_fnBody(src.substring(start), signature)}}';
}

String? _resolveNode() {
  final String exe = Platform.isWindows ? 'node.exe' : 'node';
  final List<String> dirs = <String>[
    ...(Platform.environment['PATH'] ?? '').split(
      Platform.isWindows ? ';' : ':',
    ),
    '/opt/homebrew/bin',
    '/usr/local/bin',
  ];
  for (final String d in dirs) {
    if (d.isEmpty) continue;
    final File f = File('$d${Platform.pathSeparator}$exe');
    if (f.existsSync()) return f.path;
  }
  return null;
}

/// 从 0 起分别逼近 -300 / +300（60Hz 帧）：每帧都更靠近、从不越过，1 秒内精确
/// 落位，第一帧就有明显位移（不是迟滞）；同一时刻 120Hz 与 60Hz 走过的距离几乎
/// 相同（缓动按真实时间、与刷新率无关）；一格（100px）在 80ms 后仍未停稳——
/// 相邻两格的间隔里不会停顿，连续滚动是一段不停的滑行（「无极」）。
const String _wheelHarness = r"""
var TAU = 90;
var ok = 0;
[-300, 300].forEach(function(target) {
  var cur = 0, frames = 0, prevGap = Math.abs(target);
  while (cur !== target) {
    var next = __lyricsWheelStep(cur, target, 1000 / 60, TAU);
    var gap = Math.abs(target - next);
    if (gap >= prevGap) throw new Error('not converging ' + next);
    if ((target - next) * target < 0) throw new Error('overshoot ' + next);
    if (frames === 0 && Math.abs(next) < 20) throw new Error('sluggish ' + next);
    prevGap = gap; cur = next;
    if (++frames > 60) throw new Error('too slow ' + cur);
  }
  ok++;
});
function after(ms, hz, target) {
  var cur = 0, t = 0;
  while (t + 1e-9 < ms) {
    cur = __lyricsWheelStep(cur, target, 1000 / hz, TAU);
    t += 1000 / hz;
  }
  return cur;
}
if (Math.abs(after(100, 60, 300) - after(100, 120, 300)) > 3) {
  throw new Error('rate dependent');
}
var notch = after(80, 60, 100);
if (notch >= 99) throw new Error('settles between notches ' + notch);
console.log('WHEEL_OK ' + ok);
""";

/// Simulated vertical-rl scroller: `moved` = how far the viewport has travelled
/// left from the start (the first cue sits at the right edge). Each convention
/// maps `moved` <-> scrollLeft differently; the page only ever does
/// `scrollLeft += delta`, so both must land the cue on the viewport centre.
const String _centerHarness = r"""
var viewW = 1000, viewH = 700, max = 6000;
var conventions = {
  specNegative: { toS: function(m) { return -m; }, toM: function(s) { return -s; } },
  legacyPositive: { toS: function(m) { return max - m; }, toM: function(s) { return max - s; } },
};
var ok = 0;
for (var name in conventions) {
  var c = conventions[name];
  // A cue 40px wide whose right edge is 2300px left of the content's right edge.
  var elRight = 2300, elW = 40;
  [0, 1500].forEach(function(startMoved) {
    var s = c.toS(startMoved);
    function rect() {
      var left = viewW - elRight - elW + c.toM(s);
      return { left: left, width: elW, top: 0, height: 300 };
    }
    s += __lyricsCenterDeltaFor(rect(), viewW, viewH, true, 0.46);
    var r = rect();
    var off = r.left + r.width / 2 - viewW / 2;
    if (Math.abs(off) > 0.5) throw new Error(name + ' off by ' + off);
    // Wheel down (deltaY > 0) => scrollLeft -= px => viewport moves on (left).
    var before = c.toM(s);
    s -= 120;
    if (!(c.toM(s) > before)) throw new Error(name + ' wheel went backwards');
    ok++;
  });
}
// Horizontal pages still anchor on the theme's anchorY.
var d = __lyricsCenterDeltaFor({ left: 0, width: 10, top: 500, height: 100 }, viewW, viewH, false, 0.5);
if (d !== 200) throw new Error('horizontal anchor ' + d);
console.log('CENTER_OK ' + ok);
""";

/// 假 DOM：写 style 置脏，脏状态下读 offset* 记一次强制同步布局（与浏览器同义）。
const String _fitHarnessPrelude = r"""
var window = { innerWidth: 0, innerHeight: 0 };
var layouts = 0, dirty = true, writes = 0, scrolls = 0;
function makeCue(extent) {
  var style = {}, fs = '';
  Object.defineProperty(style, 'fontSize', {
    get: function() { return fs; },
    set: function(v) { fs = v; dirty = true; writes++; },
  });
  function read() { if (dirty) { layouts++; dirty = false; } return extent; }
  return {
    style: style,
    get offsetHeight() { return read(); },
    get offsetWidth() { return read(); },
  };
}
var _cues = [];
for (var k = 0; k < 600; k++) _cues.push(makeCue(k % 3 === 0 ? 900 : 300));
var __lyricsVertical = true;
var __LYRICS_MIN_FONT_PX = 12;
var _currentIdx = 5;
var document = { getElementById: function() { return {}; } };
function _lyricsBaseFontPx() { return 24; }
function _lyricsAvailExtent() { return Math.max(1, window.innerHeight - 40); }
function _lyricsCenterDelta(el) { return 10; }
function _lyricsScrollByAxis(d) { scrolls++; }
// 逐字扫过层在 fit 末尾按此刻进度重搭一次；这里只计数，不计入 fit 自身的强制布局次数。
var sweeps = 0;
function _lySweepRelayout() { sweeps++; }
var _lyInitPending = true;
""";

const String _fitHarness = r"""
// 零视口：不量、不写、不定位。
__lyricsFitCues();
_lyInitialPosition();
if (layouts !== 0 || writes !== 0) throw new Error('zero viewport measured: layouts=' + layouts + ' writes=' + writes);
if (scrolls !== 0) throw new Error('zero viewport positioned');
// 真实视口到达（resize）：600 句只允许常数次强制布局。
window.innerWidth = 402; window.innerHeight = 471;
__lyricsFitCues();
_lyInitialPosition();
if (layouts > 2) throw new Error('per-cue forced layouts: ' + layouts);
// 900 > avail(431) 的句子被缩小，300 的保持基准。
if (_cues[0].style.fontSize === '' || _cues[1].style.fontSize !== '') throw new Error('fit result wrong');
if (scrolls !== 1) throw new Error('initial position count ' + scrolls);
// 之后的 resize 不再重复初始定位。
_lyInitialPosition();
if (scrolls !== 1) throw new Error('initial position repeated');
console.log('FIT_OK layouts=' + layouts);
""";

AudioCue _cue(int index) {
  return AudioCue()
    ..id = index + 1
    ..bookKey = 'book'
    ..chapterHref = 'chapter'
    ..sentenceIndex = index
    ..textFragmentId = ''
    ..text = 'cue $index'
    ..startMs = index * 1000
    ..endMs = index * 1000 + 500
    ..audioFileIndex = 0;
}

import 'dart:io';
import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_engine_config.dart';
import 'package:fushi/src/reader/reader_host_hover_lookup.dart';

import '../pages/reader_fushi_page_source_corpus.dart';

/// BUG-2508：macOS 阅读器 Shift 悬停查词无反应。
///
/// 阅读器悬停查词此前只有 WebView 文档内的 JS `mousemove` 一条腿；WebKit 只在
/// AppKit 命中测试判定 WKWebView 为最顶视图时才把 mouseMoved 交给页面，而 Flutter
/// macOS 嵌入层把平台视图之上的任何 Flutter 绘制都写进 `_hitTestIgnoreRegion`
/// （BUG-1692 同机制）——那条腿在 macOS 上收不到事件。修复给宿主（Flutter）补一条腿，
/// 两条腿按 `hostOwnsWebViewHoverLookup`（只有 macOS）互斥；Windows / Android / iOS / Linux 维持 JS 腿。
///
/// 第一组是宿主腿门控/节流的纯行为测试；第二组是接线守卫：reader 页含真实
/// `InAppWebView` 平台视图，无法在 widget 测试里驱动 hover / keydown 到 JS，故按
/// 源扫描钉住（与 BUG-880 视频页守卫同范式）。
void main() {
  group('ReaderHostHoverLookupGate', () {
    test('门关着（无 Shift 且未开悬停即查词）不触发并复位锚点', () {
      final ReaderHostHoverLookupGate gate = ReaderHostHoverLookupGate();
      expect(
        gate.shouldLookup(
          const Offset(100, 100),
          shiftPressed: true,
          hoverAutoLookup: false,
        ),
        isTrue,
      );
      // 松开 Shift：不触发，且锚点复位——再按住 Shift 回到同一点也要立即触发。
      expect(
        gate.shouldLookup(
          const Offset(100, 100),
          shiftPressed: false,
          hoverAutoLookup: false,
        ),
        isFalse,
      );
      expect(
        gate.shouldLookup(
          const Offset(100, 100),
          shiftPressed: true,
          hoverAutoLookup: false,
        ),
        isTrue,
        reason: '未触发分支必须复位锚点，否则重新按 Shift 进入时被 8px 阈值吃掉',
      );
    });

    test('「悬停即查词」开着时不要求 Shift', () {
      final ReaderHostHoverLookupGate gate = ReaderHostHoverLookupGate();
      expect(
        gate.shouldLookup(
          const Offset(10, 10),
          shiftPressed: false,
          hoverAutoLookup: true,
        ),
        isTrue,
      );
    });

    test('8px 内的移动不重复触发，越过阈值才再查（与 JS 腿 dx²+dy²<64 同阈值）', () {
      final ReaderHostHoverLookupGate gate = ReaderHostHoverLookupGate();
      expect(
        gate.shouldLookup(
          const Offset(100, 100),
          shiftPressed: true,
          hoverAutoLookup: false,
        ),
        isTrue,
      );
      // 7.9px 斜移：dx²+dy² < 64。
      expect(
        gate.shouldLookup(
          const Offset(105, 105),
          shiftPressed: true,
          hoverAutoLookup: false,
        ),
        isFalse,
      );
      // 锚点没动，累计到 8px 即触发。
      expect(
        gate.shouldLookup(
          const Offset(108, 100),
          shiftPressed: true,
          hoverAutoLookup: false,
        ),
        isTrue,
      );
      expect(ReaderHostHoverLookupGate.thresholdPx, 8);
    });

    test('markLookedUp 把锚点钉到 Shift 按下处，紧随的抖动不再查', () {
      final ReaderHostHoverLookupGate gate = ReaderHostHoverLookupGate();
      gate.markLookedUp(const Offset(50, 50));
      expect(
        gate.shouldLookup(
          const Offset(53, 51),
          shiftPressed: true,
          hoverAutoLookup: false,
        ),
        isFalse,
      );
      gate.reset();
      expect(
        gate.shouldLookup(
          const Offset(53, 51),
          shiftPressed: true,
          hoverAutoLookup: false,
        ),
        isTrue,
      );
    });

    test('盒内判定：负坐标与超出尺寸都算盒外', () {
      const Size box = Size(200, 100);
      expect(readerHostHoverPointInside(const Offset(0, 0), box), isTrue);
      expect(
        readerHostHoverPointInside(const Offset(199.9, 99.9), box),
        isTrue,
      );
      expect(readerHostHoverPointInside(const Offset(-1, 10), box), isFalse);
      expect(readerHostHoverPointInside(const Offset(10, -1), box), isFalse);
      expect(readerHostHoverPointInside(const Offset(200, 10), box), isFalse);
      expect(readerHostHoverPointInside(const Offset(10, 100), box), isFalse);
    });
  });

  group('ReaderEngineConfig.hostHoverLookup', () {
    test('默认 false（JS 腿维持），序列化进 JS 配置', () {
      const ReaderEngineConfig config = ReaderEngineConfig(
        navigationGeneration: 1,
        continuousMode: false,
        vnMode: false,
        vnClickAdvance: false,
        scanNonJapaneseText: false,
        hoverAutoLookup: false,
        highlightOnTap: true,
        showChrome: true,
        debugLogging: false,
        swipeDistThreshold: 44,
        swipeFastDistThreshold: 22,
        wheelGestureQuietMs: 450,
        furiganaMode: 'toggle',
        caretColor: 'rgba(0,0,0,0.5)',
        caretInsetTop: 0,
        caretInsetBottom: 0,
        initialProgress: 0,
        initialCharOffset: -1,
        initialCharOffsetEnd: -1,
        initialFragment: null,
        chromeTopInset: 0,
        chromeBottomInset: 0,
        dartPageWidth: 800,
        dartPageHeight: 600,
        marginTop: 0,
        marginBottom: 0,
        marginLeft: 0,
        marginRight: 0,
        blurImages: false,
        revealedKeys: <String>[],
        perfTraceEnabled: false,
        vnRevealSpeed: 0,
        vnScreenMode: 'block',
        vnSentencesPerScreen: 1,
        vnPreserveDialogue: false,
        vnMergeCrossScreenSentenceAudioCues: false,
        sentenceAudioCuesJson: null,
      );
      expect(config.hostHoverLookup, isFalse);
      expect(config.toJson()['hostHoverLookup'], isFalse);
    });
  });

  group('BUG-2508 接线守卫', () {
    final String src = readReaderPageSource();
    final String js = File(
      'lib/src/pages/implementations/reader_fushi/webview.part.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final String lyrics = File(
      'lib/src/media/audiobook/lyrics_mode_html.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');

    test('只在宿主腿平台把正文 WebView 紧包 MouseRegion，且不改命中（opaque: false）', () {
      expect(
        RegExp(
          r'KeyedSubtree\(\s*key:\s*_webViewKey,\s*'
          r'child:\s*hostOwnsWebViewHoverLookup\s*\?\s*MouseRegion\('
          r'[\s\S]{0,200}?opaque:\s*false[\s\S]{0,200}?'
          r'onHover:\s*_handleWebViewHostHover[\s\S]{0,120}?'
          r'onExit:\s*_handleWebViewHostHoverExit[\s\S]{0,120}?'
          r'\)\s*:\s*webView,',
        ).hasMatch(src),
        isTrue,
        reason:
            '宿主腿必须挂在 WebView 自己的盒上（localPosition == CSS 视口坐标），'
            'opaque:false 不得改变弹窗 barrier / chrome 的命中；非宿主腿平台'
            '（Windows / Android / iOS / Linux）不装、连位置都不记',
      );
    });

    test('宿主腿平台判据只有 macOS，不借 !hostOwnsWebViewPointerInput 反推', () {
      final String bridge = File(
        'lib/src/focus/webview_key_bridge.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      expect(
        bridge.contains(
          'bool get hostOwnsWebViewHoverLookup => isMacOSPlatform;',
        ),
        isTrue,
        reason:
            '根因（WKMouseTrackingObserver 命中测试门）只在 macOS 定性；'
            'Android（DeX / 外接鼠标）/ iOS / Linux 的 JS 腿此前能用，'
            '宿主 hover 在 hybrid composition 下未验证，不能顺带关掉它们唯一的一条腿',
      );
      for (final String file in <String>[
        'lib/src/pages/implementations/reader_fushi/webview.part.dart',
        'lib/src/pages/implementations/reader_fushi_page.dart',
      ]) {
        expect(
          File(
            file,
          ).readAsStringSync().contains('!hostOwnsWebViewPointerInput'),
          isFalse,
          reason: '$file：悬停腿的分工不得用鼠标按下所有权的反面来推',
        );
      }
    });

    test('宿主腿与 JS 腿按 hostOwnsWebViewHoverLookup 互斥（一平台一条腿）', () {
      // Flutter 腿：只在宿主腿平台装配，装了就查词，方法体内不再有平台分支。
      expect(
        RegExp(
          r'void _handleWebViewHostHover\(PointerHoverEvent event\)[\s\S]*?'
          r'_lastWebViewHoverLocal = local;\s*'
          r'_hostHoverLookupAt\(local\);',
        ).hasMatch(src),
        isTrue,
      );
      // JS 腿：宿主接管时文档内 mousemove 让路。
      expect(
        js.contains('hostHoverLookup: hostOwnsWebViewHoverLookup,'),
        isTrue,
        reason: '引擎配置必须把「宿主腿是否接管」下发给文档，判据与 MouseRegion 同一个',
      );
      expect(
        js.contains('window.__fushiHostHoverLookup = C.hostHoverLookup;'),
        isTrue,
      );
      expect(
        RegExp(
          r"document\.addEventListener\('mousemove', function\(e\) \{\s*"
          r'(?://[^\n]*\n\s*)*if \(window\.__fushiHostHoverLookup\) return;',
        ).hasMatch(js),
        isTrue,
        reason: '正文 mousemove 腿必须在入口按 __fushiHostHoverLookup 让路',
      );
      expect(
        RegExp(
          r"document\.addEventListener\('mousemove', function\(e\) \{\s*"
          r'(?://[^\n]*\n\s*)*if \(window\.__fushiHostHoverLookup\) return;',
        ).hasMatch(lyrics),
        isTrue,
        reason: '歌词页是独立文档，它的 mousemove 腿同样要让路',
      );
      // 歌词页不经 setup 脚本：开关随 __hoverAutoLookup 一起 live 下发。
      expect(
        RegExp(
          r"'window\.__hoverAutoLookup = \$enabled;'\s*"
          r"'window\.__fushiHostHoverLookup = \$hostHover;'",
        ).hasMatch(src),
        isTrue,
      );
    });

    test('barrier 与正文两个 hover 入口共用同一把门控/节流', () {
      expect(
        RegExp(
          r'void onDismissBarrierHover\(PointerHoverEvent event\)[\s\S]*?'
          r'_lastWebViewHoverLocal = local;\s*_hostHoverLookupAt\(local\);',
        ).hasMatch(src),
        isTrue,
      );
      expect(
        RegExp(
          r'void _hostHoverLookupAt\(Offset local\)[\s\S]*?'
          r'_hostHoverGate\.shouldLookup\([\s\S]*?'
          r'shiftPressed:\s*HardwareKeyboard\.instance\.isShiftPressed[\s\S]*?'
          r'hoverAutoLookup:\s*ReaderFushiSource\.instance\.hoverAutoLookup[\s\S]*?'
          r'_selectTextAt\(local\.dx, local\.dy, fromHover: true\);',
        ).hasMatch(src),
        isTrue,
        reason: '宿主腿语义须与 JS 腿一致：Shift 或悬停即查词开着才触发，且走 fromHover 路径',
      );
    });

    test('Shift 按下在最后指针位置直接查词（静止光标，对齐视频页 BUG-880）', () {
      expect(
        RegExp(
          r'KeyEventResult _handleKeyEvent\(FocusNode node, KeyEvent event\) \{'
          r'[\s\S]{0,900}?event is KeyDownEvent[\s\S]*?'
          r'LogicalKeyboardKey\.shiftLeft[\s\S]*?'
          r'LogicalKeyboardKey\.shiftRight[\s\S]*?'
          r'focusedEditableText\(\) == null[\s\S]*?'
          r'_triggerShiftLookupAtLastPointer\(\);',
        ).hasMatch(src),
        isTrue,
        reason:
            'Shift keydown 必须在按键处理入口处（任何 handled 分支之前）触发反查、'
            '不消费按键，且文本框聚焦时放行（打大写字母不是查词）',
      );
      expect(
        RegExp(
          r'void _triggerShiftLookupAtLastPointer\(\) \{\s*'
          r'if \(!hostOwnsWebViewHoverLookup\) return;\s*'
          r'if \(_focusNavEnabled && _caretActive\) return;\s*'
          r'final Offset\? local = _lastWebViewHoverLocal;\s*'
          r'if \(local == null\) return;\s*'
          r'_hostHoverGate\.markLookedUp\(local\);\s*'
          r'_selectTextAt\(local\.dx, local\.dy, fromHover: true\);',
        ).hasMatch(src),
        isTrue,
        reason:
            'Shift 反查两道门缺一不可：非宿主腿平台（Windows）按 Shift+方向 / '
            'Shift+滚轮 / 任何含 Shift 的快捷键不得被宿主抹掉现有选区（JS selectText '
            '命中空白 clearSelection、命中别的词换词）；光标模式下 Shift+方向是键盘'
            '扩选，按下沿正是扩选起点。反查后必须推进节流锚，否则紧随的微小抖动会'
            '再查一次同一处',
      );
    });

    test('指针离开正文才清最后位置；弹窗 barrier 接管引起的 exit 不算离开', () {
      expect(
        RegExp(
          r'void _handleWebViewHostHoverExit\(PointerExitEvent event\) \{\s*'
          r'if \(isDictionaryShown\) return;\s*'
          r'_lastWebViewHoverLocal = null;\s*_hostHoverGate\.reset\(\);',
        ).hasMatch(src),
        isTrue,
      );
    });
  });
}

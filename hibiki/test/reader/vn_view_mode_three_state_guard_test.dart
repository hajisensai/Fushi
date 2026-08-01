import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';
import '../helpers/source_guard.dart';

/// TODO-909 源码守卫（源码扫描，沿用仓库既有 `File(...).readAsStringSync()` +
/// `contains` 模式）。
///
/// VN 是书籍「第三种 view-mode」（与 `'paginated'` / `'continuous'` 并列）。最大
/// 结构风险是「二元假设污染三元」：现有大量代码用二元谓词 `isContinuousMode`
/// （`viewMode == 'continuous'`）把模式一分为二，VN 接入后若哪里漏判，VN 会被
/// 当成 paginated 静默走错分支（例如吃分页 column 几何，与 VN 独立 stage 打架）。
///
/// 本守卫锁住三态接入的「权威分流点」都在位、且没有人新增绕过 `viewMode` 的裸
/// `== 'continuous'` 二分。headless WebView 在 CI 跑不到，真机行为留真机 Gate；
/// 本守卫只锁源码结构不回退。
void main() {
  late String settings;
  late String styles;
  late String schema;
  late String webview;
  late String vnScripts;

  setUpAll(() {
    settings = File('lib/src/reader/reader_settings.dart').readAsStringSync();
    styles = File(
      'lib/src/reader/reader_content_styles.dart',
    ).readAsStringSync();
    schema = File(
      'lib/src/settings/settings_schema_reading.dart',
    ).readAsStringSync();
    webview = File(
      'lib/src/pages/implementations/reader_hibiki/webview.part.dart',
    ).readAsStringSync();
    vnScripts = File(
      'lib/src/reader/reader_visual_novel_scripts.dart',
    ).readAsStringSync();
  });

  group('TODO-909 VN view-mode three-state guard', () {
    test('reader_settings exposes the strict three-state discriminator', () {
      expect(
        settings.contains(
          "bool get isContinuousMode => viewMode == 'continuous';",
        ),
        isTrue,
        reason: 'isContinuousMode must remain strict viewMode == continuous',
      );
      expect(
        settings.contains("bool get isVnMode => viewMode == 'vn';"),
        isTrue,
        reason: 'VN third-state discriminator isVnMode must exist',
      );
    });

    test(
      'the only authoritative viewMode == continuous comparison is the '
      'isContinuousMode getter',
      () {
        final String code = _stripLineComments(settings);
        expect(
          "viewMode == 'continuous'".allMatches(code).length,
          1,
          reason: 'view-mode must funnel through isContinuousMode / isVnMode, '
              'not scattered bare == continuous comparisons',
        );
        expect(
          "viewMode == 'vn'".allMatches(code).length,
          1,
          reason: 'VN mode must funnel through isVnMode',
        );
      },
    );

    test(
      'the engine routes VN before the paginated/continuous branches '
      '(BUG-1140 第二阶段①：分流从 Dart 注入期搬到 JS 运行时)',
      () {
        // 改动前：Dart 的 shellScript 按 vnMode/continuousMode 三选一**插值**出一份
        // shell。现在 Dart 只决定嵌哪一份 shell，运行时分流点是引擎里的
        // window.__hoshiInstallShell（读 C）—— 判据与顺序必须逐条保留。
        final String engine = ReaderPaginationScripts.engineShell(
            vnMode: true, continuousMode: false);
        final int vnIdx = engine.indexOf('if (C.vnMode)');
        final int contIdx = engine.indexOf('if (C.continuousMode)');
        expect(vnIdx, isNonNegative, reason: 'engine must branch on C.vnMode');
        expect(contIdx, isNonNegative,
            reason: 'engine must branch on C.continuousMode');
        expect(vnIdx < contIdx, isTrue,
            reason: 'vnMode branch must precede continuousMode branch');
        expect(
          engine.contains('window.__hoshiShells.vn = function(C)'),
          isTrue,
          reason: 'the VN engine must carry the VN shell installer',
        );
        // Dart 侧只按 view-mode 选嵌哪一份 shell（memoize 的 key），运行时分流仍读
        // C —— 不得回到「把 progress / charOffset 之类 per-nav 值插进 shell」的老路。
        expect(
          _stripLineComments(webview)
              .contains('ReaderPaginationScripts.engineShell('),
          isTrue,
          reason: 'webview must build the engine through engineShell(mode)',
        );
      },
    );

    test(
      'content_styles selects a dedicated VN stage layout (not the paginated '
      'column geometry)',
      () {
        final String code = _stripLineComments(styles);
        expect(
          code.contains('settings.isVnMode'),
          isTrue,
          reason: 'layout selection must branch on isVnMode',
        );
        expect(
          code.contains('_vnLayoutCss('),
          isTrue,
          reason: 'VN must use _vnLayoutCss, not _paginatedLayoutCss',
        );
        final int vnIdx = code.indexOf('settings.isVnMode');
        final int contIdx = code.indexOf('settings.isContinuousMode');
        expect(
          vnIdx >= 0 && contIdx >= 0 && vnIdx < contIdx,
          isTrue,
          reason: 'isVnMode must be checked before isContinuousMode',
        );
        for (final String cls in <String>[
          '.hoshi-vn-stage',
          '.hoshi-vn-screen',
          '.hoshi-vn-content',
          '[data-hoshi-visual-novel-unrevealed]',
        ]) {
          expect(
            styles.contains(cls),
            isTrue,
            reason: 'VN stage CSS must define $cls',
          );
        }
      },
    );

    test(
      'TODO-958: _vnLayoutCss centres VN content (no hardcoded width:100%) and '
      'branches on isVertical',
      () {
        final String body = _extractVnLayoutCssBody(styles);
        // The function must actually consume its isVertical parameter so the
        // axis (main vs cross) is taken into account, not ignored as before.
        expect(
          body.contains('isVertical'),
          isTrue,
          reason: '_vnLayoutCss must reference isVertical for axis-aware '
              'centering, not ignore it',
        );
        // The .hoshi-vn-content block must no longer force a physical full
        // width — that filled the main axis and defeated justify-content:center
        // (台词贴最右). It must constrain with max-width instead. (Note:
        // .hoshi-vn-screen legitimately keeps width: 100%, so scope the check
        // to the vn-content block only.)
        final String contentBlock = _extractCssBlock(body, '.hoshi-vn-content');
        // Match a *declaration line* of plain `width: 100%` (not `max-width`,
        // and not the explanatory comment text), so the guard is robust against
        // the substring overlap with `max-width: 100% !important;`.
        final RegExp plainWidthDecl =
            RegExp(r'(^|[;{\s])width:\s*100%\s*!important;', multiLine: true);
        expect(
          plainWidthDecl.hasMatch(contentBlock),
          isFalse,
          reason: '_vnLayoutCss must not hardcode width: 100% on vn-content; '
              'that breaks vertical-rl centering',
        );
        expect(
          contentBlock.contains('max-width: 100% !important;'),
          isTrue,
          reason: 'vn-content must use max-width so flex centring works',
        );
      },
    );

    test(
      'webview passes vnMode + VN config into the shell and binds the M0 '
      'blank-tap advance',
      () {
        expect(
          webview.contains('final bool vnMode = s.isVnMode;'),
          isTrue,
          reason: 'webview must derive VN mode from view-mode',
        );
        expect(
          webview.contains('vnMode: vnMode,'),
          isTrue,
          reason: 'VN mode must reach the engine through ReaderEngineConfig',
        );
        // TODO-909 M0: reveal 渐显是 M1 功能。M0 强制 vnRevealSpeed=0，避免新屏停在
        // revealComplete=false 时 forward 翻屏命中 paginate 的 "revealed" 分支，与
        // Dart 端只认 "scrolled" 的 _didScroll 撞车而误跨章。
        expect(
          webview.contains('const int vnRevealSpeedM0ForceZero = 0;'),
          isTrue,
          reason: 'M0 must define the reveal-speed force-zero constant',
        );

        expect(
          webview.contains(
            'vnRevealSpeed: vnMode ? vnRevealSpeedM0ForceZero : 0,',
          ),
          isTrue,
          reason: 'webview must forward the M0-forced reveal speed into config',
        );
        // M0 must NOT wire the live setting through (that is the M1 default 45).
        expect(
          _stripLineComments(webview)
              .contains('vnRevealSpeed: s.visualNovelRevealSpeed'),
          isFalse,
          reason: 'M0 must not pass the live reveal-speed setting to the shell',
        );
        // BUG-1195: blank-tap 不再由 JS 自己 paginate（那会吃掉唯一能唤出控制栏的
        // 手势）。JS 只回传事实，翻页/唤栏由 Dart 判——详见
        // vn_blank_tap_chrome_reveal_bug1195_test.dart。
        expect(
          webview.contains("callHandler('onVnBlankTap')"),
          isTrue,
          reason: 'VN blank-tap must be routed to Dart, not paginated in JS',
        );
        expect(
          webview.contains('hoshiVnClickAdvance'),
          isTrue,
          reason: 'VN click-advance flag must be injected',
        );
      },
    );

    test('settings schema exposes the VN third option', () {
      expect(
        schema.contains("value: 'vn'"),
        isTrue,
        reason: 'view-mode segmented control must offer the VN option',
      );
      expect(
        schema.contains('t.ttu_vn'),
        isTrue,
        reason: 'VN option must use the ttu_vn i18n label',
      );
    });

    test(
      'VN scripts install the three injected dependencies and the Hibiki '
      'restore bridge',
      () {
        for (final String dep in <String>[
          'global.hoshiReaderTextSemantics',
          'global.hoshiReaderVnContentStream',
          'global.hoshiReaderVnRangeMap',
          'global.hoshiReaderMediaSemantics',
        ]) {
          expect(
            vnScripts.contains(dep),
            isTrue,
            reason: 'VN shell must inline $dep',
          );
        }
        expect(
          _hasGenerationAwareRestoreCall(vnScripts),
          isTrue,
          reason: 'VN restore must forward handler + perf placeholder + the '
              'document navigation generation',
        );
        // The live native bridge CALL must be gone (the bridge name may still
        // appear in explanatory comments, so scan comment-stripped code).
        expect(
          _stripLineComments(vnScripts)
              .contains('window.HoshiReaderRestore.postMessage('),
          isFalse,
          reason: 'VN must not keep hoshi native restore bridge call',
        );
        expect(
          vnScripts.contains('restoreToCharOffset'),
          isTrue,
          reason: 'VN must support char-offset restore',
        );
        expect(
          vnScripts.contains('screenContainsCharOffset'),
          isTrue,
          reason: 'char-offset restore must use screenContainsCharOffset',
        );
      },
    );
  });
}

/// 提取 `_vnLayoutCss(...) { ... }` 整个函数体（从签名到匹配的右花括号），
/// 用花括号配平避免误截其它函数。
String _extractVnLayoutCssBody(String source) {
  final int sigIdx = source.indexOf('static String _vnLayoutCss(');
  expect(sigIdx >= 0, isTrue, reason: '_vnLayoutCss must exist');
  // 清理 wave2 后签名收敛为单个 record 参数 `(_LayoutCssArgs a) {`（原为
  // `{required ...}` 命名参数表结尾 `}) {`）。两种形状统一按「签名后第一个
  // `) {` 的花括号」定位方法体开括号，不变量（函数体消费 isVertical、
  // vn-content 用 max-width）不受签名形状影响。
  final int paramsEndIdx = source.indexOf(') {', sigIdx);
  expect(paramsEndIdx >= 0, isTrue, reason: '_vnLayoutCss must have a body');
  final int braceIdx = source.indexOf('{', paramsEndIdx + 1);
  expect(braceIdx >= 0, isTrue, reason: '_vnLayoutCss must have a body brace');
  int depth = 0;
  for (int i = braceIdx; i < source.length; i++) {
    final String ch = source[i];
    if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) {
        return source.substring(braceIdx, i + 1);
      }
    }
  }
  fail('_vnLayoutCss body braces are unbalanced');
}

/// 从一段 CSS 文本里提取以 `selector {` 开头的规则块（含选择器到 `}`）。
String _extractCssBlock(String css, String selector) {
  final int selIdx = css.indexOf(selector);
  expect(selIdx >= 0, isTrue, reason: 'CSS must contain $selector block');
  final int braceIdx = css.indexOf('{', selIdx);
  final int endIdx = css.indexOf('}', braceIdx);
  expect(
    braceIdx >= 0 && endIdx >= 0,
    isTrue,
    reason: '$selector block must be well-formed',
  );
  return css.substring(selIdx, endIdx + 1);
}

String _stripLineComments(String source) => maskCommentsAndScriptLines(source);

bool _hasGenerationAwareRestoreCall(String source) {
  return RegExp(
    r"callHandler\(\s*'onRestoreComplete'\s*,\s*null\s*,\s*"
    r'C\.navigationGeneration\s*\)',
  ).hasMatch(_stripLineComments(source));
}

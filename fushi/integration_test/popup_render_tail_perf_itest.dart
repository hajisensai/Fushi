import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 查词弹窗「渲染尾巴」实测 itest —— **手动探针，不是守卫**。
///
/// 状态要说清楚（此前这份文件长得像守卫，其实两样都不是）：
/// 1. 它**不在任何 runner 清单里**。`ci/integration-test.sh` 的 `ALL_TARGETS` 按
///    `integration_test/<target>_test.dart` 解析目标名，`_itest.dart` 后缀天然进
///    不去——本目录 45 个 `_itest.dart` 全是这样，一律只经
///    `tool/run_windows_itest.ps1` 手动跑。别指望 CI 会跑它。
/// 2. 绝对耗时**不做断言**（机器差异假红）；下面只断言**不依赖机器的比值/计数**，
///    那几条正是「渲染尾巴」这批改动的形态本身：退回旧实现时它们必然不成立。
///    没有这几条的话，本文件跑通只证明「没抛异常」。
///
/// 量的是 popup.js 首词条同步渲染之后那段：余下词条/词典块逐宏任务补建 + masonry
/// 合帧重排 + 高度回报，直到 DOM 与布局都稳定。用户感知就是「弹窗先出来，然后内容
/// 一块块往下掉、卡片跳位、高度反复变」。
///
/// 本测试**不启动 app**（不碰生产数据库），只挂一个 InAppWebView，用与生产 Windows
/// 弹窗同一种 initialData 内联方式装载真 popup.css / dict-media.js / selection.js /
/// popup.js，再灌合成词条（E 词条 × D 词典，结构化释义高度参差以触发 masonry）。
///
/// 输出（grep command.log `[render-tail-perf]`）每个场景一行 JSON：
///   - `completeMs`：renderPopup() 到 `_emitPopupRenderPerf('complete')` 的时长
///   - `settleMs`：到最后一次 requestAnimationFrame 回调 + 静默 300ms 的时长
///   - `raf`：requestAnimationFrame 调度次数（≈ masonry 重排帧数）
///   - `reports`：`popupRendered` 回报次数（宿主每次都要重定尺）
///   - `offsetHeightReads`：卡片高度读取次数（每次紧跟样式写 ⇒ 强制同步布局）
///   - `longTasks` / `longTaskMs`：>50ms 的长任务数与总时长
///   - `layoutShifts` / `layoutShiftScore`：Layout Instability API 计到的位移。注意它
///     **不计 transform 位移**，而 masonry 摆卡片用的正是 translate，所以这两项前后
///     都 ≈0，不能当抖动证据；抖动看 `raf` / `reports`（宿主每次回报都重定尺一次）。
///
/// Run (PowerShell, from fushi/)：
///   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 `
///     -RunId render-tail-01 integration_test/popup_render_tail_perf_itest.dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late String inlineHtml;

  setUpAll(() async {
    final String css = await rootBundle.loadString('assets/popup/popup.css');
    final String dictMediaJs = await rootBundle.loadString(
      'assets/popup/dict-media.js',
    );
    final String selectionJs = await rootBundle.loadString(
      'assets/popup/selection.js',
    );
    final String popupJs = await rootBundle.loadString('assets/popup/popup.js');
    // 与 DictionaryPopupWebViewState._buildInlinePopupHtml 同形（Windows 生产路径）。
    inlineHtml = '<!DOCTYPE html>'
        '<html data-theme="dark" '
        'style="--background-color:#202020;--dict-columns:2">'
        '<head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1.0">'
        '<style>$css</style>'
        '<script>$dictMediaJs</script>'
        '<script>$selectionJs</script>'
        '<script>$popupJs</script>'
        '</head><body>'
        '<div id="entries-container"></div>'
        '<div class="overlay"><div class="overlay-close"></div>'
        '<div class="overlay-title"></div><div class="overlay-content"></div>'
        '</div></body></html>';
  });

  testWidgets(
    'measure popup render tail (deferred blocks + masonry settle)',
    timeout: const Timeout(Duration(minutes: 20)),
    (WidgetTester tester) async {
      final Completer<InAppWebViewController> ready =
          Completer<InAppWebViewController>();
      int popupRenderedCalls = 0;
      // 宿主每次收到的高度；连续相同的高度是「没变也回报」的冗余重定尺。
      final List<num> reportedHeights = <num>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 720,
              height: 900,
              child: InAppWebView(
                initialData: InAppWebViewInitialData(data: inlineHtml),
                initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
                onWebViewCreated: (InAppWebViewController controller) {
                  controller.addJavaScriptHandler(
                    handlerName: 'popupRendered',
                    callback: (List<dynamic> args) {
                      popupRenderedCalls++;
                      final Object? h = args.isNotEmpty ? args[0] : null;
                      reportedHeights.add(h is num ? h : -1);
                      return null;
                    },
                  );
                  controller.addJavaScriptHandler(
                    handlerName: 'duplicateCheck',
                    callback: (List<dynamic> args) => false,
                  );
                  controller.addJavaScriptHandler(
                    handlerName: 'reportJsError',
                    callback: (List<dynamic> args) {
                      debugPrint('[render-tail-perf] jsError: $args');
                      return null;
                    },
                  );
                  controller.addJavaScriptHandler(
                    handlerName: 'tapOutside',
                    callback: (List<dynamic> args) => null,
                  );
                },
                onConsoleMessage: (
                  InAppWebViewController controller,
                  ConsoleMessage message,
                ) {
                  if (message.messageLevel == ConsoleMessageLevel.ERROR) {
                    debugPrint(
                      '[render-tail-perf] console: ${message.message}',
                    );
                  }
                },
                onLoadStop: (InAppWebViewController controller, WebUri? url) {
                  if (!ready.isCompleted) ready.complete(controller);
                },
              ),
            ),
          ),
        ),
      );

      final InAppWebViewController controller = await ready.future.timeout(
        const Duration(seconds: 60),
      );
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      await controller.evaluateJavascript(source: _instrumentationJs);

      const List<({int entries, int dicts})> scenarios =
          <({int entries, int dicts})>[
        (entries: 10, dicts: 5),
        (entries: 30, dicts: 5),
        (entries: 3, dicts: 12),
      ];
      for (final ({int entries, int dicts}) s in scenarios) {
        // 每个场景跑两遍，第一遍暖 JIT / CSS memo，只报第二遍。
        for (int round = 0; round < 2; round++) {
          popupRenderedCalls = 0;
          reportedHeights.clear();
          final String entriesJson = _buildEntriesJson(s.entries, s.dicts);
          final String stylesJson = _buildDictionaryStylesJson(s.dicts);
          await controller.evaluateJavascript(
            source: 'window.__perfBegin($entriesJson, $stylesJson);',
          );
          Map<String, dynamic>? result;
          for (int i = 0; i < 600; i++) {
            await tester.pump(const Duration(milliseconds: 100));
            final Object? raw = await controller.evaluateJavascript(
              source: 'window.__perfPoll()',
            );
            if (raw is String && raw.isNotEmpty) {
              result = jsonDecode(raw) as Map<String, dynamic>;
              break;
            }
          }
          expect(result, isNotNull, reason: 'render tail never settled');
          result!['reports'] = popupRenderedCalls;

          // ── 不依赖机器的形态不变式（绝对耗时仍然只作数据输出）──────────
          final int blocks = s.entries * s.dicts;
          expect(result['cards'], blocks,
              reason: '每个 (词条 × 词典) 必须各成一块：块数对不上说明尾批把词条'
                  '丢了，后面几条比值也就没有意义了');
          if (blocks > s.dicts) {
            // 论点⑤：每词典一份 <style>。退回「每块一份」时 styleElements >= blocks。
            // 这里比的是「样式表数 vs 块数」而不是绝对值——applyCustomCSS 之类
            // 另外插的 <style> 只是常数项，不影响这个数量级判据。
            expect(result['styleElements'] as int, lessThan(blocks),
                reason: '样式表数 ${result['styleElements']} 不该逼近块数 $blocks：'
                    '每个词典块各插一份 <style> 就是被这条钉住的退化形态');
          }
          if (blocks > 2) {
            // 论点①：尾批按时间预算分片，一个宏任务连续建多块。退回「一块一宏
            // 任务」时 tailTasks 恰好等于待建块数。
            expect(result['tailTasks'] as int, lessThan(blocks),
                reason: '尾批宏任务数 ${result['tailTasks']} 不该逼近块数 $blocks：'
                    '一块一任务就是 TAIL_SLICE_BUDGET_MS 失效的形态');
          }
          int distinct = 0;
          num? last;
          for (final num h in reportedHeights) {
            if (h != last) distinct++;
            last = h;
          }
          result['distinctReports'] = distinct;
          result['entries'] = s.entries;
          result['dicts'] = s.dicts;
          result['round'] = round;
          debugPrint('[render-tail-perf] ${jsonEncode(result)}');
        }
      }
    },
  );
}

/// 页面内计量钩子。`__perfBegin(entries)` 起表并 renderPopup；`__perfPoll()` 在终态
/// 阶段已到且最后一次 RAF 之后静默 300ms 时返回 JSON 串，否则返回空串。
const String _instrumentationJs = r'''
(function(){
  const P = window.__perf = {};
  const nativeRaf = window.requestAnimationFrame.bind(window);
  window.requestAnimationFrame = function(cb) {
    P.raf++;
    return nativeRaf(function(ts) { P.lastRaf = performance.now(); cb(ts); });
  };
  // 分段计时：尾批宏任务（纯 DOM 构建）与 masonry（含被迫的样式重算 + 布局）各自的
  // 墙钟时间；剩下的就是帧间等待。popup.js 顶层函数声明是全局对象属性，裸标识符
  // 调用经全局对象解析，故此处替换即生效。
  const origTail = window.scheduleRenderTail;
  window.scheduleRenderTail = function(task) {
    return origTail(function() {
      const s = performance.now();
      try { task(); } finally { P.tailTasks++; P.tailTaskMs += performance.now() - s; }
    });
  };
  const origMasonry = window.layoutMasonry;
  window.layoutMasonry = function(bodies) {
    const s = performance.now();
    try { return origMasonry(bodies); } finally { P.masonryCalls++; P.masonryMs += performance.now() - s; }
  };
  const origCreate = document.createElement.bind(document);
  document.createElement = function(tag, opts) {
    if (String(tag).toLowerCase() === 'style') P.styleElements++;
    return origCreate(tag, opts);
  };
  const hDesc = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'offsetHeight');
  Object.defineProperty(HTMLElement.prototype, 'offsetHeight', {
    configurable: true,
    get() { P.offsetHeightReads++; return hDesc.get.call(this); },
  });
  try {
    new PerformanceObserver(list => {
      for (const e of list.getEntries()) { P.longTasks++; P.longTaskMs += e.duration; }
    }).observe({ type: 'longtask' });
  } catch (_) {}
  try {
    new PerformanceObserver(list => {
      for (const e of list.getEntries()) {
        if (e.hadRecentInput) continue;
        P.layoutShifts++; P.layoutShiftScore += e.value;
      }
    }).observe({ type: 'layout-shift' });
  } catch (_) {}
  window.__fushiOnPopupPerf = function(payload) {
    P.phases.push(Object.assign({ at: +(performance.now() - P.t0).toFixed(1) }, payload));
    if (payload.phase === 'complete' || payload.phase === 'error' || payload.phase === 'cancelled') {
      P.terminalAt = performance.now();
      P.completeMs = +(P.terminalAt - P.t0).toFixed(1);
    }
  };
  window.__perfBegin = function(entries, dictionaryStyles) {
    window.dictionaryStyles = dictionaryStyles || {};
    P.raf = 0; P.lastRaf = 0; P.offsetHeightReads = 0;
    P.longTasks = 0; P.longTaskMs = 0; P.layoutShifts = 0; P.layoutShiftScore = 0;
    P.tailTasks = 0; P.tailTaskMs = 0; P.masonryCalls = 0; P.masonryMs = 0;
    P.styleElements = 0;
    P.phases = []; P.terminalAt = 0; P.completeMs = -1;
    window.lookupEntries = entries;
    window.kanjiResults = [];
    window.scrollTo(0, 0);
    P.t0 = performance.now();
    window.renderPopup();
  };
  window.__perfPoll = function() {
    if (!P.terminalAt) return '';
    const now = performance.now();
    const quietSince = Math.max(P.lastRaf, P.terminalAt);
    if (now - quietSince < 300) return '';
    const cards = document.querySelectorAll('.glossary-group');
    let hidden = 0;
    cards.forEach(c => { if (c.style.visibility === 'hidden') hidden++; });
    return JSON.stringify({
      completeMs: P.completeMs,
      settleMs: +(quietSince - P.t0).toFixed(1),
      raf: P.raf,
      offsetHeightReads: P.offsetHeightReads,
      longTasks: P.longTasks,
      longTaskMs: +P.longTaskMs.toFixed(1),
      layoutShifts: P.layoutShifts,
      layoutShiftScore: +P.layoutShiftScore.toFixed(4),
      tailTasks: P.tailTasks,
      tailTaskMs: +P.tailTaskMs.toFixed(1),
      masonryCalls: P.masonryCalls,
      masonryMs: +P.masonryMs.toFixed(1),
      styleElements: P.styleElements,
      cards: cards.length,
      hiddenCards: hidden,
      masonryBodies: document.querySelectorAll('.category-body[data-masonry-cols]').length,
      scrollHeight: document.documentElement.scrollHeight,
      phases: P.phases.map(p => p.phase + '@' + p.at),
    });
  };
})();
''';

/// 每本词典一份自带 CSS（真实 Yomitan 词典包普遍带几十条规则）。它决定每个词典块
/// 的样式注入代价：constructDictCss 有 memo，但 `<style>` 元素的解析与全文档样式
/// 失效是每次插入都付的。
String _buildDictionaryStylesJson(int dicts) {
  final Map<String, String> styles = <String, String>{};
  for (int d = 0; d < dicts; d++) {
    final StringBuffer css = StringBuffer();
    for (int r = 0; r < 24; r++) {
      css.write(
        '.gloss-$r { color: #${(r * 37 % 256).toRadixString(16).padLeft(2, '0')}'
        '4488; margin: ${r % 3}px 0; }\n',
      );
    }
    css.write('ul[data-sc-content="glossary"] li { line-height: 1.4; }\n');
    css.write('span[data-sc-content="tag"] { font-size: 0.85em; }\n');
    styles['Dict $d'] = css.toString();
  }
  return jsonEncode(styles);
}

/// 合成 E 词条 × D 词典。释义用结构化内容，按 (entry, dict) 变化行数，让 masonry
/// 的列高真的参差（全等高的卡片测不出最短列打包与重排代价）。
String _buildEntriesJson(int entries, int dicts) {
  final List<Map<String, Object?>> out = <Map<String, Object?>>[];
  for (int e = 0; e < entries; e++) {
    final List<Map<String, Object?>> glossaries = <Map<String, Object?>>[];
    for (int d = 0; d < dicts; d++) {
      final int lines = 1 + ((e * 7 + d * 3) % 6);
      final List<Object> items = <Object>[
        for (int i = 0; i < lines; i++)
          <String, Object>{
            'tag': 'li',
            'content': '释义 $i：これはテスト用の語釈です。同じ内容が続きます。'
                'entry=$e dict=$d line=$i',
          },
      ];
      final Map<String, Object> structured = <String, Object>{
        'type': 'structured-content',
        'content': <Object>[
          <String, Object>{
            'tag': 'div',
            'content': <Object>[
              <String, Object>{'tag': 'span', 'content': '【名】'},
              '見出し語の説明文。',
            ],
          },
          <String, Object>{'tag': 'ul', 'content': items},
        ],
      };
      glossaries.add(<String, Object?>{
        'dictionary': 'Dict $d',
        'content': jsonEncode(structured),
        'definitionTags': d.isEven ? 'n' : 'v5',
        'termTags': '',
      });
    }
    out.add(<String, Object?>{
      'expression': '語彙$e',
      'reading': 'ごい$e',
      'matched': '語彙$e',
      'deinflectionTrace': <Object>[],
      'frequencies': <Object>[],
      'pitches': <Object>[],
      'glossaries': glossaries,
    });
  }
  return jsonEncode(out);
}

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart'
    show ReaderHibikiSource;
import 'package:hibiki/src/models/app_model.dart' show AppModel;
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart'
    show ReaderHibikiPage;

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart' show readyAppModel, seedReaderBook;
import 'support/itest_startup_guard.dart';
import 'test_helpers.dart';

/// TODO-982 / BUG-461 设备层几何验收门（真实 Windows 引擎 + 真实 reader WebView +
/// DOM-rect 探针）。
///
/// 复现报告：「连续(滚动)模式下，从收藏夹/合集点一条收藏句跳回原文，正常应整句完整
/// 显示，但刚好句子在页面外一行时『五五开』——句尾被阅读底栏切掉一半」。用户明确：
/// 「没跨页，这个是滚动模式」。
///
/// 根因修复（develop 86df35220，BUG-461）：旧连续 `scrollToCharOffset` 只把收藏句
/// **句首**字符对齐到内容顶，完全不看句尾。长句被滚到句首贴顶后，句尾溢出可见区底沿
/// （连续模式可见区 = `clip-path inset` 的 `[chromeTopInset, innerHeight −
/// chromeBottomInset]`，底部那段被阅读底栏盖住）→「句尾被切」。修复把跳转目标当作
/// **字符区间** `[start, end]`：`collections_page` 把 `normCharLength` 透传成
/// `Bookmark.charAnchorLength` → `_initialCharOffsetEnd` → `shellScript(
/// initialCharOffsetEnd:)` → 连续 shell `restoreToCharOffset(start, end)` →
/// 连续 `scrollToCharOffset(charOffset, endCharOffset)`：横排有句尾锚时先句首贴顶，
/// 若句尾溢出可见区底沿且整句放得下，多滚把句尾拉进可见区底沿（整句完整可见）。
///
/// 本测试在真实 app 离屏壳里端到端证明该修复的**几何效果**（产品代码已落地，本文件
/// 只加测试，不改产品代码）：
///   1. 播种标准日文 EPUB（含长段落），焦点驱动打开它，等 `hoshi_content_ready`。
///   2. 强制横排（`setTtuWritingMode('horizontal-tb')`，BUG-461 句尾对齐只在横排
///      生效）+「连续滚动」模式（`setTtuViewMode('continuous')`，报告里的精确场景），
///      经 onLayoutReloadLive 整章重排（产品改结构性布局键的同一路径）。
///   3. 注入非零的阅读底栏内边距 `--chrome-bottom-inset`（模拟底栏遮挡），按章内
///      可匹配字符计数选出一条**故意够长、句首贴顶后句尾会溢出可见区底沿**的句子
///      区间 `[start, end]`。
///   4. **负向对照**：先走旧的单点句首锚 `restoreToCharOffset(start)`（不传句尾），
///      DOM-rect 探针测句尾 `bottom`，断言它 **> 可见区底沿**（即旧行为真会切尾——
///      证明本测试的 fixture 句子确实溢出、测试能区分切尾与不切尾，非假绿）。
///   5. **正向断言**：走产品真实路径 `restoreToCharOffset(start, end)`（连续模式
///      收藏句跳转的同一 JS 调用），DOM-rect 探针测句尾 `bottom`，断言它
///      **≤ 可见区底沿**（`innerHeight − chromeBottomInset`），即整句句尾不被阅读
///      底栏遮挡。这是 BUG-461 的核心几何不变量，与产品 `scrollToCharOffset` 句尾
///      区间对齐用的 `--chrome-bottom-inset` 同一坐标系。
///
/// 句尾 `bottom` 取法与产品 JS 同口径：句尾字符 collapsed range 的 `rect.top` 加上
/// 一个行高（`line-height` 或 `fontSize*1.5` 兜底），即句尾字符所在行的底边。
///
/// 探针用 `ReaderHibikiPage.debugEvaluateJavascript`（reader 页对真实 WebView 暴露的
/// 测试钩子）跑 `getBoundingClientRect`，**不**用像素截图（bg 下 WebView 截图可能白框）。
///
/// 启动期网络噪声经 `runHibikiItest` 守卫放行。
///
/// Run (PowerShell, from hibiki/):
///   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 \
///       integration_test/reader_collection_jump_sentence_tail_itest.dart

/// reader WebView 是否挂载。
bool _webViewShown() =>
    find.byKey(const ValueKey<String>('hoshi_webview')).evaluate().isNotEmpty;

/// 内容就绪标记（hoshiReader 已注入、首章已铺好）。
bool _contentReady() => find
    .byKey(const ValueKey<String>('hoshi_content_ready'))
    .evaluate()
    .isNotEmpty;

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() ready,
  String label, {
  int maxPolls = 120,
}) async {
  for (int i = 0; i < maxPolls; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (ready()) {
      debugPrint('[coll-jump] $label ready after ${i * 500}ms');
      return;
    }
  }
  fail('$label did not become ready');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'TODO-982/BUG-461 continuous scroll: favorite-sentence jump fits the whole '
    'sentence — tail bottom stays above the reader bottom-chrome band',
    (WidgetTester tester) async {
      await runHibikiItest(
        label: 'coll-jump',
        body: () async {
          app.main();
          expect(await waitForHome(tester), isTrue,
              reason: 'home (nav bar) must render');
          await tester.pump(const Duration(seconds: 2));

          // 焦点驱动需要 HibikiFocusRoot（默认 OFF；开关后 main.dart 重建装上壳）。
          final AppModel appModel = await readyAppModel(tester);
          await appModel.setExperimentalFocusNavigationEnabled(true);
          for (int i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }

          // 播种标准日文 EPUB（含长段落，第一章 420 个标记段落）。
          await seedReaderBook(tester,
              fileName: 'todo982_collection_jump.epub');
          final FocusDriver driver = FocusDriver(tester);

          // 焦点落到书架标签后打开第一本书。
          final List<Finder> navTargets = findPrimaryNavigationTargets();
          if (navTargets.isNotEmpty) {
            await driver.focusWidget(navTargets.first);
            await driver.activate();
            await tester.pump(const Duration(seconds: 1));
          }

          final Finder bookEntries = findBookEntries();
          for (int i = 0; i < 40; i++) {
            await tester.pump(const Duration(milliseconds: 500));
            if (bookEntries.evaluate().isNotEmpty) break;
          }
          expect(bookEntries, findsWidgets,
              reason: 'seeded book must appear on the shelf');
          final bool focusedBook = await driver.focusWidget(bookEntries.first);
          expect(focusedBook, isTrue,
              reason: 'book card must be reachable by focus');
          await driver.activate();
          await tester.pump(const Duration(seconds: 3));

          await _waitFor(tester, _webViewShown, 'reader WebView');
          await _waitFor(tester, _contentReady, 'hoshi content');

          // 强制横排 + 连续滚动模式（报告里的精确场景）。BUG-461 句尾区间对齐只在
          // 横排生效（竖排可见区在内容宽度轴，无「句尾被底栏切」语义），而本机默认是
          // vertical-rl，必须切成 horizontal-tb。writingMode / viewMode 都是「结构性
          // 布局键」：产品里改它们走 notifyReaderLayoutChanged → onLayoutReloadLive
          // （整章重排，CSS-only 的 onSettingsChangedLive 表达不了写排方向切换）。这里
          // 严格复刻产品同一路径：先写两个偏好，再 fire onLayoutReloadLive 触发
          // 重排，等内容重新就绪。
          await ReaderHibikiSource.instance.setTtuWritingMode('horizontal-tb');
          await ReaderHibikiSource.instance.setTtuViewMode('continuous');
          // 设一个非零顶部正文边距：连续模式横排里 paddingTop = marginTop·vh +
          // chromeTopInset，而 BUG-461 的可见区上沿 bandTop = chromeTopInset。只有
          // paddingTop > bandTop（即 marginTop·vh > 0）时，句首贴内容顶后才可能比
          // 「贴可见区上沿」低一截，使一条本身放得下可见区的句子的句尾溢出底沿——
          // 这正是修复要解决的「放得下却被切尾」窗口。chromeTopInset 取 0 时窗口宽度
          // = marginTop·vh，10vh 给足余量。
          await ReaderHibikiSource.instance.setTtuMarginTop(10);
          ReaderHibikiSource.onLayoutReloadLive?.call();
          for (int i = 0; i < 16; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }
          await _waitFor(tester, _contentReady, 'continuous content');
          expect(ReaderHibikiSource.readerSettings?.isContinuousMode, isTrue,
              reason: 'reader must be in continuous scroll mode for TODO-982');

          final Future<dynamic> Function(String source)? runJs =
              ReaderHibikiPage.debugEvaluateJavascript;
          expect(runJs, isNotNull,
              reason: 'reader must expose debugEvaluateJavascript hook');

          // 健全性：我们已强制 horizontal-tb；确认 DOM 真生效（竖排无「句尾被底栏
          // 切」语义，本守卫只覆盖横排——产品修复亦只动横排分支）。
          final Object? verticalRaw =
              await runJs!('window.hoshiReader.isVertical();');
          final bool vertical = verticalRaw == true || verticalRaw == 'true';
          expect(vertical, isFalse,
              reason: 'after forcing horizontal-tb, the chapter must render '
                  'horizontally so the sentence-tail band semantics apply');

          // 注入非零阅读底栏内边距（模拟底栏遮挡），让可见区底沿明显高于视口底。
          // 与产品 setChromeInsets 同一 CSS 变量；连续 scrollToCharOffset 句尾区间
          // 对齐正是读这个 --chrome-bottom-inset 算 bandBottom。
          const double chromeBottomInsetPx = 160.0;
          // chromeTopInset = 0 → bandTop = 0；可见区上沿落在视口顶。配合上面的
          // marginTop·vh > 0，使 paddingTop(=marginTop·vh) > bandTop，开出修复生效窗口。
          const double chromeTopInsetPx = 0.0;
          await runJs(
            'window.hoshiReader.setChromeInsets('
            '$chromeTopInsetPx, $chromeBottomInsetPx);',
          );
          await tester.pump(const Duration(milliseconds: 300));

          // 选一条「故意够长、句首贴顶后句尾会溢出可见区底沿、但整句仍放得下可见区」
          // 的句子区间。用产品同一字符寻址（章内可匹配字符计数，createWalker 跳振假名）
          // 在真实 DOM 上探：从某个起始字符往后扩，直到句尾贴顶后的可视高度落在
          // (溢出底沿, 可见区高] 之间。纯几何探测，返回 [start, end]。
          final String pickJson = await runJs(r'''
            (function() {
              var rr = window.hoshiReader;
              var walker = rr.createWalker();
              var total = 0, node;
              while (node = walker.nextNode()) {
                total += rr.countChars(node.textContent);
              }
              var rootStyle = getComputedStyle(document.documentElement);
              var topInset = parseFloat(
                rootStyle.getPropertyValue('--chrome-top-inset')) || 0;
              var bottomInset = parseFloat(
                rootStyle.getPropertyValue('--chrome-bottom-inset')) || 0;
              var vh = window.innerHeight;
              var band = (vh - bottomInset) - topInset;
              var cs = getComputedStyle(document.body);
              var lineH = parseFloat(cs.lineHeight);
              if (!(lineH > 0)) lineH = (parseFloat(cs.fontSize) || 16) * 1.5;
              var pt = parseFloat(cs.paddingTop) || 0;
              var bandBottom = vh - bottomInset;
              // 句首贴内容顶后句尾视口位置 = pt + extent。要它 > bandBottom 才会被切；
              // 同时整句要放得下 extent <= band。
              var minExtent = (bandBottom - pt) + lineH;
              var maxExtent = band;
              if (minExtent >= maxExtent) {
                return JSON.stringify({ok:false, why:'no fitting extent window',
                  band:band, pt:pt, vh:vh, bandBottom:bandBottom, lineH:lineH});
              }
              var targetExtent = (minExtent + maxExtent) / 2;
              var start = Math.min(40, Math.floor(total * 0.2));
              function rangeAt(off) { return rr.collapsedRangeAtCharOffset(off); }
              var startRange = rangeAt(start);
              if (!startRange) return JSON.stringify({ok:false, why:'no start range'});
              var startTop = startRange.getBoundingClientRect().top;
              var end = start + 1;
              var chosen = -1;
              for (; end < total; end++) {
                var er = rangeAt(end);
                if (!er) continue;
                var extent = (er.getBoundingClientRect().top + lineH) - startTop;
                if (extent >= targetExtent) { chosen = end; break; }
                if (extent > maxExtent) { break; }
              }
              if (chosen < 0) {
                return JSON.stringify({ok:false, why:'could not reach extent',
                  total:total, targetExtent:targetExtent, band:band});
              }
              return JSON.stringify({ok:true, start:start, end:chosen,
                band:band, bandBottom:bandBottom, pt:pt, lineH:lineH,
                targetExtent:targetExtent});
            })();
          ''') as String;
          debugPrint('[coll-jump] pick=$pickJson');
          final Map<String, dynamic> pick =
              jsonDecode(pickJson) as Map<String, dynamic>;
          expect(pick['ok'], isTrue,
              reason: 'must find a sentence range that overflows the band but '
                  'still fits: $pickJson');
          final int startOff = (pick['start'] as num).toInt();
          final int endOff = (pick['end'] as num).toInt();

          // 句尾 bottom 探针（与产品同口径：句尾字符 collapsed range top + 一行高）。
          Future<Map<String, dynamic>> probe() async {
            final String raw = await runJs('''
              (function() {
                var rr = window.hoshiReader;
                var rootStyle = getComputedStyle(document.documentElement);
                var bottomInset = parseFloat(
                  rootStyle.getPropertyValue('--chrome-bottom-inset')) || 0;
                var vh = window.innerHeight;
                var bandBottom = vh - bottomInset;
                var cs = getComputedStyle(document.body);
                var lineH = parseFloat(cs.lineHeight);
                if (!(lineH > 0)) lineH = (parseFloat(cs.fontSize) || 16) * 1.5;
                var endRange = rr.collapsedRangeAtCharOffset($endOff);
                if (!endRange) return JSON.stringify({ok:false});
                var endTop = endRange.getBoundingClientRect().top;
                var tailBottom = endTop + lineH;
                return JSON.stringify({ok:true, tailBottom:tailBottom,
                  bandBottom:bandBottom, scrollTop:
                  (document.scrollingElement||document.documentElement).scrollTop});
              })();
            ''') as String;
            return jsonDecode(raw) as Map<String, dynamic>;
          }

          // ── 负向对照：旧单点句首锚（不传句尾）→ 句尾应溢出可见区底沿 ──
          await runJs('window.hoshiReader.restoreToCharOffset($startOff);');
          await tester.pump(const Duration(milliseconds: 400));
          final Map<String, dynamic> oldProbe = await probe();
          debugPrint('[coll-jump] OLD(start-only) probe=$oldProbe');
          expect(oldProbe['ok'], isTrue,
              reason: 'old-path probe must resolve the sentence tail');
          final double oldTailBottom =
              (oldProbe['tailBottom'] as num).toDouble();
          final double oldBandBottom =
              (oldProbe['bandBottom'] as num).toDouble();
          expect(oldTailBottom, greaterThan(oldBandBottom),
              reason:
                  'pre-fix single-point anchor must leave the sentence tail '
                  'BELOW the visible band bottom (cut off by reader chrome) — '
                  'tail=$oldTailBottom bandBottom=$oldBandBottom; this proves the '
                  'fixture sentence genuinely overflows so the guard is meaningful');

          // ── 正向断言：产品真实路径 restoreToCharOffset(start, end) ──
          await runJs('window.hoshiReader.restoreToCharOffset('
              '$startOff, $endOff);');
          await tester.pump(const Duration(milliseconds: 400));
          final Map<String, dynamic> newProbe = await probe();
          debugPrint('[coll-jump] NEW(range) probe=$newProbe');
          expect(newProbe['ok'], isTrue,
              reason: 'range-path probe must resolve the sentence tail');
          final double newTailBottom =
              (newProbe['tailBottom'] as num).toDouble();
          final double newBandBottom =
              (newProbe['bandBottom'] as num).toDouble();

          // 核心几何不变量（BUG-461）：跳转后整句句尾 bottom ≤ 可见区底沿（不被底栏切）。
          // 容差 1px 吸收亚像素/行高估算误差。
          expect(newTailBottom, lessThanOrEqualTo(newBandBottom + 1.0),
              reason: 'TODO-982 fix: after range-aware continuous jump, the '
                  'sentence TAIL bottom ($newTailBottom) must sit at or above the '
                  'visible content band bottom ($newBandBottom = innerHeight − '
                  'chromeBottomInset), i.e. the whole sentence fits and the tail '
                  'is NOT covered by the reader bottom chrome');

          debugPrint('[coll-jump] PASS: continuous favorite-sentence jump fits '
              'the whole sentence (tail $newTailBottom <= band $newBandBottom); '
              'pre-fix single-point anchor cut the tail (old tail $oldTailBottom '
              '> band $oldBandBottom).');
        },
      );
    },
  );
}

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart'
    show buildSpreadPageHtml;
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/source_guard.dart';
import '../pages/reader_hibiki_page_source_corpus.dart';

/// BUG-1280 守卫：从书架打开书后自动切进「双页漫画」（spread）展开，就再也唤不出
/// 底栏、退不出这本书。
///
/// ① spread 页是 [buildSpreadPageHtml] 生成的**独立文档**（继歌词 BUG-756、VN
///    BUG-1195 之后的第四种），HTML 本身不含正文 hoshiReader 的 onTap/onTapEmpty，
///    自带手势只有「点图片 → 弹图片查看器」。底栏一收起就没有唤出通道，用户看不到
///    返回按钮 → 退不出书 → 回不到书架。
/// ② 点图片的 Dart 处理器没有 reclaim 阅读焦点，OS 焦点留在 WebView，ESC 全局退出
///    也失效（BUG-136 同族）。两张整页图铺满视口时点击几乎必然命中图片，于是两条
///    退出通道同时死掉。
/// ③ 平台分叉：`_loadSpreadPage` 的 baseUrl 与 `_chapterUrl(_currentChapter)` 逐字
///    相同，而 onLoadStop 的陈旧判据只比 `Uri.path`。Windows 的 loadData 丢 baseUrl
///    → 判 stale → 不注入；Android 的 loadDataWithBaseURL 保留 baseUrl → 判据放行
///    → 整份正文引擎（含 onTapEmpty）被注进 spread 文档，与本修复的专桥双触发、
///    互相抵消。必须有守卫钉住「spread 文档不注入正文引擎」。
///
/// 修法：spread 文档补「图片以外的点击」专桥交给 Dart 判唤出/收起（镜像歌词），
/// 点图片路径补 reclaim，`_onChapterLoadComplete` 加 spread 分支守卫；并把
/// `spreadMode` 默认从 auto 改成 off（选项本身完整保留）。
void main() {
  const String kEmptyTapBridge = 'onSpreadTapEmpty';

  group('spread 文档有唤出底栏的通道 (BUG-1280)', () {
    const String leftUrl = 'hoshi.local/OEBPS/img/left.png';
    const String rightUrl = 'hoshi.local/OEBPS/img/right.png';
    final String html = buildSpreadPageHtml(
      leftUrl: leftUrl,
      rightUrl: rightUrl,
      swipeDistThreshold: 44,
      swipeFastDistThreshold: 22,
    );

    test('图片以外的点击有专桥回传 Dart', () {
      expect(html, contains("callHandler('$kEmptyTapBridge')"),
          reason: 'spread 页没有这条桥就没有任何唤出底栏的手势 → 退不出书');
      expect(html, contains("document.addEventListener('click'"),
          reason: '专桥必须挂在文档级，才能收到 letterbox 留白 / 页缝上的点击');
    });

    test('点在图片上仍走图片查看器，不误报成空白点（位置断言）', () {
      final int bridgeIdx = html.indexOf("callHandler('$kEmptyTapBridge')");
      final int guardIdx = html.indexOf("tagName === 'IMG'");
      expect(guardIdx, greaterThan(0), reason: '缺少 IMG 短路');
      expect(guardIdx, lessThan(bridgeIdx),
          reason: 'IMG 短路必须在回传之前，否则点图片会被当成空白点');
      expect(html, contains("callHandler('onImageTap'"),
          reason: '点图片查看原图是既有行为，不得被本次修复吃掉');
    });

    // 上一条只断言字面量的**位置**，把 `if (...) return;` 改成空块（保留判断、删掉
    // `return;`）它照样绿——而那个变异会让点图片同时弹查看器 + 翻转底栏。这里把
    // 生产 HTML 里的脚本原样丢进 node 真跑，断言的是**短路真的生效**：模拟冒泡，
    // 点 IMG 只能出 onImageTap，点留白才出 onSpreadTapEmpty。
    test('spread 脚本真跑：IMG 短路真生效，点图片不翻底栏（行为级）', () {
      final String payload = jsonEncode(<String, String>{'html': html});
      final Directory temp =
          Directory.systemTemp.createTempSync('hibiki-spread-js-');
      final File payloadFile = File('${temp.path}/payload.json')
        ..writeAsStringSync(payload);
      late final ProcessResult result;
      try {
        result = Process.runSync(
          'node',
          <String>['-e', _spreadBehaviorRunner, payloadFile.path],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
      } finally {
        temp.deleteSync(recursive: true);
      }
      expect(
        result.exitCode,
        0,
        reason: 'spread JS behavior runner failed:\n'
            'stdout=${result.stdout}\nstderr=${result.stderr}',
      );
      expect(result.stdout.toString().trim(), 'OK');
    });

    test('空白桥与 spreadReady 就绪门控互不干扰 (TODO-1229 不回退)', () {
      expect(html, contains("callHandler('spreadReady')"));
      expect(html, contains('function signalReady'));
      expect("callHandler('spreadReady')".allMatches(html).length, 1);
    });
  });

  group('Dart 侧接线 (BUG-1280)', () {
    final String source = readReaderPageSource();

    test('注册了 $kEmptyTapBridge 处理器，且无条件翻转底栏 + 夺回焦点', () {
      final int idx = source.indexOf("handlerName: '$kEmptyTapBridge'");
      expect(idx, greaterThan(0), reason: 'JS 发了桥而 Dart 不接 = 桥是死的');
      // 切到下一个 handler 注册为止，只看本处理器函数体。
      final int end = source.indexOf('addJavaScriptHandler', idx + 1);
      expect(end, greaterThan(idx));
      final String body = source.substring(idx, end);

      expect(body, contains('_handleFloatingChromeReveal()'),
          reason: '悬浮态必须走唤出/收起状态机');
      expect(body, contains('_toggleChrome()'), reason: '挤压态必须能翻转底栏');
      expect(body, contains('FocusReclaimCause.gesture'),
          reason: '不夺回 Flutter 焦点则 ESC 退出仍然失效（BUG-136）');
      expect(containsCodeLine(body, 'tapEmptyToHideChrome'), isFalse,
          reason: 'spread 没有别的唤出途径，绝不能被「点空白隐藏控制栏」开关关死');
    });

    test('点图片路径夺回阅读焦点，ESC 仍能退出', () {
      final int idx = source.indexOf("handlerName: 'onImageTap'");
      expect(idx, greaterThan(0));
      final int end = source.indexOf('addJavaScriptHandler', idx + 1);
      expect(end, greaterThan(idx));
      final String body = source.substring(idx, end);

      expect(body, contains('FocusReclaimCause.gesture'),
          reason: '点图片把 OS 焦点交给 WebView，不 reclaim 则看完图后 ESC 退不出书');
      expect(body, contains('_openImageViewer('),
          reason: '查看原图是既有行为，reclaim 不得取代它');
    });

    // 平台分叉守卫：Android 的 loadDataWithBaseURL 保留 baseUrl，onLoadStop 只比
    // path 的陈旧判据分不出 spread 文档，会把整份正文引擎（含 onTapEmpty）注进来，
    // 与专桥双触发互相抵消。Windows 因 NavigateToString 丢 baseUrl 天然不会。
    test('spread 独立文档不注入正文引擎（Android/Windows 行为拉齐）', () {
      final String body =
          methodBody(source, 'Future<void> _onChapterLoadComplete(');
      expect(containsCodeLine(body, '_spreadDocumentLoaded'), isTrue,
          reason: 'spread 文档必须在注入正文引擎之前被挡下');

      final int guardIdx = body.indexOf('if (_spreadDocumentLoaded)');
      final int injectIdx = body.indexOf('readerEngineSource(');
      expect(guardIdx, greaterThan(0), reason: '守卫必须是真分支，不是提一嘴的注释');
      expect(injectIdx, greaterThan(0), reason: '正文引擎注入点没了，本守卫需要跟着重写');
      expect(guardIdx, lessThan(injectIdx), reason: '守卫必须在注入之前，放在后面等于没有');

      // 光有判断不够，必须真的短路掉后续注入。窗口只能是 if 块**自身**（花括号
      // 配对）：早先写成 `body.substring(guardIdx, injectIdx)` 时，窗口里混进了
      // 歌词分支自己的 `return;`，把「删掉守卫的 return」这个变异放了过去（实测
      // 假绿）。
      final String guardBlock = methodBody(body, 'if (_spreadDocumentLoaded)');
      expect(containsCodeLine(guardBlock, 'return;'), isTrue,
          reason: '判到 spread 却不 return，正文引擎照样注进去');

      // 两个写点必须都在：置位在 spread 装载原语，复位在正文章节装载原语。
      // 少任何一个，标记要么永远为假（守卫真空通过）、要么置位后再不复位
      // （正文章节从此不再注入引擎 = 整个阅读器废掉）。
      final String setBody =
          methodBody(source, 'Future<void> _loadSpreadPage(SpreadEntry entry)');
      expect(containsCodeLine(setBody, '_spreadDocumentLoaded = true'), isTrue,
          reason: 'spread 装载原语必须置位，否则守卫永远看不到 spread');
      final String clearBody =
          methodBody(source, 'Future<void> _loadChapterDirectly(int index)');
      expect(
          containsCodeLine(clearBody, '_spreadDocumentLoaded = false'), isTrue,
          reason: '正文章节装载原语必须复位，否则翻回正文后引擎再不注入');

      // 第三个装载点：歌词。漏掉它 → 从双页页面切进歌词模式时标记残留为真，
      // spread 守卫把歌词分支一起挡掉 → 歌词永远不就绪。
      final String lyricsBody =
          methodBody(source, 'Future<void> _loadLyricsPage()');
      expect(
          containsCodeLine(lyricsBody, '_spreadDocumentLoaded = false'), isTrue,
          reason: '歌词装载点必须复位，否则从双页切歌词会被 spread 守卫挡死');
    });
  });

  group('spreadMode 默认不再自动进双页 (BUG-1280)', () {
    late HibikiDatabase db;

    setUp(() {
      db = HibikiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('没设置过的用户默认 off', () {
      expect(ReaderSettings(db).spreadMode, 'off');
    });

    test('显式设过的值照旧生效（选项没被删掉）', () async {
      final ReaderSettings settings = ReaderSettings(db);
      for (final String mode in <String>['auto', 'on', 'off']) {
        await settings.setSpreadMode(mode);
        expect(settings.spreadMode, mode);
      }
    });

    // `ttu_spread_mode` 有两处兜底默认：[ReaderSettings.spreadMode] 是阅读器真正
    // 读的那个，[ReaderHibikiSource.ttuSpreadMode] 是 readerSettings 未就绪时
    // （设置页 / 冷启动）读的那个。两处漂开 = 设置页显示的默认与阅读器实际用的默认
    // 相反。上面两条真行为测试只覆盖 ReaderSettings，单独把 source 那处改回 auto
    // 全套照样绿——所以必须有这条跨文件一致性断言。
    test('两处兜底默认必须一致，且都是 off', () {
      const String kSettingsFile = 'lib/src/reader/reader_settings.dart';
      const String kSourceFile =
          'lib/src/media/sources/reader_hibiki_source.dart';
      final String settingsSrc = File(kSettingsFile).readAsStringSync();
      final String sourceSrc = File(kSourceFile).readAsStringSync();

      final RegExpMatch? settingsHit = RegExp(
        r"_get<String>\(\s*'ttu_spread_mode'\s*,\s*'([a-z]+)'\s*\)",
      ).firstMatch(settingsSrc);
      final RegExpMatch? sourceHit = RegExp(
        r"key:\s*'ttu_spread_mode'\s*,\s*defaultValue:\s*'([a-z]+)'",
      ).firstMatch(sourceSrc);

      // `isNotNull` 在本文件里与 drift 的同名符号撞车（两边都被 import），
      // 故用显式 `!= null`，语义相同。
      expect(settingsHit != null, isTrue,
          reason: '$kSettingsFile 里找不到 ttu_spread_mode 的兜底默认，守卫已失效');
      expect(sourceHit != null, isTrue,
          reason: '$kSourceFile 里找不到 ttu_spread_mode 的兜底默认，守卫已失效');

      final String settingsDefault = settingsHit!.group(1)!;
      final String sourceDefault = sourceHit!.group(1)!;
      expect(sourceDefault, settingsDefault,
          reason: '两处兜底默认漂开：$kSettingsFile=$settingsDefault / '
              '$kSourceFile=$sourceDefault');
      expect(settingsDefault, 'off', reason: 'BUG-1280：没设置过的用户不得被自动切进双页展开');
    });
  });
}

/// 把生产 spread HTML 里的 `<script>` 原样丢进 node 跑，用最小假 DOM 复现「点图片」
/// 与「点留白」两条真实路径（含冒泡：真浏览器里 img 的 click 一定会冒到文档级监听）。
const String _spreadBehaviorRunner = r"""
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
function assert(value, message) {
  if (!value) throw new Error(message);
}
const html = data.html;
const open = html.indexOf('<script>');
const close = html.indexOf('</script>', open);
assert(open >= 0 && close > open, 'spread script block missing');
const script = html.slice(open + '<script>'.length, close);

function node(tagName, src) {
  return {
    tagName: tagName,
    src: src,
    listeners: {},
    complete: true,
    naturalWidth: 100,
    addEventListener(type, fn) {
      (this.listeners[type] = this.listeners[type] || []).push(fn);
    },
    removeEventListener(type, fn) {
      const list = this.listeners[type] || [];
      this.listeners[type] = list.filter(f => f !== fn);
    }
  };
}

const imgs = [node('IMG', 'L'), node('IMG', 'R')];
// BUG-1426 起本文档还挂了 wheel / touch / capture 阶段的 click 监听，故假 DOM 要
// 按 (type, capture) 分桶——否则「文档级 click 桥只有一个」这条断言会被 capture 阶段
// 那个吞噬监听凑数放过去。
const docListeners = {};
function bucket(type, capture) {
  const key = type + (capture ? ':capture' : '');
  return (docListeners[key] = docListeners[key] || []);
}
const document = {
  querySelectorAll(selector) {
    assert(selector === 'img', 'unexpected selector ' + selector);
    return imgs;
  },
  addEventListener(type, fn, options) {
    const capture = options === true || (options && options.capture === true);
    bucket(type, capture).push(fn);
  }
};
const calls = [];
const window = {
  flutter_inappwebview: {callHandler: (...args) => calls.push(args)}
};
new Function('window', 'document', script)(window, document);

assert(calls.length === 1 && calls[0][0] === 'spreadReady',
  'already-decoded images must signal spreadReady once, got ' +
  JSON.stringify(calls));
assert((docListeners['click'] || []).length === 1,
  'spread document-level click listener missing');

// 真浏览器语义：capture 阶段的文档级监听最先跑（可 stopPropagation 掐断后续），
// 再跑目标自己的监听，最后冒泡回文档级监听——三段共用同一个 event 对象。
function clickOn(target) {
  let stopped = false;
  const ev = {
    target: target,
    stopPropagation() { stopped = true; },
    preventDefault() {}
  };
  (docListeners['click:capture'] || []).slice().forEach(fn => fn(ev));
  if (stopped) return;
  (target.listeners['click'] || []).slice().forEach(fn => fn(ev));
  (docListeners['click'] || []).slice().forEach(fn => fn(ev));
}

calls.length = 0;
clickOn(imgs[0]);
assert(calls.length === 1,
  'clicking an image must fire exactly one bridge, got ' +
  JSON.stringify(calls));
assert(calls[0][0] === 'onImageTap' && calls[0][1] === 'L',
  'clicking an image must open the image viewer, got ' +
  JSON.stringify(calls));

calls.length = 0;
clickOn(node('DIV', null));
assert(calls.length === 1 && calls[0][0] === 'onSpreadTapEmpty',
  'clicking the letterbox must reach the chrome-reveal bridge, got ' +
  JSON.stringify(calls));

process.stdout.write('OK');
""";

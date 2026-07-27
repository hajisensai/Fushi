import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/reader/reader_caret_scripts.dart';
import 'package:hibiki/src/reader/reader_engine_config.dart';
import 'package:hibiki/src/reader/reader_engine_script.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';
import 'package:hibiki/src/reader/reader_selection_scripts.dart';
import 'package:hibiki/src/reader/reader_visual_novel_scripts.dart';

/// BUG-1140 第二阶段①守卫：阅读器引擎 JS 走 `<script src>` 外链 + 强缓存，
/// 每次导航只下发一小份 config。
///
/// 这套守卫存在的理由（写清楚，别日后被当成噪音删掉）：
///
/// 1. **性能改动最容易裸奔**。收益全在「注入载荷从 14.5 万字符降到 1 千字符」和
///    「引擎源码逐字不变所以能被 WebView 缓存 + 复用编译结果」这两条性质上，而性质
///    退化不会让任何现有测试变红——真机 itest 又不进 CI 单测门。本文件把这两条性质
///    直接钉成断言。
/// 2. **本仓出过「守卫逃逸出覆盖范围」**：把判定从 JS 侧搬到 Dart 侧，三条扫 JS 源码
///    的守卫一个字都管不到，CI 照样全绿。引擎形态从内联字符串变成外链资源，正是同一
///    类风险，所以这里同时钉住「引擎里确实含有全部载荷」「章节 HTML 里确实有 script
///    标签」「拦截器确实认这个路径」「响应确实带强缓存头」。
/// 3. **改动前的覆盖是单向的**：所有脚本守卫都只断言各 builder 的返回值，没有一条
///    断言那些返回值真的进了注入物——漏装一个载荷（caret / longPressDrag / 某个
///    shell），约一百条测试照样全绿。第 2 组直接补这条链。
void main() {
  late String webview;

  setUpAll(() {
    webview = File(
      'lib/src/pages/implementations/reader_hibiki/webview.part.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
  });

  group('1. 引擎源码与导航状态无关', () {
    test('引擎构造器是 static 且无参（编译器背书：static 读不到实例状态）', () {
      // 这是本改动的地基：只要它是 static + 无参，编译器就保证引擎源码不可能
      // 掺进 _settings / _initialProgress / MediaQuery 这类每次导航才知道的值。
      expect(
        webview.contains('static String _buildReaderEngineSource() {'),
        isTrue,
        reason: '_buildReaderEngineSource 必须保持 static 且无参数；'
            '一旦加回参数，引擎就会随导航变化，外链强缓存与编译复用同时失效',
      );
      expect(
        webview.contains('String _buildReaderSetupScript({'),
        isFalse,
        reason: '旧的 per-nav 拼装入口必须彻底消失，不能两条路并存',
      );
    });

    test('三种 shell 的源码访问器同样无参', () {
      final String pagination = File(
        'lib/src/reader/reader_pagination_scripts.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      final String vn = File(
        'lib/src/reader/reader_visual_novel_scripts.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      expect(pagination.contains('static String paginatedShellSource() {'),
          isTrue);
      expect(pagination.contains('static String continuousShellSource() {'),
          isTrue);
      expect(vn.contains('static String vnShellScript() => _shell();'), isTrue);
      expect(
        pagination.contains('static String shellScript('),
        isFalse,
        reason: '旧的按模式插值的 shellScript 必须消失',
      );
    });

    test('同一进程里引擎源码与版本哈希恒定', () {
      expect(readerHibikiEngineSource(), readerHibikiEngineSource());
      expect(
        readerHibikiEngineVersion(),
        ReaderEngineScript.versionOf(readerHibikiEngineSource()),
      );
    });

    test('引擎只定义不执行（外链在解析期跑，不能有副作用）', () {
      final String src = readerHibikiEngineSource().trim();
      expect(
        src.startsWith('window.__hoshiEngine = {'),
        isTrue,
        reason: '引擎顶层只能是一个 window.__hoshiEngine 对象字面量赋值；'
            '任何顶层副作用都会在 <script src> 解析期提前发生，破坏时序',
      );
      expect(src.endsWith('};'), isTrue);
      expect('install: function(C) {'.allMatches(src).length, 1);
    });
  });

  group('2. 引擎必须含有全部载荷（此前完全没有的一条链）', () {
    test('每个真实载荷的特征行都出现在最终引擎里', () {
      final String engine = readerHibikiEngineSource();
      final Map<String, String> payloads = <String, String>{
        'selection': ReaderSelectionScripts.source(),
        'longPressDrag': ReaderSelectionScripts.longPressDragGestureScript(),
        'caret': ReaderCaretScripts.source(),
        'shell.paginated': ReaderPaginationScripts.paginatedShellSource(),
        'shell.continuous': ReaderPaginationScripts.continuousShellSource(),
        'shell.vn': ReaderVisualNovelScripts.vnShellScript(),
      };
      payloads.forEach((String name, String payload) {
        // 特征行从真实 builder 输出里取（不是硬编码字面量），所以载荷改写不会让
        // 守卫漂成永真；载荷整块被漏装才会红。
        final String marker = _signatureLine(payload);
        expect(
          engine.contains(marker),
          isTrue,
          reason: '引擎里找不到 $name 载荷的特征行 <$marker> —— '
              '拼装时漏装了一整块载荷，而各 builder 自己的守卫看不到这一层',
        );
      });
    });

    test('三种 shell 与运行时分流点都在引擎里', () {
      final String engine = readerHibikiEngineSource();
      for (final String shell in <String>['paginated', 'continuous', 'vn']) {
        expect(engine.contains('window.__hoshiShells.$shell = function(C)'),
            isTrue);
      }
      expect(engine.contains('window.__hoshiInstallShell(C);'), isTrue);
    });

    test('caret / furigana 的初始化改成读运行时 config', () {
      final String engine = readerHibikiEngineSource();
      expect(engine.contains('window.hoshiCaret.init({'), isTrue);
      expect(engine.contains('color: C.caretColor,'), isTrue);
      expect(engine.contains("C.furiganaMode === 'partial'"), isTrue);
      expect(engine.contains("C.furiganaMode === 'toggle'"), isTrue);
    });
  });

  group('3. 每章注入载荷必须保持极小（收益本身）', () {
    test('boot 载荷只有 config + 一次 install 调用，不含引擎本体', () {
      final String boot = ReaderEngineScript.bootInvocation(_sampleConfig());
      expect(
        boot.length,
        lessThan(4096),
        reason: '每次跨章下发的载荷必须只是 config；一旦有人把引擎塞回内联路径，'
            '这条会红——这就是本改动收益的守卫',
      );
      expect(boot.contains('window.__hoshiEngine.install(C);'), isTrue);
      // 引擎独有符号一个都不许出现在每章载荷里。
      for (final String engineOnly in <String>[
        'window.__hoshiShells.paginated = function(C)',
        'buildNodeOffsets',
        'window.hoshiSelection',
        'window.hoshiCaret.init({',
      ]) {
        expect(
          boot.contains(engineOnly),
          isFalse,
          reason: 'boot 载荷里出现了引擎本体符号，说明引擎又被塞回每章注入路径了',
        );
      }
    });

    test('boot 是表达式，返回值供 Dart 做确定性能力检查', () {
      final String boot = ReaderEngineScript.bootInvocation(_sampleConfig());
      expect(boot.startsWith('(function(){'), isTrue);
      expect(boot.endsWith('})()'), isTrue);
      expect(boot.contains('return "${ReaderEngineScript.bootOk}"'), isTrue);
      expect(
        boot.contains('return "${ReaderEngineScript.bootEngineMissing}"'),
        isTrue,
      );
    });

    test('per-nav 参数确实进了 config 字面量（含 cue 原样拼接）', () {
      final ReaderEngineConfig cfg = _sampleConfig(
        sasayakiCuesJson: '[{"id":"c1","start":0}]',
      );
      final String literal = cfg.toJsLiteral();
      final Map<String, dynamic> decoded =
          jsonDecode(literal) as Map<String, dynamic>;
      expect(decoded['initialProgress'], 0.42);
      expect(decoded['chromeBottomInset'], 64);
      expect(decoded['furiganaMode'], 'toggle');
      expect(decoded['dartPageWidth'], 800);
      expect((decoded['sasayakiCues'] as List<dynamic>).length, 1);
      expect(_sampleConfig().toJsLiteral().contains('"sasayakiCues":null'),
          isTrue);
    });
  });

  group('4. 外链链路：HTML 标签 / 拦截器路由 / 强缓存', () {
    test('章节 HTML 的三条注入分支都带 script src', () {
      final int start = webview.indexOf('final String engineTag =');
      expect(start, isNonNegative, reason: '章节 HTML 必须注入引擎外链标签');
      final int end = webview.indexOf('return Uint8List.fromList', start);
      expect(end, isNonNegative);
      final String block = webview.substring(start, end);
      // head 开闭齐全 / 只有 head / 完全没有 head —— 三条分支缺一不可，
      // 漏一条就有一类书永远走内联兜底，性能静默退回改动前。
      expect(r'$engineTag'.allMatches(block).length, 3,
          reason: 'HTML 注入的三条分支必须都拼上引擎外链标签');
    });

    test('标签用 defer：不阻塞解析，但保证早于 load 事件就绪', () {
      final String tag = ReaderEngineScript.tag('https://hoshi.local/x.js');
      expect(tag.contains('defer'), isTrue);
      expect(tag.contains('src="https://hoshi.local/x.js"'), isTrue);
    });

    test('拦截器认引擎路径，且排在 epub 之前', () {
      final int engineIdx =
          webview.indexOf('ReaderEngineScript.isEnginePath(path)');
      final int epubIdx = webview.indexOf("if (!path.startsWith('/epub/'))");
      expect(engineIdx, isNonNegative, reason: '拦截器必须分派引擎路径');
      expect(epubIdx, isNonNegative);
      expect(engineIdx < epubIdx, isTrue);
      expect(
        webview.contains('headers: ReaderEngineScript.cacheHeaders,'),
        isTrue,
        reason: '引擎响应必须带强缓存头，否则每章都会回拦截器重新取 + 重新编译',
      );
    });

    test('强缓存头是 immutable + 长 max-age，URL 带内容哈希', () {
      final String cc = ReaderEngineScript.cacheHeaders['Cache-Control']!;
      expect(cc.contains('immutable'), isTrue);
      expect(cc.contains('max-age=31536000'), isTrue);
      final String version = readerHibikiEngineVersion();
      expect(
          ReaderEngineScript.isEnginePath(ReaderEngineScript.pathFor(version)),
          isTrue);
      expect(ReaderEngineScript.isEnginePath('/epub/ch1.xhtml'), isFalse);
      expect(
        ReaderHibikiSource.engineUrl(version)
            .endsWith(ReaderEngineScript.pathFor(version)),
        isTrue,
      );
    });
  });

  group('5. 时序保证（PR#461 / PR#469 建立的两条，不得被本改动动摇）', () {
    test('install 仍由 Dart 在 onLoadStop 之后触发，不挂脚本解析期', () {
      // 引擎脚本只定义（见第 1 组最后一条）；执行时刻由 boot 决定，而 boot 就在
      // 改动前 evaluateJavascript(整份 setup 脚本) 的同一位置——docLoad 打点之后、
      // evalSetupScript 打点之前，同一个 _navigateGeneration 守卫下。
      final int bootIdx =
          webview.indexOf('ReaderEngineScript.bootInvocation(engineConfig)');
      final int markIdx =
          webview.indexOf("ReaderChapterPerfTrace.mark('evalSetupScript')");
      expect(bootIdx, isNonNegative);
      expect(markIdx, isNonNegative);
      expect(bootIdx < markIdx, isTrue);
      expect(
        readerHibikiEngineSource()
            .contains("if (document.readyState === 'complete')"),
        isTrue,
        reason: 'shell 的 load / readyState 双分支 boot 语义保持不变',
      );
    });

    test('外链缺席时就地内联同一份引擎（确定性兜底，不是重试/等待）', () {
      expect(
        webview.contains('ReaderEngineScript.inlineFallback('),
        isTrue,
        reason: '拦截器失败 / 旧缓存 HTML 时必须有确定性兜底，不能白屏',
      );
      expect(
        webview.contains('!= ReaderEngineScript.bootOk'),
        isTrue,
        reason: '兜底判据必须是 boot 的返回值，不能是超时或轮询',
      );
      // 兜底路径与外链路径必须共用同一份引擎源码，不能各造一份。
      expect(webview.contains('source: readerEngineSource(),'), isTrue);
    });
  });

  group('6. 生成的 JS 真能解析（node --check）', () {
    test('引擎与 boot 都是合法 JS', () {
      final ProcessResult probe = _runNode(<String>['--version']);
      if (probe.exitCode != 0) {
        markTestSkipped('node 不可用，跳过真解析');
        return;
      }
      final Directory tmp = Directory.systemTemp.createTempSync('hoshi-engine');
      try {
        final File engine = File('${tmp.path}/engine.js')
          ..writeAsStringSync(readerHibikiEngineSource());
        final File boot = File('${tmp.path}/boot.js')
          ..writeAsStringSync(
              'void ${ReaderEngineScript.bootInvocation(_sampleConfig())};');
        for (final File f in <File>[engine, boot]) {
          final ProcessResult r = _runNode(<String>['--check', f.path]);
          expect(r.exitCode, 0, reason: '解析失败: ${r.stderr}');
        }
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}

/// 从载荷里挑一条稳定的特征行：足够长、不是注释、不是纯符号。
/// 从真实 builder 输出里取，所以不会随载荷改写漂成永真断言。
String _signatureLine(String payload) {
  for (final String raw in payload.split('\n')) {
    final String line = raw.trim();
    if (line.length < 40) continue;
    if (line.startsWith('//') ||
        line.startsWith('/*') ||
        line.startsWith('*')) {
      continue;
    }
    if (line.startsWith('<script') || line.startsWith('</script')) continue;
    return line;
  }
  throw StateError('载荷里找不到可用作特征的行');
}

ProcessResult _runNode(List<String> args) {
  try {
    return Process.runSync('node', args);
  } on ProcessException {
    return ProcessResult(0, 127, '', 'node not found');
  }
}

ReaderEngineConfig _sampleConfig({String? sasayakiCuesJson}) =>
    ReaderEngineConfig(
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
      furiganaMode: 'toggle',
      caretColor: 'rgba(0,0,0,0.5)',
      caretInsetTop: 0,
      caretInsetBottom: 64,
      initialProgress: 0.42,
      initialCharOffset: -1,
      initialCharOffsetEnd: -1,
      initialFragment: null,
      chromeTopInset: 0,
      chromeBottomInset: 64,
      dartPageWidth: 800,
      dartPageHeight: 600,
      blurImages: false,
      revealedKeys: const <String>[],
      perfTraceEnabled: false,
      vnRevealSpeed: 0,
      vnScreenMode: 'block',
      vnSentencesPerScreen: 1,
      vnPreserveDialogue: false,
      vnMergeCrossScreenSasayakiCues: false,
      sasayakiCuesJson: sasayakiCuesJson,
    );

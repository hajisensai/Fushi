import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/reader/reader_caret_scripts.dart';
import 'package:hibiki/src/reader/reader_engine_config.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';
import 'package:hibiki/src/reader/reader_selection_scripts.dart';
import 'package:hibiki/src/reader/reader_visual_novel_scripts.dart';

/// 守卫：阅读器引擎 JS 的 per-nav 参数走 [ReaderEngineConfig] 运行时读取，引擎源码本身
/// 只依赖 view-mode 与编译期常量。
///
/// 为什么要这套守卫：
///
/// 1. **引擎源码"与导航状态无关"这条性质退化不会让任何现有测试变红**。一旦有人把某个
///    per-nav 值插回源码，memoize 就悄悄失效（每章重新拼装 + 压缩近万行，实测 9ms），
///    而功能完全正常。第 1 组把这条性质直接钉成断言。
/// 2. **本仓出过"守卫逃逸出覆盖范围"**：把判定从 JS 侧搬到 Dart 侧，三条扫 JS 源码的
///    守卫一个字都管不到，CI 照样全绿。判定从 Dart 插值搬到 JS 运行时正是同一类风险。
/// 3. **改动前的覆盖是单向的**：约 100 条脚本守卫都只断言各 builder 的返回值，没有一条
///    断言那些返回值真的进了注入物——漏装一个载荷（caret / longPressDrag / 某个 shell），
///    那 100 条照样全绿。第 2 组补这条链。
void main() {
  late String webview;

  setUpAll(() {
    webview = File(
      'lib/src/pages/implementations/reader_hibiki/webview.part.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
  });

  group('1. 引擎源码与导航状态无关', () {
    test('引擎构造器是 static，参数表只有 view-mode 开关', () {
      // 这是本改动的地基：static 让编译器保证引擎源码不可能掺进 _settings /
      // _initialProgress / MediaQuery 这类每次导航才知道的值。
      // static 保证读不到实例状态；参数表只许有 view-mode 两个开关——多一个
      // per-nav 参数，引擎就会随导航变化，memoize 立刻失效。
      final int declIdx =
          webview.indexOf('static String _buildReaderEngineSource({');
      expect(declIdx, isNonNegative,
          reason: '_buildReaderEngineSource 必须是 static');
      final String params =
          webview.substring(declIdx, webview.indexOf('}) {', declIdx));
      expect(params.contains('required bool vnMode,'), isTrue);
      expect(params.contains('required bool continuousMode,'), isTrue);
      expect('required '.allMatches(params).length, 2,
          reason: '参数表只许有 vnMode / continuousMode 两个 view-mode 开关；'
              '多一个 per-nav 参数，引擎就会随导航变化，memoize 立刻失效');
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

    test('同一进程里同一模式的引擎源码恒定（memoize 的前提）', () {
      expect(readerHibikiEngineSource(), same(readerHibikiEngineSource()));
      expect(readerHibikiEngineSource(continuousMode: true),
          same(readerHibikiEngineSource(continuousMode: true)));
      expect(readerHibikiEngineSource(vnMode: true),
          same(readerHibikiEngineSource(vnMode: true)));
      // 三种模式各自不同（没有被 memoize key 串味）。
      expect(
          readerHibikiEngineSource() ==
              readerHibikiEngineSource(continuousMode: true),
          isFalse);
    });

    test('引擎只定义不执行，install 之外没有顶层副作用', () {
      final String src = readerHibikiEngineSource().trim();
      expect(
        src.startsWith('window.__hoshiEngine = {'),
        isTrue,
        reason: '引擎顶层只能是一个 window.__hoshiEngine 对象字面量赋值；'
            '顶层副作用会脱离 install 的时序控制',
      );
      expect(src.endsWith('};'), isTrue);
      expect('install: function(C) {'.allMatches(src).length, 1);
    });
  });

  group('2. 引擎必须含有全部载荷（此前完全没有的一条链）', () {
    test('每个真实载荷都**整段原样**出现在最终引擎里', () {
      // 用整段比对而不是「挑一条特征行」：特征行会因为兄弟载荷里出现同名/同形的
      // 行而假绿（本轮负向验证实测过——删掉整个 caret 载荷，特征行版本照样全绿）。
      // 比对对象取压缩**之前**的引擎，因为载荷是字面拼接、压缩后才逐行剥注释。
      final Map<String, String> payloads = <String, String>{
        'selection': ReaderSelectionScripts.source(),
        'longPressDrag': ReaderSelectionScripts.longPressDragGestureScript(),
        'caret': ReaderCaretScripts.source(),
      };
      final Map<String, String> engines = <String, String>{
        'paged': readerHibikiEngineSourceUncompacted(),
        'continuous': readerHibikiEngineSourceUncompacted(continuousMode: true),
        'vn': readerHibikiEngineSourceUncompacted(vnMode: true),
      };
      engines.forEach((String mode, String engine) {
        payloads.forEach((String name, String payload) {
          expect(
            engine.contains(payload),
            isTrue,
            reason: '$mode 引擎里 $name 载荷不是整段在场 —— 拼装时漏装了一整块，'
                '而各 builder 自己的守卫看不到这一层',
          );
        });
      });
      // 每种模式还必须整段带上**自己那一份** shell。
      final Map<String, String> shells = <String, String>{
        'paged':
            _stripScriptTags(ReaderPaginationScripts.paginatedShellSource()),
        'continuous':
            _stripScriptTags(ReaderPaginationScripts.continuousShellSource()),
        'vn': _stripScriptTags(ReaderVisualNovelScripts.vnShellScript()),
      };
      shells.forEach((String mode, String shell) {
        expect(engines[mode]!.contains(shell), isTrue,
            reason: '$mode 引擎没有整段带上自己那一份 shell');
      });
    });

    test('每种模式只装自己那一份 shell，分流点仍在 JS 侧读运行时 C', () {
      const Map<String, String> expected = <String, String>{
        'paged': 'paginated',
        'continuous': 'continuous',
        'vn': 'vn',
      };
      final Map<String, String> engines = <String, String>{
        'paged': readerHibikiEngineSource(),
        'continuous': readerHibikiEngineSource(continuousMode: true),
        'vn': readerHibikiEngineSource(vnMode: true),
      };
      engines.forEach((String mode, String engine) {
        expect(
          engine
              .contains('window.__hoshiShells.${expected[mode]} = function(C)'),
          isTrue,
          reason: '\$mode 引擎必须装 \${expected[mode]} shell',
        );
        // 分流仍读运行时 C：Dart 只决定嵌哪一份，不决定运行时走哪条分支。
        expect(engine.contains('if (C.vnMode)'), isTrue);
        expect(engine.contains('if (C.continuousMode)'), isTrue);
        expect(engine.contains('window.__hoshiInstallShell(C);'), isTrue);
      });
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
      final String boot = readerHibikiEngineBoot(_sampleConfig());
      expect(
        boot.length,
        lessThan(4096),
        reason: 'per-nav 那一半必须只是 config；一旦有人把引擎本体拼回这里，'
            '引擎就不能再 memoize，每章又要重新拼装 + 压缩近万行',
      );
      expect(
        boot.contains(
            'window.__hoshiEngine.install(window.__fushiReaderConfig);'),
        isTrue,
      );
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

    test('per-nav 参数确实进了 config 字面量（含 cue 原样拼接）', () {
      final ReaderEngineConfig cfg = _sampleConfig(
        sasayakiCuesJson: '[{"id":"c1","start":0}]',
      );
      final String literal = cfg.toJsLiteral();
      final Map<String, dynamic> decoded =
          jsonDecode(literal) as Map<String, dynamic>;
      expect(decoded['initialProgress'], 0.42);
      expect(decoded['navigationGeneration'], 17);
      expect(decoded['chromeBottomInset'], 64);
      expect(decoded['furiganaMode'], 'toggle');
      expect(decoded['dartPageWidth'], 800);
      expect((decoded['sasayakiCues'] as List<dynamic>).length, 1);
      expect(_sampleConfig().toJsLiteral().contains('"sasayakiCues":null'),
          isTrue);
    });

    test('三种 shell 回传 immutable navigation generation', () {
      final String pagination = ReaderPaginationScripts.paginatedShellSource();
      final String continuous = ReaderPaginationScripts.continuousShellSource();
      final String vn = ReaderVisualNovelScripts.vnShellScript();
      for (final String shell in <String>[pagination, continuous, vn]) {
        expect(shell, contains("'onRestoreComplete'"));
        expect(
          shell,
          contains('C.navigationGeneration'),
          reason: 'restore 回调必须携带创建当前文档时捕获的代次',
        );
      }

      final String navigation = File(
        'lib/src/pages/implementations/reader_hibiki/navigation.part.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      final int gate = navigation.indexOf('void _acceptRestoreComplete({');
      final int effects = navigation.indexOf(
        "ReaderChapterPerfTrace.mark('jsInitRestore')",
        gate,
      );
      expect(gate, isNonNegative);
      expect(effects, greaterThan(gate));
      final String guarded = navigation.substring(gate, effects);
      expect(guarded, contains('isCurrentReaderRestoreCompletion('));
      expect(guarded, contains('reportedGeneration: reportedGeneration,'));
      expect(webview, contains('navigationGeneration: gen,'));
      expect(webview, contains('reportedGeneration: rawGeneration.toInt(),'));
    });
  });

  group('4. 时序保证（PR#461 / PR#469 建立的两条，不得被本改动动摇）', () {
    test('install 仍由 Dart 在 onLoadStop 之后一次 evaluateJavascript 触发', () {
      // 引擎源码 + boot 拼成同一份字符串、同一次注入，位置就是改动前
      // evaluateJavascript(整份 setup 脚本) 的那一处：docLoad 打点之后、
      // evalSetupScript 打点之前、同一个 _navigateGeneration 守卫下。
      final int buildIdx = webview.indexOf('final String setupScript =');
      final int evalIdx = webview
          .indexOf('await controller.evaluateJavascript(source: setupScript);');
      final int markIdx =
          webview.indexOf("ReaderChapterPerfTrace.mark('evalSetupScript')");
      expect(buildIdx, isNonNegative);
      expect(evalIdx, greaterThan(buildIdx));
      expect(markIdx, greaterThan(evalIdx));
      expect(
        readerHibikiEngineSource()
            .contains("if (document.readyState === 'complete')"),
        isTrue,
        reason: 'shell 的 load / readyState 双分支 boot 语义保持不变',
      );
    });

    test('注入仍是一次往返（不得拆成多次 evaluateJavascript）', () {
      // 实测那条通道的固定往返约 7.5ms、与载荷大小几乎无关，拆成两次就是白送 7.5ms。
      final int start =
          webview.indexOf('final ReaderEngineConfig engineConfig =');
      final int end = webview.indexOf(
          "ReaderChapterPerfTrace.mark('caretReanchor')", start);
      expect(start, isNonNegative);
      expect(end, greaterThan(start));
      expect(
        'evaluateJavascript('.allMatches(webview.substring(start, end)).length,
        1,
        reason: 'setup 注入必须保持单次往返',
      );
    });
  });

  group('5. 生成的 JS 真能解析（node --check）', () {
    test('引擎与 boot 都是合法 JS', () {
      final ProcessResult probe = _runNode(<String>['--version']);
      if (probe.exitCode != 0) {
        markTestSkipped('node 不可用，跳过真解析');
        return;
      }
      final Directory tmp = Directory.systemTemp.createTempSync('hoshi-engine');
      try {
        for (final MapEntry<String, String> entry in <String, String>{
          'paged': readerHibikiEngineSource(),
          'continuous': readerHibikiEngineSource(continuousMode: true),
          'vn': readerHibikiEngineSource(vnMode: true),
          'boot': readerHibikiEngineBoot(_sampleConfig()),
        }.entries) {
          final File f = File('${tmp.path}/${entry.key}.js')
            ..writeAsStringSync(entry.value);
          final ProcessResult r = _runNode(<String>['--check', f.path]);
          expect(r.exitCode, 0, reason: '${entry.key} 解析失败: ${r.stderr}');
        }
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
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
      navigationGeneration: 17,
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

String _stripScriptTags(String js) => js
    .replaceFirst(RegExp('^<script[^>]*>'), '')
    .replaceFirst(RegExp(r'</script>$'), '')
    .trim();

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show readerFushiEngineSource;
import 'package:fushi/src/reader/reader_engine_config.dart';

/// BUG-2471：阅读器设置改完不实时生效——边距 / 滑动灵敏度 / 滚轮静默窗 / 扫描非日文
/// 只在引擎 install 时从 `C` 读一次。修复后 `_applyStylesLive` 先经
/// [ReaderEngineConfig.liveUpdateInvocation] 把这份 patch 热更新进已 install 的
/// config（`window.__fushiEngine.updateLive`），再换 CSS + 重锚。
///
/// 三层：① Dart 侧 patch 编码；② 引擎源码 / 页面 / 设置 schema 的静态守卫；③ 用 node
/// 真跑 `updateLive` + `__fushiApplyReaderMargins`（`reader_engine_live_config_behavior_test.js`）。
void main() {
  group('ReaderEngineConfig.liveUpdateInvocation', () {
    test('encodes exactly the hot-updatable keys behind an engine guard', () {
      final String js = ReaderEngineConfig.liveUpdateInvocation(
        marginTop: 5,
        marginBottom: 6.5,
        marginLeft: 0,
        marginRight: 12,
        swipeDistThreshold: 44,
        swipeFastDistThreshold: 22,
        wheelGestureQuietMs: 300,
        scanNonJapaneseText: false,
      );
      expect(
        js,
        startsWith(
          '(window.__fushiEngine && '
          'window.__fushiEngine.updateLive) ? '
          'window.__fushiEngine.updateLive({',
        ),
      );
      expect(js, endsWith('}) : false;'));
      final int open = js.indexOf('{');
      final int close = js.lastIndexOf('}');
      final Map<String, dynamic> patch =
          jsonDecode(js.substring(open, close + 1)) as Map<String, dynamic>;
      expect(patch, <String, Object?>{
        'marginTop': 5,
        'marginBottom': 6.5,
        'marginLeft': 0,
        'marginRight': 12,
        'swipeDistThreshold': 44,
        'swipeFastDistThreshold': 22,
        'wheelGestureQuietMs': 300,
        'scanNonJapaneseText': false,
      });
      // 这些必须随 install 走，绝不能出现在热更新 patch 里。
      for (final String frozen in <String>[
        'navigationGeneration',
        'dartPageWidth',
        'dartPageHeight',
        'initialProgress',
        'chromeBottomInset',
        'continuousMode',
        'vnMode',
      ]) {
        expect(patch.containsKey(frozen), isFalse, reason: frozen);
      }
    });
  });

  group('source guards', () {
    final String engine = readerFushiEngineSource();
    final String page = File(
      'lib/src/pages/implementations/reader_fushi_page.dart',
    ).readAsStringSync();
    final String webview = File(
      'lib/src/pages/implementations/reader_fushi/webview.part.dart',
    ).readAsStringSync();

    test('engine exposes updateLive and remembers the margin viewport', () {
      expect('updateLive: function(patch) {'.allMatches(engine).length, 1);
      expect(
        engine,
        contains('window.__fushiReaderMarginsLast = { w: w, h: h };'),
        reason: '热更新边距要用上一次物化时的视口，不能等下一次 resize',
      );
      expect(
        engine,
        contains('window.__fushiApplyReaderMargins(last.w, last.h);'),
        reason: '边距变了必须当场重物化 --reader-margin-* 像素变量',
      );
      expect(
        engine,
        contains('window.scanNonJapaneseText = C.scanNonJapaneseText;'),
      );
      // updateLive 合并进的是 install 时的同一个对象（C === window.__fushiReaderConfig）。
      expect(engine, contains('var C = window.__fushiReaderConfig;'));
    });

    test('_applyStylesLive pushes the live patch before swapping CSS', () {
      final int live = page.indexOf('Future<void> _applyStylesLive() async {');
      expect(live, isNonNegative);
      final String body = page.substring(live, page.indexOf('\n  }\n', live));
      final int patchAt = body.indexOf('_liveEngineConfigJs()');
      final int cssAt = body.indexOf("getElementById('fushi-reader-style')");
      expect(patchAt, isNonNegative, reason: '热更新 patch 必须在 live 路径上下发');
      expect(cssAt, isNonNegative);
      expect(
        patchAt,
        lessThan(cssAt),
        reason: '先热更新内联像素变量，再换 CSS——顺序反了新样式表的回退值仍被旧变量遮住',
      );
      expect(
        body,
        contains(
          r'$liveConfigJs'
          '\n(function(){',
        ),
        reason: 'patch 与 CSS 换入拼在同一次 evaluateJavascript 里（不多一次往返）',
      );
      // 全局默认内容语言改了要重解析（字体族按语言选）。
      expect(body, contains('explicit: _explicitContentLanguage,'));
    });

    test('live patch derives thresholds exactly like the install config', () {
      final int at = webview.indexOf('String _liveEngineConfigJs() {');
      expect(at, isNonNegative);
      final String body = webview.substring(at, webview.indexOf('\n  }\n', at));
      expect(body, contains('ReaderSettings.swipePageTurnDistThresholds('));
      expect(body, contains('wheelPageTurnInterval.clamp(150, 800)'));
      expect(
        body,
        contains('scanNonJapaneseText: appModel.scanNonJapaneseText'),
      );
      expect(body, contains('ReaderEngineConfig.liveUpdateInvocation('));
      // install 那份用同一套派生（两处一起改，别漂）。
      final int cfg = webview.indexOf(
        'ReaderEngineConfig _buildReaderEngineConfig(',
      );
      final String cfgBody = webview.substring(
        cfg,
        webview.indexOf('\n  }\n', cfg),
      );
      expect(cfgBody, contains('ReaderSettings.swipePageTurnDistThresholds('));
      expect(cfgBody, contains('wheelPageTurnInterval.clamp(150, 800)'));
    });

    test('settings that feed the live patch notify the open reader', () {
      final String reading = File(
        'lib/src/settings/settings_schema_reading.dart',
      ).readAsStringSync();
      for (final String id in <String>[
        'reading_display.margin_top',
        'reading_display.margin_bottom',
        'reading_display.margin_left',
        'reading_display.margin_right',
        'reading_controls.wheel_page_turn_interval',
        'reading_controls.swipe_page_turn_sensitivity',
      ]) {
        final int at = reading.indexOf("id: '$id'");
        expect(at, isNonNegative, reason: id);
        final String item = reading.substring(
          at,
          reading.indexOf('\n          ),', at),
        );
        expect(
          item,
          matches(
            RegExp(r'notifyReaderSettingsChanged\((settingsContext|c)\)'),
          ),
          reason: '$id 改完必须打 onSettingsChangedLive，否则引擎里的值停在 install 时',
        );
      }
      final String lookup = File(
        'lib/src/settings/settings_schema_lookup.dart',
      ).readAsStringSync();
      final int scan = lookup.indexOf("id: 'lookup.scan_non_japanese'");
      expect(scan, isNonNegative);
      final String item = lookup.substring(
        scan,
        lookup.indexOf('\n          ),', scan),
      );
      expect(
        item,
        contains('notifyReaderSettingsChanged(settingsContext)'),
        reason: 'scan_non_japanese 曾只 refresh 设置页，开着的阅读器要重进章节才生效',
      );
    });
  });

  test(
    'updateLive re-materializes margins from the last viewport (node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
          'node not found on PATH; skipping JS behavior execution',
        );
        return;
      }
      final File jsTest = File(
        'test/reader/reader_engine_live_config_behavior_test.js',
      );
      expect(jsTest.existsSync(), isTrue);
      final ProcessResult result = await Process.run(
          nodeExe,
          <String>[
            jsTest.path,
          ],
          workingDirectory: Directory.current.path);
      expect(
        result.exitCode,
        0,
        reason: 'live config JS behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(
        result.stdout.toString(),
        contains('reader_engine_live_config_behavior_test: ok'),
      );
    },
  );
}

String? _resolveNode() {
  final List<String> candidates =
      Platform.isWindows ? <String>['node.exe', 'node'] : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) return name;
    } on ProcessException {
      continue;
    }
  }
  return null;
}

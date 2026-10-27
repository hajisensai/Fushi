// 「评分 → 下一张上屏」帧耗时探针（Windows 离屏 runner，手动跑）。
//
// 所有者报告：SRS 评分后下一张卡显示帧率低。本探针按真实路径（牌组列表页之上开复习页、
// 键盘 Space 翻面 / 3 评分，焦点驱动）量评分那一刻起 1.5 s 内：
// - 每帧 UI 线程 build、raster 耗时（FrameTiming）与相邻帧间隔（丢帧）；
// - 复习页各阶段时刻（[SrsReviewPage.debugPhase]：answer / show / 预取各步 / 计数 / 预览）；
// - 卡面 WebView 新内容首帧（页内 MutationObserver 双 rAF 回报）。
// 两种卡各量一轮：带图片 + 音频的 Lapis（整面 WebView 卡面）与 Fushi 卡片（原生 + 释义 WebView）。
// 结果打 `[srs-rate-frame]` 行，并写进隔离根 app-documents/srs_rate_frame_probe.txt。
//
//   .\tool\run_windows_itest.ps1 integration_test/srs_rate_next_frame_itest.dart
import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_deck_list_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/srs/srs_card_sample.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/startup/test_environment.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'helpers/library_fixture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _probeHandler = 'onSrsRateFramePaint';

/// 只量一种卡（`lapis` / `fushi`；空 = 两种都量）。
const String _only = String.fromEnvironment('FUSHI_PROBE_SRS_ONLY');

const String _probeScript =
    '''
(function(){
  if (window.__srsRateProbe) return;
  window.__srsRateProbe = true;
  var last = null;
  function text(){
    var r = document.getElementById('fushi-card-root') || document.body;
    return r ? r.textContent.replace(/\\s+/g, ' ').trim() : '';
  }
  function check(){
    var t = text();
    if (t === last) return;
    last = t;
    requestAnimationFrame(function(){ requestAnimationFrame(function(){
      if (window.flutter_inappwebview) window.flutter_inappwebview.callHandler('$_probeHandler', t.slice(0, 40));
    }); });
  }
  new MutationObserver(check).observe(document.documentElement, {subtree: true, childList: true, characterData: true});
  check();
})();
''';

void _log(String line) {
  final String full = '[srs-rate-frame] $line';
  debugPrint(full);
  final Directory? docs = fushiTestDirectory('app-documents');
  if (docs == null) return;
  File(
    p.join(docs.path, 'srs_rate_frame_probe.txt'),
  ).writeAsStringSync('$full\n', mode: FileMode.append, flush: true);
}

Future<void> _pumpFor(WidgetTester tester, Duration d) async {
  final Stopwatch sw = Stopwatch()..start();
  while (sw.elapsed < d) {
    await tester.pump(const Duration(milliseconds: 8));
  }
}

/// 44 字节头的 16 bit 单声道 PCM WAV（[seconds] 秒 440 Hz）。
Uint8List _wav(double seconds) {
  const int rate = 22050;
  final int n = (rate * seconds).round();
  final ByteData b = ByteData(44 + n * 2);
  void str(int at, String s) {
    for (int i = 0; i < s.length; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  b.setUint32(4, 36 + n * 2, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, rate, Endian.little);
  b.setUint32(28, rate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  str(36, 'data');
  b.setUint32(40, n * 2, Endian.little);
  for (int i = 0; i < n; i++) {
    final double v = math.sin(2 * math.pi * 440 * i / rate) * 0.05;
    b.setInt16(44 + i * 2, (v * 32767).round(), Endian.little);
  }
  return b.buffer.asUint8List();
}

/// 800×500 渐变 + 色块 PNG（卡面图片，量真实解码 / 合成成本）。
Future<Uint8List> _png() async {
  final ui.PictureRecorder rec = ui.PictureRecorder();
  final Canvas canvas = Canvas(rec);
  const Rect r = Rect.fromLTWH(0, 0, 800, 500);
  canvas.drawRect(
    r,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        const Offset(800, 500),
        <Color>[const Color(0xFF3366CC), const Color(0xFFCC6633)],
      ),
  );
  for (int i = 0; i < 40; i++) {
    canvas.drawCircle(
      Offset(20.0 * i, 12.0 * i),
      30,
      Paint()..color = Color(0xFF000000 | (i * 0x061F3B)),
    );
  }
  final ui.Image image = await rec.endRecording().toImage(800, 500);
  final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

class _Frame {
  _Frame(this.startUs, this.buildUs, this.rasterUs, this.totalUs);
  final int startUs;
  final int buildUs;
  final int rasterUs;
  final int totalUs;
}

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // 与真实 app 一样由引擎 vsync 驱动帧（动画不只在测试 pump 时前进）。
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('评分 → 下一张：帧耗时与阶段时间线', (WidgetTester tester) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    await tester.pump(const Duration(seconds: 2));
    final AppModel appModel = await readyAppModel(tester);
    await appModel.setModuleEnabled(ModuleId.srs, true);
    await _pumpFor(tester, const Duration(seconds: 1));

    final ProviderContainer container = ProviderScope.containerOf(
      appModel.navigatorKey.currentContext!,
    );
    final SrsDbStore store = (await container.read(srsStoreProvider.future))!;
    expect(store.canSchedule, isTrue, reason: 'FSRS 内核应可用');
    await store.ensureBuiltins();
    final SrsMediaStore media = (await container.read(
      srsMediaStoreProvider.future,
    ))!;
    media.root.createSync(recursive: true);
    final Uint8List png = (await tester.runAsync(_png))!;
    final Uint8List wav = _wav(0.6);
    final String uid = store.profileUid;

    // 真实规模的牌组列表（列表页在复习页底下，评分后的刷新信号会让它重读）。
    for (int i = 0; i < 30; i++) {
      await store.createDeck('牌组 $i');
    }
    final String lapisDeck = await store.createDeck('探针 Lapis');
    final String fushiDeck = await store.createDeck('探针 Fushi');
    final String longDefinition = List<String>.generate(
      30,
      (int i) => '定義の行 ${i + 1}：とても長い説明文がここに続きます。',
    ).join('<br>');
    for (int i = 0; i < 14; i++) {
      File(p.join(media.root.path, 'pic_$i.png')).writeAsBytesSync(png);
      File(p.join(media.root.path, 'word_$i.wav')).writeAsBytesSync(wav);
      File(p.join(media.root.path, 'sent_$i.wav')).writeAsBytesSync(wav);
      await store.createNote(
        noteTypeId: store.lapisNoteTypeId,
        deckId: lapisDeck,
        createdAt: 1700000000000 + i,
        fieldsById: <String, String>{
          srsLapisFieldId(uid, 'Expression'): '単語$i',
          srsLapisFieldId(uid, 'ExpressionReading'): 'たんご$i',
          srsLapisFieldId(uid, 'ExpressionAudio'): '[sound:word_$i.wav]',
          srsLapisFieldId(uid, 'MainDefinition'): '意味 $i<br>$longDefinition',
          srsLapisFieldId(uid, 'Sentence'): 'これは<b>単語$i</b>の例文です。',
          srsLapisFieldId(uid, 'SentenceAudio'): '[sound:sent_$i.wav]',
          srsLapisFieldId(uid, 'Picture'): '<img src="pic_$i.png">',
        },
      );
      final Map<String, String> fields = <String, String>{
        ...srsSampleCardFields(),
        'Expression': '通う$i',
        'Picture': '<img src="pic_$i.png">',
        'ExpressionAudio': '[sound:word_$i.wav]',
        'SentenceAudio': '[sound:sent_$i.wav]',
      };
      await store.createNote(
        noteTypeId: store.fushiCardNoteTypeId,
        deckId: fushiDeck,
        createdAt: 1700000100000 + i,
        fieldsById: <String, String>{
          for (final MapEntry<String, String> e in fields.entries)
            srsFushiCardFieldId(uid, e.key): e.value,
        },
      );
    }
    container.read(srsRevisionProvider.notifier).state++;

    // 真实入口：先到牌组列表页，复习页压在它上面。
    unawaited(
      appModel.navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (BuildContext _) => const SrsDeckListPage(),
        ),
      ),
    );
    await _pumpFor(tester, const Duration(seconds: 2));

    final List<_Frame> frames = <_Frame>[];
    void onTimings(List<FrameTiming> list) {
      for (final FrameTiming f in list) {
        frames.add(
          _Frame(
            f.timestampInMicroseconds(FramePhase.buildStart),
            f.buildDuration.inMicroseconds,
            f.rasterDuration.inMicroseconds,
            f.totalSpan.inMicroseconds,
          ),
        );
      }
    }

    SchedulerBinding.instance.addTimingsCallback(onTimings);
    // 每帧重建了多少 element、按 widget 类型计（看换卡那几帧是谁在整页重建）。
    final List<(int, Map<String, int>)> rebuilds = <(int, Map<String, int>)>[];
    Map<String, int> current = <String, int>{};
    debugOnRebuildDirtyWidget = (Element e, bool _) {
      final String k = e.widget.runtimeType.toString();
      current[k] = (current[k] ?? 0) + 1;
    };
    SchedulerBinding.instance.addPersistentFrameCallback((Duration _) {
      if (current.isNotEmpty) rebuilds.add((Timeline.now, current));
      current = <String, int>{};
    });
    final List<(int, String)> phases = <(int, String)>[];
    SrsReviewPage.debugPhase = (String phase) =>
        phases.add((Timeline.now, phase));

    final List<String> summary = <String>[];

    Future<void> runDeck(
      String label,
      String deckId, {
      required bool web,
    }) async {
      SrsWebCardFace.debugController = null;
      unawaited(
        appModel.navigatorKey.currentState!.push(
          MaterialPageRoute<void>(
            builder: (BuildContext _) =>
                SrsReviewPage(deckId: deckId, deckName: label),
          ),
        ),
      );
      final List<int> paintedAt = <int>[];
      if (web) {
        final Stopwatch wait = Stopwatch()..start();
        while (SrsWebCardFace.debugController == null &&
            wait.elapsed < const Duration(seconds: 30)) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        final InAppWebViewController c = SrsWebCardFace.debugController!;
        c.addJavaScriptHandler(
          handlerName: _probeHandler,
          callback: (List<dynamic> _) {
            paintedAt.add(Timeline.now);
            return null;
          },
        );
        await c.addUserScript(
          userScript: UserScript(
            source: _probeScript,
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
          ),
        );
        await c.evaluateJavascript(source: _probeScript);
      }
      await _pumpFor(tester, const Duration(seconds: 3));

      final List<double> maxBuild = <double>[];
      final List<double> maxGap = <double>[];
      final List<int> slow = <int>[];
      final List<double> paintMs = <double>[];
      final List<int> rebuiltTotals = <int>[];
      _log('$label opened');
      for (int n = 0; n < 10; n++) {
        _log('$label step $n');
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await _pumpFor(tester, const Duration(milliseconds: 700));
        frames.clear();
        phases.clear();
        final int paintFrom = paintedAt.length;
        final int t0 = Timeline.now;
        await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
        await _pumpFor(tester, const Duration(milliseconds: 1500));
        // FrameTiming 是批量回报的：再等一会儿把这段的帧收齐。
        await _pumpFor(tester, const Duration(milliseconds: 300));
        final List<_Frame> win = <_Frame>[
          for (final _Frame f in frames)
            if (f.startUs >= t0 && f.startUs <= t0 + 1500000) f,
        ];
        double gap = 0;
        for (int i = 1; i < win.length; i++) {
          gap = math.max(gap, (win[i].startUs - win[i - 1].startUs) / 1000);
        }
        final double build = win.isEmpty
            ? 0
            : win.map((_Frame f) => f.buildUs).reduce(math.max) / 1000;
        final double raster = win.isEmpty
            ? 0
            : win.map((_Frame f) => f.rasterUs).reduce(math.max) / 1000;
        final int over = win.where((_Frame f) => f.totalUs > 16667).length;
        maxBuild.add(build);
        maxGap.add(gap);
        slow.add(over);
        final String timeline = <String>[
          for (final (int at, String ph) in phases)
            '$ph@${((at - t0) / 1000).toStringAsFixed(1)}',
        ].join(' ');
        String painted = '-';
        if (paintedAt.length > paintFrom) {
          final double ms = (paintedAt[paintFrom] - t0) / 1000;
          paintMs.add(ms);
          painted = ms.toStringAsFixed(1);
        }
        _log(
          '$label #$n frames=${win.length} slow(>16.7ms)=$over '
          'maxBuild=${build.toStringAsFixed(1)} maxRaster=${raster.toStringAsFixed(1)} '
          'maxGap=${gap.toStringAsFixed(1)} webPaint=$painted ms | $timeline',
        );
        _log(
          '$label #$n frameList ${<String>[for (final _Frame f in win) '${((f.startUs - t0) / 1000).toStringAsFixed(0)}:b${(f.buildUs / 1000).toStringAsFixed(1)}/r${(f.rasterUs / 1000).toStringAsFixed(1)}'].join(' ')}',
        );
        int totalRebuilt = 0;
        final List<String> heavy = <String>[];
        for (final (int at, Map<String, int> m) in rebuilds) {
          if (at < t0 || at > t0 + 1500000) continue;
          final int sum = m.values.fold(0, (int a, int b) => a + b);
          totalRebuilt += sum;
          if (sum < 40) continue;
          final List<MapEntry<String, int>> top = m.entries.toList()
            ..sort(
              (MapEntry<String, int> a, MapEntry<String, int> b) =>
                  b.value.compareTo(a.value),
            );
          final String marks = <String>[
            for (final String k in const <String>[
              'SrsReviewPage',
              'SrsDeckListPage',
              'SrsFushiCardView',
              'SrsWebCardFace',
              'FushiFloatingTopBar',
            ])
              if (m.containsKey(k)) k,
          ].join(',');
          heavy.add(
            '${((at - t0) / 1000).toStringAsFixed(0)}ms n=$sum [$marks] '
            '${top.take(4).map((MapEntry<String, int> e) => '${e.key}:${e.value}').join(' ')}',
          );
        }
        rebuilds.clear();
        _log(
          '$label #$n rebuilt=$totalRebuilt heavyFrames: ${heavy.join(' | ')}',
        );
        rebuiltTotals.add(totalRebuilt);
        await _pumpFor(tester, const Duration(milliseconds: 300));
      }
      double mean(List<num> v) =>
          v.isEmpty ? 0 : v.reduce((num a, num b) => a + b) / v.length;
      final String line =
          '$label SUMMARY meanMaxBuild=${mean(maxBuild).toStringAsFixed(1)} '
          'meanMaxGap=${mean(maxGap).toStringAsFixed(1)} '
          'meanSlowFrames=${mean(slow).toStringAsFixed(1)} '
          'meanWebPaint=${mean(paintMs).toStringAsFixed(1)} ms '
          'meanRebuiltElements=${mean(rebuiltTotals).toStringAsFixed(0)}';
      summary.add(line);
      _log(line);
      appModel.navigatorKey.currentState!.pop();
      await _pumpFor(tester, const Duration(seconds: 1));
    }

    if (_only != 'fushi') await runDeck('lapis', lapisDeck, web: true);
    if (_only != 'lapis') await runDeck('fushi', fushiDeck, web: false);
    debugOnRebuildDirtyWidget = null;
    SchedulerBinding.instance.removeTimingsCallback(onTimings);
    SrsReviewPage.debugPhase = null;
    for (final String s in summary) {
      _log(s);
    }
  });
}

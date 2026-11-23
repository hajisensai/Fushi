@Tags(<String>['chrome'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/node_runtime.dart';

/// 有声书跟读的两种新跟随方式（反馈 tUJsiLpL9d / GitHub #3300，所有者拍板 A+B）。
///
/// 真 Chrome 跑生产 CSS + 引擎 shell，横排 / 竖排各一遍：
/// * 分页「读到页边就翻」（方案 A）：揭示一句跨页句时 shell 量出跨页分界
///   （`audioCuePageSplit`），分界前的字在句首页的正文框里、分界那个字不在；
///   `revealAudioCueTail` 恰好前进一页并让后半截露出来；同一句再揭示停在后半截页，
///   `dropAudioCueTail` 后回到句首页；整句在一页里的句子不报分界。
/// * 连续「整行对齐」（方案 B）：句子不在正文带内时，句首所在行的行框起始边对齐
///   正文起始边；整句已在带内时再揭示不滚；开关关掉时仍是旧的 15% 边距跟随。
void main() {
  const String pool =
      'あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわ'
      '山川空海花雨雪風森林春夏秋冬朝昼夜星月光音色声言葉心夢道町村駅橋窓扉部屋机椅子本紙筆';

  /// 互不相同的句子（每句只含会被计数的假名 / 汉字，句末一个「。」）。
  List<String> sentences() {
    final List<String> out = <String>[];
    for (int i = 0; i < 120; i++) {
      final int length = 45 + (i * 17) % 40;
      final StringBuffer b = StringBuffer();
      for (int k = 0; k < length; k++) {
        b.write(pool[(i * 7 + k * 13 + k * k) % pool.length]);
      }
      out.add(b.toString());
    }
    return out;
  }

  Future<String> page({
    required String writingMode,
    required String viewMode,
    required bool lineAlign,
  }) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    await settings.setWritingMode(writingMode);
    await settings.setViewMode(viewMode);
    final String css = ReaderContentStyles.css(settings: settings);
    final String engine = ReaderPaginationScripts.engineShell(
      vnMode: false,
      continuousMode: viewMode == 'continuous',
    );
    final List<String> texts = sentences();
    final List<Map<String, Object>> cues = <Map<String, Object>>[];
    final StringBuffer body = StringBuffer();
    int start = 0;
    for (int i = 0; i < texts.length; i++) {
      if (i % 30 == 0) body.write(i == 0 ? '<p>' : '</p><p>');
      body.write('${texts[i]}。');
      cues.add(<String, Object>{
        'id': 'c$i',
        'text': texts[i],
        'start': start,
        'length': texts[i].length,
      });
      start += texts[i].length;
    }
    body.write('</p>');
    final Map<String, Object?> config = <String, Object?>{
      'vnMode': false,
      'continuousMode': viewMode == 'continuous',
      'dartPageWidth': 1280,
      'dartPageHeight': 800,
      'chromeTopInset': 0,
      'chromeBottomInset': 0,
      'initialCharOffset': -1,
      'initialProgress': 0,
      'initialFragment': null,
      'sentenceAudioCues': cues,
      'perfTraceEnabled': false,
      'vnRevealSpeed': 0,
      'vnSentencesPerScreen': 4,
      'vnScreenMode': 'sentences',
      'vnPreserveDialogue': true,
      'vnMergeCrossScreenSentenceAudioCues': false,
      'audiobookLineAlignFollow': lineAlign,
      'navigationGeneration': 1,
      'revealedKeys': <String>[],
      'blurImages': false,
    };
    return '<!doctype html><html><head><meta charset="utf-8">'
        '<style id="fushi-reader-style">$css</style>'
        '<script>window.__fushiRestored = new Promise(function(r) '
        '{ window.__fushiMarkRestored = r; });'
        'window.flutter_inappwebview = { callHandler: function(name) '
        '{ if (name === "onRestoreComplete") window.__fushiMarkRestored(); '
        'return Promise.resolve(null); } };'
        'window.__fushiApplyReaderMargins = function() {};'
        'window.__cueIds = ${jsonEncode(<String>[for (final Map<String, Object> c in cues) c['id']! as String])};'
        '</script></head><body>$body'
        '<script>${ReaderSelectionScripts.source()}</script>$engine'
        '<script>window.__harnessConfig = ${jsonEncode(config)}; window.__fushiInstallShell(window.__harnessConfig);</script>'
        '</body></html>';
  }

  test(
    'paginated page-edge turn and continuous line align follow the cue',
    () async {
      final String? nodeExe = resolveNodeExecutable();
      if (nodeExe == null) {
        markTestSkipped('node not found on PATH; skipping JS execution');
        return;
      }
      final List<Map<String, String>> paginated = <Map<String, String>>[];
      final List<Map<String, String>> continuous = <Map<String, String>>[];
      for (final String writingMode in <String>[
        'vertical-rl',
        'horizontal-tb',
      ]) {
        paginated.add(<String, String>{
          'name': '$writingMode/paginated',
          'html': await page(
            writingMode: writingMode,
            viewMode: 'paginated',
            lineAlign: true,
          ),
        });
        continuous.add(<String, String>{
          'name': '$writingMode/continuous',
          'html': await page(
            writingMode: writingMode,
            viewMode: 'continuous',
            lineAlign: true,
          ),
        });
      }
      final Map<String, Object> payload = <String, Object>{
        'paginated': paginated,
        'continuous': continuous,
      };
      // 留一份给本机直接 `node test/reader/audiobook_follow_style_harness.mjs < 它` 调试。
      File(
        '${Directory.systemTemp.path}/fushi_audiobook_follow_payload.json',
      ).writeAsStringSync(jsonEncode(payload));
      final NodeHarnessResult run = await runNodeHarness(
        nodeExe,
        'test/reader/audiobook_follow_style_harness.mjs',
        payload,
        timeout: const Duration(seconds: 100),
      );
      if (run.exitCode == 77) {
        markTestSkipped('Chrome unavailable: ${run.stdout}');
        return;
      }
      expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
      expect(
        run.stdout,
        contains('PASS 2 paginated pages, 2 continuous pages'),
      );
    },
    timeout: const Timeout(Duration(seconds: 150)),
  );
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle_auto_align.dart';
import 'package:fushi/src/media/video/subtitle_capture_align.dart';
import 'package:fushi/src/sync/fushi_extension_api_core.dart';

/// 反馈 0wkJImhZUp：浏览器扩展边播边听的「窗口 + 空洞」包络 → app 自动对轴算法。

/// 一段不规则的「对白」：(起, 止) 毫秒，相对窗口起点。间隔各不相同，互相关只有一个峰。
const List<(int, int)> _speech = <(int, int)>[
  (1200, 3100),
  (4000, 4700),
  (6900, 9800),
  (11000, 11600),
  (13900, 17000),
  (18200, 19100),
  (22500, 25400),
  (26100, 26900),
  (29800, 33500),
  (35000, 35800),
  (38700, 41900),
  (43300, 44000),
  (47100, 50600),
  (52000, 53300),
  (55900, 58700),
];

const int _windowStartMs = 600000; // 窗口从媒体 10:00 起（不是 0）
const int _bins = 600; // 60 秒 @ 100ms

List<double?> _envelope() {
  final List<double?> out = List<double?>.filled(_bins, -62.0);
  for (final (int s, int e) in _speech) {
    for (int i = s ~/ 100; i < e ~/ 100 && i < _bins; i++) {
      out[i] = -18.0;
    }
  }
  return out;
}

/// 字幕比声音早 [earlyMs]（cue 的媒体时间 = 对白时间 − earlyMs）。
List<({int startMs, int endMs})> _cues(int earlyMs) =>
    <({int startMs, int endMs})>[
      for (final (int s, int e) in _speech)
        (
          startMs: _windowStartMs + s - earlyMs,
          endMs: _windowStartMs + e - earlyMs,
        ),
    ];

void main() {
  group('alignCuesToCapturedEnvelope', () {
    test('窗口不从 0 起：按窗口起点平移后求出字幕要延后的量', () {
      final SubtitleAutoAlignResult r = alignCuesToCapturedEnvelope(
        rmsDb: _envelope(),
        startMs: _windowStartMs,
        cues: _cues(1500),
      );
      expect(r.status, SubtitleAutoAlignStatus.aligned);
      expect(r.offsetMs, 1500);
    });

    test('字幕偏晚 → 负偏移', () {
      final SubtitleAutoAlignResult r = alignCuesToCapturedEnvelope(
        rmsDb: _envelope(),
        startMs: _windowStartMs,
        cues: _cues(-2300),
      );
      expect(r.status, SubtitleAutoAlignStatus.aligned);
      expect(r.offsetMs, -2300);
    });

    test('拖动进度条留下的空洞（null）不拖歪峰值', () {
      final List<double?> env = _envelope();
      for (int i = 180; i < 320; i++) {
        env[i] = null;
      }
      final SubtitleAutoAlignResult r = alignCuesToCapturedEnvelope(
        rmsDb: env,
        startMs: _windowStartMs,
        cues: _cues(800),
      );
      expect(r.status, SubtitleAutoAlignStatus.aligned);
      expect(r.offsetMs, 800);
    });

    test('听到的不足最小样本量 → noData（不拿几秒钟乱平移）', () {
      final List<double?> env = _envelope();
      for (int i = kCaptureAlignMinCapturedBins - 1; i < _bins; i++) {
        env[i] = null;
      }
      expect(
        alignCuesToCapturedEnvelope(
          rmsDb: env,
          startMs: _windowStartMs,
          cues: _cues(0),
        ),
        SubtitleAutoAlignResult.noData,
      );
    });

    test('窗口里没有 cue / 空输入 → noData', () {
      expect(
        alignCuesToCapturedEnvelope(
          rmsDb: _envelope(),
          startMs: 0,
          cues: _cues(0), // 全在 10:00 之后，窗口 [0, 60s) 内一条都没有
        ),
        SubtitleAutoAlignResult.noData,
      );
      expect(
        alignCuesToCapturedEnvelope(
          rmsDb: const <double?>[],
          startMs: 0,
          cues: _cues(0),
        ),
        SubtitleAutoAlignResult.noData,
      );
    });
  });

  group('buildCaptureAlignResponse / /api/subtitle/align', () {
    Map<String, dynamic> body({Object? binMs = 100}) => <String, dynamic>{
      'binMs': binMs,
      'startMs': _windowStartMs,
      'rmsDb': _envelope(),
      'cues': <Map<String, int>>[
        for (final ({int startMs, int endMs}) c in _cues(1200))
          <String, int>{'startMs': c.startMs, 'endMs': c.endMs},
      ],
    };

    test('合法体 → aligned + 偏移量', () {
      final Map<String, dynamic>? out = buildCaptureAlignResponse(body());
      expect(out, isNotNull);
      expect(out!['status'], 'aligned');
      expect(out['offsetMs'], 1200);
      expect(out['confidence'], greaterThan(kSubtitleAutoAlignMinConfidence));
    });

    test('栅格不是 100ms / 缺字段 / cue 写歪 → null（HTTP 400）', () {
      expect(buildCaptureAlignResponse(body(binMs: 20)), isNull);
      expect(buildCaptureAlignResponse(<String, dynamic>{}), isNull);
      expect(
        buildCaptureAlignResponse(<String, dynamic>{
          ...body(),
          'cues': <Object>['x'],
        }),
        isNull,
      );
      expect(
        buildCaptureAlignResponse(<String, dynamic>{
          ...body(),
          'rmsDb': List<double>.filled(kCaptureAlignMaxBins + 1, -20),
        }),
        isNull,
      );
    });

    test('端点挂在扩展核心上：路径登记 + 400 + 成功体', () async {
      expect(
        FushiExtensionApiCore.paths,
        contains(FushiExtensionApiCore.subtitleAlignPath),
      );
      final FushiExtensionApiCore core = FushiExtensionApiCore();
      final FushiExtensionApiResponse bad = await core.handle(
        FushiExtensionApiCore.subtitleAlignPath,
        <String, dynamic>{},
      );
      expect(bad.status, 400);
      final FushiExtensionApiResponse ok = await core.handle(
        FushiExtensionApiCore.subtitleAlignPath,
        body(),
      );
      expect(ok.ok, isTrue);
      expect(ok.json!['offsetMs'], 1200);
    });

    test('扩展侧开算门槛不低于服务端最小样本量（两边同一口径）', () {
      final String js = File(
        '../tools/browser-extension/subtitle-align.js',
      ).readAsStringSync();
      final RegExpMatch? m = RegExp(
        r'AUTO_MIN_CAPTURED_MS = (\d+);',
      ).firstMatch(js);
      expect(m, isNotNull, reason: 'subtitle-align.js 缺 AUTO_MIN_CAPTURED_MS');
      expect(
        int.parse(m!.group(1)!),
        greaterThanOrEqualTo(
          kCaptureAlignMinCapturedBins * kSubtitleAutoAlignBinMs,
        ),
      );
      expect(js, contains('BIN_MS = $kSubtitleAutoAlignBinMs;'));
    });
  });
}

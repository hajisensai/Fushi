import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/audio_energy_probe.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_controller.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_waveform.dart';
import 'package:fushi_anki/fushi_anki_core.dart';

import 'advanced_mining_test_host.dart';

/// 高级制卡「句子音频」可拖波形：拖动几何（纯函数）、拖动结果怎么并进偏移（控制器）、
/// ffmpeg 只读一段音频（`-ss`），以及接线（本机文件才给波形加载器、对话框用选区）。
void main() {
  group('pickWaveformDragMode', () {
    test('手柄附近取近的那根；两根都够得着取近的', () {
      expect(
        pickWaveformDragMode(x: 102, startX: 100, endX: 300),
        WaveformDragMode.start,
      );
      expect(
        pickWaveformDragMode(x: 296, startX: 100, endX: 300),
        WaveformDragMode.end,
      );
      expect(
        pickWaveformDragMode(x: 108, startX: 100, endX: 112),
        WaveformDragMode.end,
      );
    });

    test('选区内部整段平移；选区外就近拖一根边过去', () {
      expect(
        pickWaveformDragMode(x: 200, startX: 100, endX: 300),
        WaveformDragMode.move,
      );
      expect(
        pickWaveformDragMode(x: 20, startX: 100, endX: 300),
        WaveformDragMode.start,
      );
      expect(
        pickWaveformDragMode(x: 380, startX: 100, endX: 300),
        WaveformDragMode.end,
      );
    });
  });

  group('applyWaveformDrag', () {
    ({int startMs, int endMs}) drag(
      WaveformDragMode mode,
      int pointer, {
      int grab = 0,
    }) => applyWaveformDrag(
      mode: mode,
      pointerMs: pointer,
      grabOffsetMs: grab,
      startMs: 10000,
      endMs: 14000,
      domainStartMs: 2000,
      domainEndMs: 22000,
    );

    test('拖起点 / 终点：只动那一根', () {
      expect(drag(WaveformDragMode.start, 8000), (startMs: 8000, endMs: 14000));
      expect(drag(WaveformDragMode.end, 17000), (startMs: 10000, endMs: 17000));
    });

    test('两根边不能越过对方：至少隔最短选区', () {
      const int min = AdvancedMiningController.kMinAudioWindowMs;
      expect(drag(WaveformDragMode.start, 99999).startMs, 14000 - min);
      expect(drag(WaveformDragMode.end, 0).endMs, 10000 + min);
    });

    test('夹在波形域内', () {
      expect(drag(WaveformDragMode.start, -5000).startMs, 2000);
      expect(drag(WaveformDragMode.end, 99999).endMs, 22000);
    });

    test('整段平移：保持时长、跟手不跳、不出域', () {
      // 在区间起点右 1500ms 处按下，指针到 9000 → 起点 7500。
      expect(drag(WaveformDragMode.move, 9000, grab: 1500), (
        startMs: 7500,
        endMs: 11500,
      ));
      expect(drag(WaveformDragMode.move, -9000, grab: 1500).startMs, 2000);
      final ({int startMs, int endMs}) right = drag(
        WaveformDragMode.move,
        99999,
        grab: 1500,
      );
      expect(right.endMs, 22000);
      expect(right.endMs - right.startMs, 4000);
    });
  });

  test('waveformPixelToMs：线性、夹在域内、非法输入退回域起点', () {
    expect(
      waveformPixelToMs(
        x: 150,
        width: 300,
        domainStartMs: 2000,
        domainEndMs: 22000,
      ),
      12000,
    );
    expect(
      waveformPixelToMs(
        x: -40,
        width: 300,
        domainStartMs: 2000,
        domainEndMs: 22000,
      ),
      2000,
    );
    expect(
      waveformPixelToMs(
        x: 150,
        width: 0,
        domainStartMs: 2000,
        domainEndMs: 22000,
      ),
      2000,
    );
  });

  group('AdvancedMiningController.setAudioWindow', () {
    late FakeAdvancedMiningHost host;
    setUp(() => host = FakeAdvancedMiningHost());

    Future<AdvancedMiningController> loaded() async {
      final AdvancedMiningController c = AdvancedMiningController(
        host.videoPage(),
      );
      await c.load();
      await pumpEventQueue();
      return c;
    }

    test('拖出的区间并进与微调同一对偏移，写卡覆盖项一致', () async {
      final AdvancedMiningController c = await loaded();
      final AdvancedMiningAudioWindow w = c.audioWindow!;
      c.setAudioWindow(startMs: w.startMs - 1500, endMs: w.endMs + 500);
      await pumpEventQueue();
      expect(host.describeCalls.last, <int>[-1500, 500]);
      final MiningRequestOverrides o = c.buildOverrides();
      expect(o.audioStartDeltaMs, -1500);
      expect(o.audioEndDeltaMs, 500);
      expect(c.audioWindow!.startMs, w.startMs - 1500);
    });

    test('拖动与微调按钮可以混用：偏移累加而不是互相覆盖', () async {
      final AdvancedMiningController c = await loaded();
      final AdvancedMiningAudioWindow w = c.audioWindow!;
      c.setAudioWindow(startMs: w.startMs - 1000, endMs: w.endMs);
      c.nudgeAudioEdge(start: true, deltaMs: -250);
      await pumpEventQueue();
      expect(c.buildOverrides().audioStartDeltaMs, -1250);
    });

    test('短于最短选区的拖动被拒绝，偏移不变', () async {
      final AdvancedMiningController c = await loaded();
      final AdvancedMiningAudioWindow w = c.audioWindow!;
      c.setAudioWindow(startMs: w.startMs + 1000, endMs: w.startMs + 1050);
      await pumpEventQuiet();
      expect(c.buildOverrides().audioStartDeltaMs, 0);
      expect(c.buildOverrides().audioEndDeltaMs, 0);
    });
  });

  group('buildFfmpegPcmEnvelopeArgs 只读一段音频', () {
    test('startMs → 输入端 -ss（在 -i 之前），秒数三位小数', () {
      final List<String> args = buildFfmpegPcmEnvelopeArgs(
        inputPath: '/tmp/v.mkv',
        startMs: 12500,
        limitSeconds: 20,
      );
      final int ss = args.indexOf('-ss');
      expect(ss, isNonNegative);
      expect(args[ss + 1], '12.500');
      expect(ss, lessThan(args.indexOf('-i')));
      expect(args.indexOf('-t'), lessThan(args.indexOf('-i')));
    });

    test('不给 startMs（或 0）就没有 -ss，原有参数不变', () {
      expect(
        buildFfmpegPcmEnvelopeArgs(inputPath: '/tmp/v.mkv'),
        isNot(contains('-ss')),
      );
      expect(
        buildFfmpegPcmEnvelopeArgs(inputPath: '/tmp/v.mkv', startMs: 0),
        isNot(contains('-ss')),
      );
    });
  });

  test('接线：本机文件才给波形加载器，对话框音频区用可拖选区', () {
    final String host = File(
      'lib/src/pages/implementations/video_fushi/advanced_mining.part.dart',
    ).readAsStringSync();
    expect(host, contains('loadWaveform: localSource == null'));
    expect(host, contains('extractAudioEnergyEnvelope('));
    final String sections = File(
      'lib/src/mining/advanced_mining/advanced_mining_sections.dart',
    ).readAsStringSync();
    expect(sections, contains('AdvancedMiningWaveformSelector('));
    expect(sections, contains('c.audioSection!.loadWaveform == null'));
  });
}

/// 等一小会儿让（不该发生的）describe 回调有机会落地，再断言偏移没变。
Future<void> pumpEventQuiet() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

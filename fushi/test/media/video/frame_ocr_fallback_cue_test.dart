import 'dart:io';

import 'package:fushi/src/media/video/player_decoded_subtitle_cues.dart';
import 'package:fushi/src/mining/advanced_mining/video_advanced_mining.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart'
    show miningClipTimeMs;
import 'package:fushi_anki/fushi_anki_core.dart' show MiningRequestOverrides;
import 'package:fushi_audio/fushi_audio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 硬字幕（烧进画面、没有字幕轨）上暂停 OCR 点字查词：mpv 没有 `sub-start`，制卡区间
/// 以前塌成 `0..0`（无句子音频，高级制卡的起止偏移也加不出区间）。修复给一个「暂停位置
/// 往前几秒」的默认窗口；这里钉住窗口怎么建，以及它经制卡链路（字幕轴 → 播放器轴 →
/// 高级制卡偏移）后是不是用户期望的那一段。
void main() {
  test('接线：暂停 OCR 点字在没有图形锚点时回落 frameOcrFallbackCue', () {
    final String source = File(
      'lib/src/pages/implementations/video_fushi_page.dart',
    ).readAsStringSync();
    final int start = source.indexOf('_handleGraphicSubtitleOcrLookupTap(');
    expect(start, isNonNegative);
    final String body = source.substring(start, start + 2500);
    expect(body, contains('currentGraphicSubtitleCue'));
    expect(body, contains('frameOcrFallbackCue'));
  });

  group('buildFrameOcrFallbackCue', () {
    test('窗口 = 暂停位置往前 kFrameOcrFallbackWindowMs，文本用 OCR 句', () {
      final AudioCue? cue = buildFrameOcrFallbackCue(
        text: ' 走り出した。\r\n',
        positionMs: 60000,
        delayMs: 0,
      );
      expect(cue, isNotNull);
      expect(cue!.startMs, 60000 - kFrameOcrFallbackWindowMs);
      expect(cue.endMs, 60000);
      expect(cue.text, '走り出した。');
    });

    test('位置不足一个窗口时下界夹到 0', () {
      final AudioCue? cue = buildFrameOcrFallbackCue(
        text: '走り出した。',
        positionMs: 1500,
        delayMs: 0,
      );
      expect(cue!.startMs, 0);
      expect(cue.endMs, 1500);
    });

    test('位置在片头 0 → null（没有窗口可裁）', () {
      expect(
        buildFrameOcrFallbackCue(text: '走り出した。', positionMs: 0, delayMs: 0),
        isNull,
      );
    });

    test('OCR 文本为空 → null', () {
      expect(
        buildFrameOcrFallbackCue(text: '  ', positionMs: 60000, delayMs: 0),
        isNull,
      );
    });

    test('有调轴：cue 在字幕轴，经 miningClipTimeMs 加回 delay 后落在播放器轴', () {
      const int delayMs = 750;
      final AudioCue cue = buildFrameOcrFallbackCue(
        text: '走り出した。',
        positionMs: 60000,
        delayMs: delayMs,
      )!;
      expect(
        miningClipTimeMs(cue.startMs, delayMs),
        60000 - kFrameOcrFallbackWindowMs,
      );
      expect(miningClipTimeMs(cue.endMs, delayMs), 60000);
    });

    test('经高级制卡偏移：起点往前拉 1.5 秒，窗口真的变长（0..0 时加不出区间）', () {
      final AudioCue cue = buildFrameOcrFallbackCue(
        text: '走り出した。',
        positionMs: 60000,
        delayMs: 0,
      )!;
      final VideoMiningRange base = (
        clipStartMs: miningClipTimeMs(cue.startMs, 0),
        clipEndMs: miningClipTimeMs(cue.endMs, 0),
        stillFrameAtMs: 60000,
        sentence: cue.text,
        cueSentence: cue.text,
      );
      final VideoMiningRange adjusted = applyVideoMiningOverrides(
        base,
        const MiningRequestOverrides(audioStartDeltaMs: -1500),
      );
      expect(adjusted.clipStartMs, base.clipStartMs - 1500);
      expect(adjusted.clipEndMs, base.clipEndMs);
    });
  });
}

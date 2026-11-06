import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/creator/mining_tts_fallback.dart';
import 'package:fushi/src/lookup/gal_line_tts.dart';
import 'package:fushi/src/media/audiobook/audiobook_speed_slider.dart';
import 'package:fushi/src/utils/misc/playback_speed.dart';

void main() {
  test('吸附到 0.05× 一档并夹进 0.25×–3.0×，结果是精确的最近 double', () {
    expect(snapPlaybackSpeed(1.234), 1.25);
    expect(snapPlaybackSpeed(1.149), 1.15);
    expect(snapPlaybackSpeed(0.1), kPlaybackSpeedMin);
    expect(snapPlaybackSpeed(9), kPlaybackSpeedMax);
    expect(snapPlaybackSpeed(1.0 + 0.1 + 0.1 + 0.1), 1.3);
  });

  test('档数与范围、步长一致', () {
    expect(
      ((kPlaybackSpeedMax - kPlaybackSpeedMin) / kPlaybackSpeedStep).round(),
      kPlaybackSpeedDivisions,
    );
  });

  test('有声书 / 台词 TTS / 兜底发音三处倍速共用同一范围与吸附', () {
    expect(AudiobookSpeedSlider.minSpeed, kPlaybackSpeedMin);
    expect(AudiobookSpeedSlider.maxSpeed, kPlaybackSpeedMax);
    expect(AudiobookSpeedSlider.divisions, kPlaybackSpeedDivisions);
    expect(AudiobookSpeedSlider.snap(2.333), snapPlaybackSpeed(2.333));
    expect(kGalLineTtsSpeedMin, kPlaybackSpeedMin);
    expect(kGalLineTtsSpeedMax, kPlaybackSpeedMax);
    expect(kTtsFallbackSpeedMin, kPlaybackSpeedMin);
    expect(kTtsFallbackSpeedMax, kPlaybackSpeedMax);
  });
}

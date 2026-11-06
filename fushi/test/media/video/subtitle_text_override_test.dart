import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle_text_override.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// 视频字幕文本覆盖层（反馈 gleDreKAvo / dpAsMkUjKT）：用户手改的单条字幕按
/// `(startMs, 原文)` 命中，换源 / 重载后幂等重套，还原换回原 cue。
AudioCue _cue(int index, int start, String text, {SubtitleMarkup? markup}) =>
    AudioCue()
      ..bookKey = ''
      ..chapterHref = ''
      ..sentenceIndex = index
      ..textFragmentId = ''
      ..text = text
      ..startMs = start
      ..endMs = start + 900
      ..audioFileIndex = 0
      ..markup = markup;

void main() {
  group('applySubtitleTextOverrides', () {
    final SubtitleTextOverrides overrides = SubtitleTextOverrides(
      <(int, String), String>{(1000, '間違った字幕'): '正しい字幕'},
    );

    test('按 (起点, 原文) 命中换文本，原 cue 挂在 uneditedCue 上', () {
      final AudioCue a = _cue(0, 0, '一行目');
      final AudioCue b = _cue(1, 1000, '間違った字幕');
      final List<AudioCue> out = applySubtitleTextOverrides(<AudioCue>[
        a,
        b,
      ], overrides);
      expect(identical(out[0], a), isTrue, reason: '没改的句子原样复用');
      expect(out[1].text, '正しい字幕');
      expect(out[1].startMs, 1000);
      expect(out[1].endMs, 1900);
      expect(identical(out[1].uneditedCue, b), isTrue);
      expect(out[1].sourceText, '間違った字幕');
      expect(b.text, '間違った字幕', reason: '原 cue（可能在缓存里）不被就地改');
    });

    test('一条都没命中时返回原列表本身', () {
      final List<AudioCue> cues = <AudioCue>[_cue(0, 0, '一行目')];
      expect(
        identical(applySubtitleTextOverrides(cues, overrides), cues),
        isTrue,
      );
    });

    test('同起点但原文不同（字幕源变了 / 重新识别）不误套', () {
      final List<AudioCue> cues = <AudioCue>[_cue(0, 1000, '別の文')];
      expect(applySubtitleTextOverrides(cues, overrides).single.text, '別の文');
    });

    test('幂等：已改副本再套一遍不变；覆盖删掉后换回原 cue', () {
      final AudioCue b = _cue(1, 1000, '間違った字幕');
      final List<AudioCue> once = applySubtitleTextOverrides(<AudioCue>[
        b,
      ], overrides);
      final List<AudioCue> twice = applySubtitleTextOverrides(once, overrides);
      expect(identical(twice, once), isTrue);
      final List<AudioCue> restored = applySubtitleTextOverrides(
        once,
        SubtitleTextOverrides.empty,
      );
      expect(identical(restored.single, b), isTrue);
    });

    test('改后文本保留整句位置与 cue 级样式，丢掉按原文下标的行内区间', () {
      const SubtitleMarkup markup = SubtitleMarkup(
        plainText: '間違った字幕',
        spans: <SubtitleSpan>[
          SubtitleSpan(startGrapheme: 0, endGrapheme: 3, bold: true),
        ],
        posFraction: SubtitlePos(0.5, 0.1),
        lineBreakGraphemes: <int>[3],
        layer: 2,
      );
      final AudioCue edited = applySubtitleTextOverride(
        _cue(1, 1000, '間違った字幕', markup: markup),
        overrides,
      );
      expect(edited.markup!.plainText, '正しい字幕');
      expect(edited.markup!.spans, isEmpty);
      expect(edited.markup!.lineBreakGraphemes, isEmpty);
      expect(edited.markup!.posFraction, markup.posFraction);
      expect(edited.markup!.layer, 2);
    });

    test('落库永远写原文', () {
      final AudioCue edited = applySubtitleTextOverride(
        _cue(1, 1000, '間違った字幕'),
        overrides,
      );
      expect(AudioCue.toCompanion(edited).cueText.value, '間違った字幕');
    });
  });

  group('覆盖层键', () {
    test('外挂文件只取文件名（不存绝对路径）', () {
      expect(
        subtitleTextOverrideSourceKey(
          r'C:\Users\a\Documents\video_subtitles\ep01.ja.srt',
        ),
        'file:ep01.ja.srt',
      );
      expect(
        subtitleTextOverrideSourceKey(
          '/data/user/0/app/video_subtitles/ep01.srt',
        ),
        'file:ep01.srt',
      );
    });

    test('内封 / 在线轨键原样，默认字幕为空串', () {
      expect(subtitleTextOverrideSourceKey('embedded:2'), 'embedded:2');
      expect(subtitleTextOverrideSourceKey('yt:ja:asr'), 'yt:ja:asr');
      expect(subtitleTextOverrideSourceKey(null), '');
      expect(subtitleTextOverrideSourceKey('  '), '');
    });

    test('视频键：第 1 集就是 uid，之后带集下标', () {
      expect(subtitleTextOverrideVideoKey('uid', 0), 'uid');
      expect(subtitleTextOverrideVideoKey('uid', 3), 'uid#3');
    });
  });

  group('VideoPlayerController 覆盖层', () {
    final SubtitleTextOverrides overrides = SubtitleTextOverrides(
      <(int, String), String>{(1000, '間違った字幕'): '正しい字幕'},
    );

    test('setCueTextOverrides 就地换文本，下标不动；之后 setCues 新列表也套用', () {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue(0, 0, '一行目'), _cue(1, 1000, '間違った字幕')]);
      int notified = 0;
      c.addListener(() => notified++);
      c.setCueTextOverrides(overrides);
      expect(c.cues.map((AudioCue e) => e.text), <String>['一行目', '正しい字幕']);
      expect(notified, 1);
      // 同一份覆盖再设一次：没有变化，不通知。
      c.setCueTextOverrides(overrides);
      expect(notified, 1);

      // 重载（换集回来 / 重新解析出同一份字幕）：新列表照样命中。
      c.setCues(<AudioCue>[_cue(1, 1000, '間違った字幕')]);
      expect(c.cues.single.text, '正しい字幕');

      // 还原：清掉覆盖，换回原文。
      c.setCueTextOverrides(SubtitleTextOverrides.empty);
      expect(c.cues.single.text, '間違った字幕');
      expect(c.cues.single.uneditedCue, isNull);
    });
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/player_decoded_subtitle_cues.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG-2648：兼容层 Emby 抽不出的内嵌文本轨，此前交给 libmpv 自绘——字画进画面、
/// 不可点击查词、字幕列表为空。现在 libmpv 只解码，`sub-text` + `sub-start` /
/// `sub-end` 回流成可点 cue，边播边累积。
AudioCue _cue(String text, int start, int end) => buildPlayerDecodedCue(
  text: text,
  startMs: start,
  endMs: end,
  positionMs: start,
)!;

void main() {
  group('parseMpvSecondsToMs', () {
    test('mpv 秒值字符串 → 毫秒', () {
      expect(parseMpvSecondsToMs('12.345000'), 12345);
      expect(parseMpvSecondsToMs(' 0.5 '), 500);
    });
    test('无当前字幕（空串 / 非数 / 负值）→ null', () {
      expect(parseMpvSecondsToMs(''), isNull);
      expect(parseMpvSecondsToMs('nan'), isNull);
      expect(parseMpvSecondsToMs('-1'), isNull);
    });
  });

  group('buildPlayerDecodedCue', () {
    test('空白文本（句间空档）不产 cue', () {
      expect(
        buildPlayerDecodedCue(
          text: ' \n',
          startMs: 1000,
          endMs: 2000,
          positionMs: 1000,
        ),
        isNull,
      );
    });

    test('mpv 起止时间直接成为 cue 区间，CRLF 归一', () {
      final AudioCue cue = buildPlayerDecodedCue(
        text: 'こんにちは\r\n世界',
        startMs: 1000,
        endMs: 2500,
        positionMs: 1200,
      )!;
      expect(cue.text, 'こんにちは\n世界');
      expect(cue.startMs, 1000);
      expect(cue.endMs, 2500);
      expect(cue.isRenderOnly, isFalse);
    });

    test('缺 sub-start 退回事件位置；缺 sub-end 给暂定时长', () {
      final AudioCue cue = buildPlayerDecodedCue(
        text: 'a',
        startMs: null,
        endMs: null,
        positionMs: 7000,
      )!;
      expect(cue.startMs, 7000);
      expect(cue.endMs, 7000 + kPlayerDecodedCueProvisionalMs);
    });
  });

  group('mergePlayerDecodedCue', () {
    test('按起点升序插入并重排 sentenceIndex（seek 回看补前面的句子）', () {
      List<AudioCue> cues = <AudioCue>[];
      cues = mergePlayerDecodedCue(cues, _cue('b', 5000, 6000)).cues;
      cues = mergePlayerDecodedCue(cues, _cue('c', 9000, 10000)).cues;
      final ({List<AudioCue> cues, int index, bool inserted}) front =
          mergePlayerDecodedCue(cues, _cue('a', 1000, 2000));
      expect(front.inserted, isTrue);
      expect(front.index, 0);
      cues = front.cues;
      expect(cues.map((AudioCue c) => c.text), <String>['a', 'b', 'c']);
      expect(cues.map((AudioCue c) => c.sentenceIndex), <int>[0, 1, 2]);
    });

    test('同一起点重复上报（回看重放）替换而不重复，报告为原地替换', () {
      final ({List<AudioCue> cues, int index, bool inserted}) merged =
          mergePlayerDecodedCue(<AudioCue>[
            _cue('a', 1000, 2000),
            _cue('b', 3000, 4000),
          ], _cue('b2', 3000, 4200));
      expect(merged.inserted, isFalse);
      expect(merged.index, 1);
      expect(merged.cues.map((AudioCue c) => c.text), <String>['a', 'b2']);
      expect(merged.cues.last.endMs, 4200);
    });

    test('不改入参列表', () {
      final List<AudioCue> original = <AudioCue>[_cue('a', 1000, 2000)];
      mergePlayerDecodedCue(original, _cue('b', 3000, 4000));
      expect(original, hasLength(1));
    });
  });

  // 「重播本句」的单句停、「字幕结束暂停」、当前句高亮都是**下标**：一句插进来
  // 只能把它之后的下标后移，不能作废（作废 = 重播本句播进下一句、句尾不停）。
  group('shiftCueIndexForInsert', () {
    test('插入位及之后后移一位，之前不动，null / -1 原样', () {
      expect(shiftCueIndexForInsert(3, 2), 4);
      expect(shiftCueIndexForInsert(2, 2), 3);
      expect(shiftCueIndexForInsert(1, 2), 1);
      expect(shiftCueIndexForInsert(null, 0), isNull);
      expect(shiftCueIndexForInsert(-1, 0), -1);
    });

    test('平移后仍指向同一句', () {
      final List<AudioCue> before = <AudioCue>[
        _cue('b', 5000, 6000),
        _cue('c', 9000, 10000),
      ];
      const int held = 1; // 正在单句停的是 c
      final ({List<AudioCue> cues, int index, bool inserted}) merged =
          mergePlayerDecodedCue(before, _cue('a', 1000, 2000));
      expect(
        merged.cues[shiftCueIndexForInsert(held, merged.index)!].text,
        'c',
      );
    });
  });

  group('closePlayerDecodedCue', () {
    test('暂定时长的句子在下一次字幕变化时按真实位置收尾', () {
      final AudioCue cue = buildPlayerDecodedCue(
        text: 'a',
        startMs: 1000,
        endMs: null,
        positionMs: 1000,
      )!;
      expect(closePlayerDecodedCue(cue, 2400), isTrue);
      expect(cue.endMs, 2400);
    });

    test('变化时刻不在句子区间内（seek 走了）保持原值', () {
      final AudioCue cue = _cue('a', 1000, 6000);
      expect(closePlayerDecodedCue(cue, 500), isFalse);
      expect(closePlayerDecodedCue(cue, 9000), isFalse);
      expect(cue.endMs, 6000);
    });
  });

  test('控制器：未 load 时选轨安全返回 false，且不处于回流模式', () async {
    final VideoPlayerController controller = VideoPlayerController();
    expect(await controller.selectEmbeddedTextTrackViaPlayer(0), isFalse);
    expect(controller.isPlayerDecodedTextSubtitleActive, isFalse);
    expect(controller.isPlayerRenderedSubtitleActive, isFalse);
  });

  group('源码守卫：selectEmbeddedTextTrackViaPlayer', () {
    final String src = File(
      'lib/src/media/video/video_player_controller.dart',
    ).readAsStringSync();
    String body() {
      final int start = src.indexOf(
        'Future<bool> selectEmbeddedTextTrackViaPlayer(int streamIndex)',
      );
      expect(start, greaterThanOrEqualTo(0));
      final int end = src.indexOf('\n  }\n', start);
      return src.substring(start, end);
    }

    test('每个原生 await 后都重校验 _isCurrentLoad（BUG-344 同款防 UAF）', () {
      final String b = body();
      expect(
        b.indexOf('final int loadToken = _loadToken;'),
        lessThan(b.indexOf('await _waitUntilSubtitleTracksReady(player')),
      );
      expect(
        RegExp(r'_isCurrentLoad\(player, loadToken\)').allMatches(b).length,
        greaterThanOrEqualTo(5),
      );
    });

    test('只解码不画：保持 sub-visibility=no，不走图形可见性', () {
      final String b = body();
      expect(b.contains('buildSubtitleSuppressionProperties()'), isTrue);
      expect(b.contains('buildGraphicSubtitleVisibilityProperties()'), isFalse);
      expect(b.contains('_graphicSubtitleActive = true'), isFalse);
      expect(b.contains('player.stream.subtitle.listen('), isTrue);
    });

    test('listen 前先结束旧回流：并发两次选轨不留两个订阅', () {
      final String b = body();
      final int stop = b.lastIndexOf('_stopPlayerDecodedText();');
      final int listen = b.indexOf('player.stream.subtitle.listen(');
      expect(stop, greaterThanOrEqualTo(0));
      expect(stop, lessThan(listen));
    });

    test('回流处理保持下标类播放态、核对当前文本再落 cue', () {
      final int start = src.indexOf('Future<void> _onPlayerDecodedText(');
      expect(start, greaterThanOrEqualTo(0));
      final String handler = src.substring(
        start,
        src.indexOf('\n  }\n', start),
      );
      // 作废这些 = 「重播本句」播进下一句、首尾相接的「字幕结束暂停」不停。
      for (final String cleared in <String>[
        '_oneShotHoldCueIndex = null;',
        '_lastSubtitleEndPauseCueIndex = null;',
        '_currentCueIndex = -1;',
      ]) {
        expect(handler.contains(cleared), isFalse, reason: cleared);
      }
      expect(handler.contains('shiftCueIndexForInsert('), isTrue);
      // 起止时间在事件到达后才读：必须再读一次 sub-text 核对，防止配上下一句的时间。
      expect(handler.contains("_getMpvProperty('sub-text')"), isTrue);
    });

    test('外部换字幕源（setCues）结束回流，迟到的句子不串进新列表', () {
      final int start = src.indexOf('void setCues(List<AudioCue> cues) {');
      final int end = src.indexOf('\n  }\n', start);
      expect(
        src.substring(start, end).contains('_stopPlayerDecodedText();'),
        isTrue,
      );
    });
  });
}

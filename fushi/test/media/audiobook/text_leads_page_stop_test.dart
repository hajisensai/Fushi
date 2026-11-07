import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/text_leads_page_stop.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// 文字领读（「跟随音频」的领读方向 = 文字）的纯决策：屏末停播判定、翻屏后音频怎么跟、
/// VN 引擎上报载荷解析。
void main() {
  group('textLeadsRequestedFor / textLeadsActive', () {
    test('只有「文字领读 + VN 模式」才算 reader 侧条件成立', () {
      expect(
        textLeadsRequestedFor(
          linkDirection: kAudiobookLinkDirectionText,
          vnMode: true,
        ),
        isTrue,
      );
      expect(
        textLeadsRequestedFor(
          linkDirection: kAudiobookLinkDirectionText,
          vnMode: false,
        ),
        isFalse,
        reason: '分页 / 连续模式没有逐屏上报，退回音频领读',
      );
      expect(
        textLeadsRequestedFor(
          linkDirection: kAudiobookLinkDirectionAudio,
          vnMode: true,
        ),
        isFalse,
      );
    });

    test('跟随音频关掉或处在歌词覆盖层时不生效', () {
      expect(
        textLeadsActive(
          requested: true,
          followAudio: true,
          lyricsOverlay: false,
        ),
        isTrue,
      );
      expect(
        textLeadsActive(
          requested: true,
          followAudio: false,
          lyricsOverlay: false,
        ),
        isFalse,
      );
      expect(
        textLeadsActive(
          requested: true,
          followAudio: true,
          lyricsOverlay: true,
        ),
        isFalse,
      );
    });
  });

  group('屏末与「音频在本屏」判定', () {
    final TextLeadsPageBounds bounds = TextLeadsPageBounds(
      first: _cue(1000, 1800),
      last: _cue(2000, 2800),
    );

    test('到达末句句末即算越过屏末；跨文件按文件下标比较', () {
      expect(
        textLeadsPastPageEnd(
          fileIndex: 0,
          effectiveMs: 2799,
          last: bounds.last,
        ),
        isFalse,
      );
      expect(
        textLeadsPastPageEnd(
          fileIndex: 0,
          effectiveMs: 2800,
          last: bounds.last,
        ),
        isTrue,
      );
      expect(
        textLeadsPastPageEnd(fileIndex: 1, effectiveMs: 0, last: bounds.last),
        isTrue,
        reason: '下一个音频文件的开头在末句之后',
      );
    });

    test('停在上一屏句末（首句句首前的静音里）算作已在本屏开头', () {
      expect(
        textLeadsAudioOnPage(fileIndex: 0, effectiveMs: 900, bounds: bounds),
        isTrue,
        reason: '首句前 ${kTextLeadsPageStartToleranceMs}ms 内',
      );
      expect(
        textLeadsAudioOnPage(fileIndex: 0, effectiveMs: 500, bounds: bounds),
        isFalse,
      );
      expect(
        textLeadsAudioOnPage(fileIndex: 0, effectiveMs: 2800, bounds: bounds),
        isFalse,
        reason: '末句已播完：停在本屏屏末的位置不再算「在本屏」',
      );
    });
  });

  group('decideTextLeadsPageChange', () {
    test('停在屏末、翻到下一屏（音频已在新屏开头）→ 原地续播', () {
      expect(
        decideTextLeadsPageChange(
          audioOnPage: true,
          pausedAtPageEnd: true,
          playing: false,
        ),
        const TextLeadsPageDecision(TextLeadsPageAction.resumeHere, play: true),
      );
    });

    test('音频在本屏且没在等续播 → 不动（播放中继续播，用户暂停的保持暂停）', () {
      for (final bool playing in <bool>[true, false]) {
        expect(
          decideTextLeadsPageChange(
            audioOnPage: true,
            pausedAtPageEnd: false,
            playing: playing,
          ),
          const TextLeadsPageDecision(TextLeadsPageAction.none),
        );
      }
    });

    test('翻到音频不在的屏：停在屏末或正在播 → 跳到屏首并播放', () {
      const TextLeadsPageDecision seekAndPlay = TextLeadsPageDecision(
        TextLeadsPageAction.seekToPageStart,
        play: true,
      );
      expect(
        decideTextLeadsPageChange(
          audioOnPage: false,
          pausedAtPageEnd: true,
          playing: false,
        ),
        seekAndPlay,
        reason: '往回翻 = 重听这一屏',
      );
      expect(
        decideTextLeadsPageChange(
          audioOnPage: false,
          pausedAtPageEnd: false,
          playing: true,
        ),
        seekAndPlay,
        reason: '播放中翻屏：音频跟到新屏，不再把文字拽回去',
      );
    });

    test('用户自己暂停后翻屏 → 只挪音频位置，不起播', () {
      expect(
        decideTextLeadsPageChange(
          audioOnPage: false,
          pausedAtPageEnd: false,
          playing: false,
        ),
        const TextLeadsPageDecision(TextLeadsPageAction.seekToPageStart),
      );
    });
  });

  group('textLeadsBoundsFromPayload', () {
    final List<AudioCue> cues = <AudioCue>[
      _cue(0, 500, frag: 'sasayaki://a', sid: 0),
      _cue(1000, 1500, frag: 'sasayaki://b', sid: 1),
      _cue(2000, 2500, frag: 'sasayaki://c', sid: 2),
    ];

    test('frag 按 textFragmentId、sid 按 sentenceIndex 反查', () {
      final TextLeadsPageBounds? byFrag = textLeadsBoundsFromPayload(
        jsonEncode(<String, Object>{
          'type': 'frag',
          'first': 'sasayaki://b',
          'last': 'sasayaki://c',
        }),
        cues,
      );
      expect(byFrag?.first, same(cues[1]));
      expect(byFrag?.last, same(cues[2]));

      final TextLeadsPageBounds? bySid = textLeadsBoundsFromPayload(
        jsonEncode(<String, Object>{'type': 'sid', 'first': '0', 'last': '1'}),
        cues,
      );
      expect(bySid?.first, same(cues[0]));
      expect(bySid?.last, same(cues[1]));
    });

    test('插图屏 / 坏载荷 / 查无 → null', () {
      expect(textLeadsBoundsFromPayload('{"type":"none"}', cues), isNull);
      expect(textLeadsBoundsFromPayload('not json', cues), isNull);
      expect(
        textLeadsBoundsFromPayload(
          '{"type":"frag","first":"x","last":"y"}',
          cues,
        ),
        isNull,
      );
    });

    test('首尾颠倒时按播放顺序摆正', () {
      final TextLeadsPageBounds? bounds = textLeadsBoundsFromPayload(
        '{"type":"sid","first":2,"last":0}',
        cues,
      );
      expect(bounds?.first, same(cues[0]));
      expect(bounds?.last, same(cues[2]));
    });

    test('同一范围按句子身份判等（章节重载换了新对象也认）', () {
      final TextLeadsPageBounds a = TextLeadsPageBounds(
        first: _cue(0, 500),
        last: _cue(1000, 1500),
      );
      final TextLeadsPageBounds b = TextLeadsPageBounds(
        first: _cue(0, 500),
        last: _cue(1000, 1500),
      );
      expect(a.sameRangeAs(b), isTrue);
      expect(a.sameRangeAs(null), isFalse);
    });
  });
}

AudioCue _cue(int startMs, int endMs, {String? frag, int? sid, int file = 0}) {
  return AudioCue()
    ..bookKey = 'book'
    ..chapterHref = 'chapter'
    ..sentenceIndex = sid ?? startMs ~/ 1000
    ..textFragmentId = frag ?? 'cue-$startMs'
    ..text = 'cue $startMs'
    ..startMs = startMs
    ..endMs = endMs
    ..audioFileIndex = file;
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart';
import 'package:fushi/src/media/audiobook/audiobook_follow_style.dart';
import 'package:fushi/src/reader/reader_engine_config.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// 有声书跟读方式（反馈 tUJsiLpL9d，所有者拍板 A+B）的 Dart 侧：跨页句翻页时刻的换算、
/// 播放 tick 上的句内观察判据、JS 分界回值解码、连续模式整行对齐开关的下发。JS 几何由
/// `test/reader/audiobook_follow_style_test.dart` 在真 Chrome 里验。
AudioCue _cue({
  int startMs = 1000,
  int endMs = 5000,
  int fileIndex = 0,
  String id = 'c1',
  CueTokenTiming? timing,
}) {
  return AudioCue()
    ..bookKey = 'b'
    ..chapterHref = 'ch.xhtml'
    ..sentenceIndex = 0
    ..textFragmentId = id
    ..text = 'テスト'
    ..startMs = startMs
    ..endMs = endMs
    ..audioFileIndex = fileIndex
    ..tokenTiming = timing;
}

bool _same(AudioCue a, AudioCue b) =>
    a.textFragmentId == b.textFragmentId && a.startMs == b.startMs;

void main() {
  group('audiobookCueSplitMs', () {
    test('without token timing interpolates by character share', () {
      expect(
        audiobookCueSplitMs(cue: _cue(), charsBefore: 30, totalChars: 40),
        4000,
      );
      expect(
        audiobookCueSplitMs(cue: _cue(), charsBefore: 1, totalChars: 4),
        2000,
      );
    });

    test('with token timing lands on the token that starts the next page', () {
      // 四个 token 各两字，发射于 cue 起点后 0 / 900 / 2100 / 3500 ms。
      final CueTokenTiming timing = CueTokenTiming(
        tokens: <String>['あい', 'うえ', 'おか', 'きく'],
        offsetsMs: <int>[0, 900, 2100, 3500],
      );
      // 一半的字在本页 → 第三个 token（第 5 个字）开始发声时翻。
      expect(
        audiobookCueSplitMs(
          cue: _cue(timing: timing),
          charsBefore: 10,
          totalChars: 20,
        ),
        1000 + 2100,
      );
      // 线性估时会给 3000，逐 token 时间给的是真实发声时刻。
      expect(
        audiobookCueSplitMs(cue: _cue(), charsBefore: 10, totalChars: 20),
        3000,
      );
    });

    test('token whitespace does not count as a spoken character', () {
      final CueTokenTiming timing = CueTokenTiming(
        tokens: <String>['あ ', ' い', 'う'],
        offsetsMs: <int>[0, 1000, 2000],
      );
      expect(
        audiobookCueSplitMs(
          cue: _cue(timing: timing),
          charsBefore: 2,
          totalChars: 3,
        ),
        1000 + 2000,
      );
    });

    test('clamps into the cue and falls back to its end when unmeasured', () {
      final CueTokenTiming late = CueTokenTiming(
        tokens: <String>['あ', 'い'],
        offsetsMs: <int>[0, 99999],
      );
      expect(
        audiobookCueSplitMs(
          cue: _cue(timing: late),
          charsBefore: 1,
          totalChars: 2,
        ),
        5000,
      );
      expect(
        audiobookCueSplitMs(cue: _cue(), charsBefore: 3, totalChars: 0),
        5000,
      );
      expect(
        audiobookCueSplitMs(
          cue: _cue(startMs: 3000, endMs: 2000),
          charsBefore: 1,
          totalChars: 2,
        ),
        3000,
      );
    });
  });

  group('cueEdgeWatchEvent', () {
    final AudioCue watched = _cue();
    final CueEdgeWatch watch = CueEdgeWatch(
      cue: watched,
      atMs: 3000,
      onReached: () {},
    );

    CueEdgeWatchEvent event({
      CueEdgeWatch? w,
      AudioCue? current,
      AudioCue? hit,
      bool hitNull = false,
      int file = 0,
      int ms = 3000,
      bool playing = true,
    }) => cueEdgeWatchEvent(
      watch: w ?? watch,
      currentCue: current ?? watched,
      hitCue: hitNull ? null : (hit ?? watched),
      audioFileIndex: file,
      effectiveMs: ms,
      playing: playing,
      isSameCue: _same,
    );

    test('fires once the cue clock reaches the split while playing', () {
      expect(event(ms: 2999), CueEdgeWatchEvent.none);
      expect(event(ms: 3000), CueEdgeWatchEvent.reached);
      expect(event(ms: 4200), CueEdgeWatchEvent.reached);
    });

    test('does not fire when paused, in another file, or on another cue', () {
      expect(event(playing: false), CueEdgeWatchEvent.none);
      expect(event(file: 1), CueEdgeWatchEvent.none);
      final AudioCue other = _cue(id: 'c2', startMs: 5000, endMs: 8000);
      expect(
        event(current: other, hit: other, ms: 6000),
        CueEdgeWatchEvent.none,
      );
      // 这一 tick 已命中下一句：换句由下一句自己的揭示翻页，不先翻一次后半截。
      expect(event(hit: other, ms: 5100), CueEdgeWatchEvent.none);
    });

    test('fires in the silence after the watched cue (it was fully read)', () {
      expect(event(hitNull: true, ms: 5200), CueEdgeWatchEvent.reached);
    });

    // 已翻到后半截后在同一句内快退 / 拖回翻页时刻之前：当前句不变、播放器不通知 reader，
    // 只有这一路能把页面带回句首页。
    test('reports a rewind back across the split within the same cue', () {
      final CueEdgeWatch tailOnly = CueEdgeWatch(
        cue: watched,
        rewindBelowMs: 3000,
        onReached: () {},
      );
      expect(event(w: tailOnly, ms: 3000), CueEdgeWatchEvent.none);
      expect(event(w: tailOnly, ms: 4800), CueEdgeWatchEvent.none);
      expect(event(w: tailOnly, ms: 2999), CueEdgeWatchEvent.rewound);
      // 退到本句之前的静音（当前句仍 hold 这句）也算退回。
      expect(
        event(w: tailOnly, hitNull: true, ms: 800),
        CueEdgeWatchEvent.rewound,
      );
      // 暂停中拖回去不翻；续播的第一个 tick 再判。
      expect(
        event(w: tailOnly, ms: 2000, playing: false),
        CueEdgeWatchEvent.none,
      );
      // 退进上一句：换句由上一句的揭示处理。
      final AudioCue prev = _cue(id: 'c0', startMs: 0, endMs: 1000);
      expect(event(w: tailOnly, hit: prev, ms: 500), CueEdgeWatchEvent.none);
    });

    test('a three-page sentence watches both directions at once', () {
      final CueEdgeWatch both = CueEdgeWatch(
        cue: watched,
        atMs: 4000,
        rewindBelowMs: 3000,
        onReached: () {},
      );
      expect(event(w: both, ms: 3500), CueEdgeWatchEvent.none);
      expect(event(w: both, ms: 4000), CueEdgeWatchEvent.reached);
      expect(event(w: both, ms: 2500), CueEdgeWatchEvent.rewound);
    });
  });

  group('AudiobookBridge.decodeAudioCueSplitForTesting', () {
    test('accepts a split strictly inside the sentence', () {
      expect(
        AudiobookBridge.decodeAudioCueSplitForTesting(
          jsonEncode(<String, int>{'before': 12, 'total': 40}),
        ),
        (before: 12, total: 40),
      );
    });

    test('rejects missing, malformed and degenerate splits', () {
      for (final Object? raw in <Object?>[
        null,
        '',
        'null',
        '{',
        '[1,2]',
        jsonEncode(<String, Object>{'before': '1', 'total': 4}),
        jsonEncode(<String, int>{'before': 0, 'total': 4}),
        jsonEncode(<String, int>{'before': 4, 'total': 4}),
        jsonEncode(<String, int>{'before': 1, 'total': 0}),
        42,
      ]) {
        expect(
          AudiobookBridge.decodeAudioCueSplitForTesting(raw),
          isNull,
          reason: '$raw',
        );
      }
    });
  });

  group('continuous line-align switch reaches the engine config', () {
    test('install config carries it, default off', () {
      final Map<String, Object?> json = const ReaderEngineConfig(
        navigationGeneration: 1,
        continuousMode: true,
        vnMode: false,
        vnClickAdvance: false,
        scanNonJapaneseText: false,
        hoverAutoLookup: false,
        highlightOnTap: false,
        showChrome: false,
        debugLogging: false,
        swipeDistThreshold: 40,
        swipeFastDistThreshold: 20,
        swipeFastVelocity: 300,
        wheelGestureQuietMs: 300,
        continuousTurnPullPx: 0,
        continuousTurnPinMidGesture: false,
        furiganaMode: 'off',
        caretColor: '#000',
        caretInsetTop: 0,
        caretInsetBottom: 0,
        initialProgress: 0,
        initialCharOffset: -1,
        initialCharOffsetEnd: -1,
        initialFragment: null,
        chromeTopInset: 0,
        chromeBottomInset: 0,
        dartPageWidth: 100,
        dartPageHeight: 100,
        marginTop: 0,
        marginBottom: 0,
        marginLeft: 0,
        marginRight: 0,
        blurImages: false,
        revealedKeys: <String>[],
        perfTraceEnabled: false,
        vnRevealSpeed: 0,
        vnScreenMode: 'block',
        vnSentencesPerScreen: 1,
        vnPreserveDialogue: false,
        vnMergeCrossScreenSentenceAudioCues: false,
        audiobookLineAlignFollow: true,
      ).toJson();
      expect(json['audiobookLineAlignFollow'], isTrue);
    });

    test('live patch hot-updates it only when given', () {
      String live({bool? lineAlign}) => ReaderEngineConfig.liveUpdateInvocation(
        marginTop: 0,
        marginBottom: 0,
        marginLeft: 0,
        marginRight: 0,
        swipeDistThreshold: 40,
        swipeFastDistThreshold: 20,
        swipeFastVelocity: 300,
        wheelGestureQuietMs: 300,
        scanNonJapaneseText: false,
        audiobookLineAlignFollow: lineAlign,
      );
      expect(
        live(lineAlign: false),
        contains('"audiobookLineAlignFollow":false'),
      );
      expect(live(), isNot(contains('audiobookLineAlignFollow')));
    });
  });

  test(
    'defaults are the new behaviours (owner decision: both default new)',
    () {
      expect(kAudiobookPageSplitPageEdge, 'page_edge');
      expect(kAudiobookScrollFollowLineAlign, 'line_align');
    },
  );
}

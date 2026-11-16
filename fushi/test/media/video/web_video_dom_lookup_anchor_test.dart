// BUG-4714：窗口宿主档 DOM 字幕层点词时，制卡锚点 cue 必须取自「被点的那一句」本身。
//
// 修复前 `_onDomLookup` 拿载荷的 (cueStart, sentence) 去 Dart 侧轨副本里按起点 + 全文相等找，
// 找不到就退回 `_controller.currentCue`。DOM 层直接读页面 store 里的活对象（live 轨边看边改：
// 文本逐字变长、起点往前并、终点往后延），Dart 副本是 250ms 节流投过来的旧快照，所以经常对不上；
// 退回的 currentCue 又按旧快照的短终点算，常常是 null → `_lastLookupCue == null` →
// 制卡落到 mixin 的纯字段路径：不入重放队列、不截帧不录音、也不提示（反馈 J8oImZq3Is）。
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/web_video_hosting.dart';
import 'package:fushi_audio/fushi_audio.dart';

AudioCue _cue(int s, int e, String text, int index) => AudioCue()
  ..bookKey = 'book'
  ..chapterHref = 'vid|ja'
  ..sentenceIndex = index
  ..textFragmentId = ''
  ..text = text
  ..startMs = s
  ..endMs = e
  ..audioFileIndex = 0;

WebVideoLookupRequest _req(int s, int e, String sentence) =>
    WebVideoLookupRequest(
      kind: 'click',
      sentence: sentence,
      graphemeIndex: 0,
      cueStartMs: s,
      cueEndMs: e,
      clientRect: const Rect.fromLTWH(0, 0, 10, 10),
      screenX: 0,
      screenY: 0,
    );

void main() {
  test('Dart 轨副本里有同一句：返回那条 cue 本身（cueStreamOwning 按 identical 认流）', () {
    final List<AudioCue> cues = <AudioCue>[
      _cue(1000, 2000, '一句目', 0),
      _cue(3000, 4000, '二句目', 1),
    ];
    final AudioCue got = webVideoDomLookupAnchorCue(
      request: _req(3000, 4000, '二句目'),
      cues: cues,
      bookUid: 'book',
      trackKey: 'vid|ja',
    );
    expect(identical(got, cues[1]), isTrue);
  });

  test('store 文本带首尾空白（Dart 解析时 trim 过）：仍认出同一条 cue', () {
    final List<AudioCue> cues = <AudioCue>[_cue(3000, 4000, '二句目', 0)];
    final AudioCue got = webVideoDomLookupAnchorCue(
      request: _req(3000, 4000, ' 二句目\n'),
      cues: cues,
      bookUid: 'book',
      trackKey: 'vid|ja',
    );
    expect(identical(got, cues.single), isTrue);
  });

  test('live 轨：DOM 活对象比 Dart 旧快照新（文本变长、终点延后）→ 锚点按被点的那句建', () {
    // Dart 副本：起播时投过来的 {startV, startV+1500, 半句}。
    final List<AudioCue> cues = <AudioCue>[_cue(10000, 11500, 'こんに', 0)];
    final AudioCue got = webVideoDomLookupAnchorCue(
      request: _req(9800, 14200, 'こんにちは、世界'),
      cues: cues,
      bookUid: 'book',
      trackKey: 'vid|ja',
    );
    expect(identical(got, cues.single), isFalse);
    expect(got.startMs, 9800);
    expect(got.endMs, 14200);
    expect(got.text, 'こんにちは、世界');
    expect(got.bookKey, 'book');
    expect(got.chapterHref, 'vid|ja');
  });

  test('Dart 侧还没收到这条轨（cue 仓库为空）：锚点照样取自被点的那句，不回 null', () {
    final AudioCue got = webVideoDomLookupAnchorCue(
      request: _req(5000, 4000, '  台詞  '),
      cues: const <AudioCue>[],
      bookUid: 'book',
      trackKey: '',
    );
    expect(got.startMs, 5000);
    // 终点早于起点（坏载荷）时夹到起点，与 parseWebVideoTrackPayload 同一口径。
    expect(got.endMs, 5000);
    expect(got.text, '台詞');
  });

  test('_onDomLookup 用被点的那句作锚点，不再退回 currentCue（源码守卫）', () {
    final String src = File(
      'lib/src/pages/implementations/web_video_fushi_page.dart',
    ).readAsStringSync();
    final int start = src.indexOf('Future<void> _onDomLookup(');
    expect(start, greaterThanOrEqualTo(0));
    final int end = src.indexOf('\n  }\n', start);
    final String body = src.substring(start, end);
    expect(body, contains('webVideoDomLookupAnchorCue('));
    expect(body, isNot(contains('_controller.currentCue')));
  });
}

// 复习卡面音频的自动播放 / 重播规则（对齐 Anki）与播放序列的打断语义。纯逻辑，不起 widget。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_card_autoplay.dart';

/// 假播放出口：每段音频挂一个 completer，测试决定它「播完」还是「被打断」。
class _FakeOutput implements SrsCardAudioOutput {
  _FakeOutput({this.holdResolve = false});

  /// true = 解析（找媒体库 / 查文件）挂起，由测试 [finishResolve] 放行。
  final bool holdResolve;
  final List<String> started = <String>[];
  final List<Completer<bool>> pending = <Completer<bool>>[];
  final List<Completer<String?>> resolving = <Completer<String?>>[];
  int stops = 0;

  @override
  Future<String?> resolve(String name) {
    if (!holdResolve) return Future<String?>.value(name);
    final Completer<String?> c = Completer<String?>();
    resolving.add(c);
    return c.future.then((String? _) => name);
  }

  void finishResolve() => resolving.last.complete('ok');

  @override
  Future<bool> playToEnd(String name) {
    started.add(name);
    final Completer<bool> c = Completer<bool>();
    pending.add(c);
    return c.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    // 共用播放器被 stop：在播的那段以「被打断」结束。
    for (final Completer<bool> c in pending) {
      if (!c.isCompleted) c.complete(false);
    }
  }

  void finishLast() => pending.last.complete(true);
}

void main() {
  group('srsCardSoundNames', () {
    test('按出现顺序取文件名，解实体、去空白、丢空名', () {
      expect(
        srsCardSoundNames(
          '<div>[sound: a.mp3 ]</div>x[sound:b&amp;c.ogg]<i>[sound:]</i>'
          '[sound:a.mp3]',
        ),
        <String>['a.mp3', 'b&c.ogg', 'a.mp3'],
      );
      expect(srsCardSoundNames('<b>no audio</b>'), isEmpty);
    });
  });

  group('自动播放 / 重播的选段', () {
    const String q = '<p>食べる</p>[sound:word.mp3]';
    // 答案面经 {{FrontSide}} 带上问题面，再加句子音频。
    const String a = '<p>食べる</p>[sound:word.mp3]<hr>[sound:sentence.mp3]';

    test('问题面自动播问题面全部音频', () {
      expect(
        srsAutoplaySounds(questionHtml: q, answerHtml: a, answerSide: false),
        <String>['word.mp3'],
      );
    });

    test('答案面自动播只播 FrontSide 之外新出现的（Anki 不重播问题音频）', () {
      expect(
        srsAutoplaySounds(questionHtml: q, answerHtml: a, answerSide: true),
        <String>['sentence.mp3'],
      );
    });

    test('答案面里同一音频出现两次：只扣掉问题面带过来的那一次', () {
      expect(
        srsAnswerOnlySounds(questionHtml: q, answerHtml: '$a[sound:word.mp3]'),
        <String>['sentence.mp3', 'word.mp3'],
      );
    });

    test('答案面重播：默认先问题后答案；关掉则只播答案音频', () {
      expect(
        srsReplaySounds(
          questionHtml: q,
          answerHtml: a,
          answerSide: true,
          includeQuestion: true,
        ),
        <String>['word.mp3', 'sentence.mp3'],
      );
      expect(
        srsReplaySounds(
          questionHtml: q,
          answerHtml: a,
          answerSide: true,
          includeQuestion: false,
        ),
        <String>['sentence.mp3'],
      );
      expect(
        srsReplaySounds(
          questionHtml: q,
          answerHtml: a,
          answerSide: false,
          includeQuestion: false,
        ),
        <String>['word.mp3'],
      );
    });
  });

  group('SrsCardAudioSequencer', () {
    test('一段播完才播下一段', () async {
      final _FakeOutput out = _FakeOutput();
      final SrsCardAudioSequencer seq = SrsCardAudioSequencer(out);
      final Future<void> done = seq.play(<String>['a', 'b']);
      await Future<void>.delayed(Duration.zero);
      expect(out.started, <String>['a']);
      out.finishLast();
      await Future<void>.delayed(Duration.zero);
      expect(out.started, <String>['a', 'b']);
      out.finishLast();
      await done;
      expect(seq.isPlaying, isFalse);
      expect(out.stops, 0);
    });

    test('一段被别处的播放打断：序列停下，不把播放抢回来', () async {
      final _FakeOutput out = _FakeOutput();
      final SrsCardAudioSequencer seq = SrsCardAudioSequencer(out);
      final Future<void> done = seq.play(<String>['a', 'b']);
      await Future<void>.delayed(Duration.zero);
      out.pending.last.complete(false);
      await done;
      expect(out.started, <String>['a']);
    });

    test('cancel 停掉在播的序列；没有序列在播时不碰播放器', () async {
      final _FakeOutput out = _FakeOutput();
      final SrsCardAudioSequencer seq = SrsCardAudioSequencer(out);
      await seq.cancel();
      expect(out.stops, 0, reason: '没在播：不误停别处（如查词发音）的音频');

      final Future<void> done = seq.play(<String>['a', 'b']);
      await Future<void>.delayed(Duration.zero);
      await seq.cancel();
      await done;
      expect(out.stops, 1);
      expect(out.started, <String>['a']);
    });

    test('BUG-3538：解析途中被 cancel，解析完也不再开播（stop 先到的那段不能随后出声）', () async {
      final _FakeOutput out = _FakeOutput(holdResolve: true);
      final SrsCardAudioSequencer seq = SrsCardAudioSequencer(out);
      final Future<void> done = seq.play(<String>['a', 'b']);
      await Future<void>.delayed(Duration.zero);
      expect(out.resolving, hasLength(1), reason: '正在解析第一段');
      // 换卡 / 翻面 / 关了自动播放 / 离开复习页。
      await seq.cancel();
      out.finishResolve();
      await done;
      expect(out.started, isEmpty, reason: '被取代的序列不得在 cancel 之后开播');
      expect(seq.isPlaying, isFalse);
    });

    test('BUG-3538：解析途中换成新序列，只有新序列开播', () async {
      final _FakeOutput out = _FakeOutput(holdResolve: true);
      final SrsCardAudioSequencer seq = SrsCardAudioSequencer(out);
      final Future<void> first = seq.play(<String>['old']);
      await Future<void>.delayed(Duration.zero);
      final Future<void> second = seq.play(<String>['new']);
      await Future<void>.delayed(Duration.zero);
      expect(out.resolving, hasLength(2));
      out.resolving.first.complete('ok');
      out.resolving.last.complete('ok');
      await Future<void>.delayed(Duration.zero);
      out.finishLast();
      await Future.wait(<Future<void>>[first, second]);
      expect(out.started, <String>['new']);
    });

    test('新序列取代旧序列：旧序列不再继续', () async {
      final _FakeOutput out = _FakeOutput();
      final SrsCardAudioSequencer seq = SrsCardAudioSequencer(out);
      final Future<void> first = seq.play(<String>['a', 'b']);
      await Future<void>.delayed(Duration.zero);
      final Future<void> second = seq.play(<String>['c']);
      await Future<void>.delayed(Duration.zero);
      // 播放器换内容 = 旧那段被打断。
      out.pending.first.complete(false);
      out.finishLast();
      await Future.wait(<Future<void>>[first, second]);
      expect(out.started, <String>['a', 'c']);
    });
  });
}

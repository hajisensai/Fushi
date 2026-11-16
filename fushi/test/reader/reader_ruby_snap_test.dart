import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_ruby_snap.dart';
import 'package:fushi/src/reader/reader_selection_data.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show FushiRubySpan;

/// ssJjbvbAbs：点中 ruby 基字时查词起点吸附到组首只是「先试」。组首查到的词覆盖不到
/// 被点的字（义训 `<ruby>じょうろ鼬<rt>ポットウィーゼル</rt></ruby>` 点「鼬」只查到「じょうろ」）
/// 就改用 payload 里从被点字起扫的候选，并让 JS 选区跟着换。
void main() {
  Map<String, dynamic> payload({required String text, int? tapIndex}) =>
      <String, dynamic>{
        'text': text,
        'sentence': 'ここ、じょうろ鼬が巣を作ってるの！',
        'rubyReadings': <Map<String, Object>>[
          <String, Object>{'s': 0, 'e': 5, 'r': 'ポットウィーゼル'},
        ],
        if (tapIndex != null)
          'rubySnap': <String, Object>{
            'tapIndex': tapIndex,
            'selection': <String, Object>{
              'text': text.substring(tapIndex),
              'sentence': 'ここ、じょうろ鼬が巣を作ってるの！',
              'normalizedOffset': 7,
            },
          },
      };

  test('payload rubySnap parses into the tapped-char candidate', () {
    final ReaderSelectionData data = ReaderSelectionData.fromJson(
      payload(text: 'じょうろ鼬が巣を作ってるの', tapIndex: 4),
    );
    expect(data.rubySnapTap, isNotNull);
    expect(data.rubySnapTap!.tapIndex, 4);
    expect(data.rubySnapTap!.selection.text, '鼬が巣を作ってるの');
    expect(data.rubySnapTap!.selection.normalizedOffset, 7);
    expect(data.rubySnapTap!.selection.rubySpans, isEmpty);
    expect(
      ReaderSelectionData.fromJson(payload(text: 'じょうろ鼬が')).rubySnapTap,
      isNull,
    );
  });

  test('a word from the ruby start that misses the tapped char adopts the '
      'tapped-char start', () async {
    final ReaderSelectionData data = ReaderSelectionData.fromJson(
      payload(text: 'じょうろ鼬が巣を作ってるの', tapIndex: 4),
    );
    final List<String> adopted = <String>[];
    final ReaderSelectionData resolved = await resolveRubySnapSelection(
      data,
      matchedLength: (String term, List<FushiRubySpan> spans) async =>
          term.startsWith('じょうろ') ? 4 : 1,
      adoptTapStart: (String expected) async {
        adopted.add(expected);
        return true;
      },
    );
    expect(resolved.text, '鼬が巣を作ってるの');
    expect(adopted, <String>['じょうろ鼬が巣を作ってるの']);
  });

  test(
    'nothing found from the ruby start also adopts the tapped char',
    () async {
      final ReaderSelectionData data = ReaderSelectionData.fromJson(
        payload(text: 'じょうろ鼬が巣を作ってるの', tapIndex: 4),
      );
      final ReaderSelectionData resolved = await resolveRubySnapSelection(
        data,
        matchedLength: (String term, List<FushiRubySpan> spans) async => 0,
        adoptTapStart: (String expected) async => true,
      );
      expect(resolved.text, '鼬が巣を作ってるの');
    },
  );

  test('a word from the ruby start that covers the tapped char keeps the '
      'snapped start (近衛 tapped on 衛)', () async {
    final ReaderSelectionData data = ReaderSelectionData.fromJson(
      payload(text: '近衛だった', tapIndex: 1),
    );
    bool adoptCalled = false;
    final ReaderSelectionData resolved = await resolveRubySnapSelection(
      data,
      matchedLength: (String term, List<FushiRubySpan> spans) async => 2,
      adoptTapStart: (String expected) async {
        adoptCalled = true;
        return true;
      },
    );
    expect(identical(resolved, data), isTrue);
    expect(adoptCalled, isFalse);
  });

  test('no candidate skips the extra lookup entirely', () async {
    final ReaderSelectionData data = ReaderSelectionData.fromJson(
      payload(text: 'じょうろ鼬が'),
    );
    bool looked = false;
    final ReaderSelectionData resolved = await resolveRubySnapSelection(
      data,
      matchedLength: (String term, List<FushiRubySpan> spans) async {
        looked = true;
        return 0;
      },
      adoptTapStart: (String expected) async => true,
    );
    expect(identical(resolved, data), isTrue);
    expect(looked, isFalse);
  });

  test('a refused adopt (selection replaced meanwhile) keeps the reported '
      'selection so lookup and highlight stay on one range', () async {
    final ReaderSelectionData data = ReaderSelectionData.fromJson(
      payload(text: 'じょうろ鼬が巣を作ってるの', tapIndex: 4),
    );
    final ReaderSelectionData resolved = await resolveRubySnapSelection(
      data,
      matchedLength: (String term, List<FushiRubySpan> spans) async => 4,
      adoptTapStart: (String expected) async => false,
    );
    expect(identical(resolved, data), isTrue);
  });
}

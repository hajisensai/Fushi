import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_sentence_audio_relocation_script.dart';

import '../helpers/node_runtime.dart';

/// 有声书 cue 重定位：三种 view mode 共用的生产 JS（[kSentenceAudioRelocationJs]）与 Dart
/// 影子 [ReaderPaginationScripts.resolveCueNormSpansForTesting] 逐用例对拍。
///
/// drift 测试里的不变量只在 Dart 影子上验；JS 那份过去只靠源码 contains 守着，改了 JS
/// 不改影子（或反过来）不会有人发现。这里把固定用例 + 一批确定性随机用例同时喂给两边，
/// 任何一条结果不同即红。
List<SentenceAudioCueHint> _cues(List<(String, int, int)> raw) =>
    <SentenceAudioCueHint>[
      for (final (String needle, int hint, int length) in raw)
        SentenceAudioCueHint(needle: needle, hint: hint, length: length),
    ];

/// 确定性随机：小字母表的全文（制造大量重复片段），cue 取全文的连续切片按顺序排列，
/// 提示坐标随机偏移（含 ±3 / ±30 与越界），偶尔混入搜不到的句子与空句。
List<({String full, List<SentenceAudioCueHint> cues})> _randomCases() {
  final math.Random random = math.Random(20261121);
  const String alphabet = 'あいうかき猫𠀀';
  final List<({String full, List<SentenceAudioCueHint> cues})> out =
      <({String full, List<SentenceAudioCueHint> cues})>[];
  for (int c = 0; c < 200; c++) {
    final StringBuffer buffer = StringBuffer();
    final int chars = 20 + random.nextInt(400);
    final List<int> runes = alphabet.runes.toList();
    for (int i = 0; i < chars; i++) {
      buffer.writeCharCode(runes[random.nextInt(runes.length)]);
    }
    final String full = buffer.toString();
    final List<SentenceAudioCueHint> cues = <SentenceAudioCueHint>[];
    int at = 0;
    while (at < full.length) {
      int len = 1 + random.nextInt(12);
      if (at + len > full.length) len = full.length - at;
      // 不切开代理对（cue 原文总是整字）。
      if (at + len < full.length &&
          (full.codeUnitAt(at + len) & 0xFC00) == 0xDC00) {
        len += 1;
      }
      final String needle = full.substring(at, at + len);
      const List<int> shifts = <int>[0, 0, 0, 3, -3, 30, -30, 300];
      final int hint = at + shifts[random.nextInt(shifts.length)];
      final int roll = random.nextInt(20);
      cues.add(
        SentenceAudioCueHint(
          needle: roll == 0 ? 'なし' : (roll == 1 ? '' : needle),
          hint: hint,
          length: len,
        ),
      );
      at += len;
    }
    out.add((full: full, cues: cues));
  }
  return out;
}

void main() {
  final NodeTestRuntime runtime = NodeTestRuntime.probe();

  test(
    '生产 JS resolveSpans 与 Dart 影子逐用例一致（固定 + 200 条随机）',
    () async {
      final String node = runtime.requireNode();
      final List<({String full, List<SentenceAudioCueHint> cues})> cases =
          <({String full, List<SentenceAudioCueHint> cues})>[
            (
              full: 'あいうえおかきくけこさしすせそ',
              cues: _cues(<(String, int, int)>[
                ('あいうえお', 3, 5),
                ('かきくけこ', 8, 5),
                ('さしすせそ', 40, 5),
              ]),
            ),
            (
              full: 'エリスだけは好きそうだけどな高い所とはいえ今はそれを考慮している暇はないとはいえ',
              cues: _cues(<(String, int, int)>[
                ('エリスだけは好きそうだけどな高い所と', 0, 18),
                ('とはいえ', 36, 4),
                ('今はそれを考慮している暇はない', 21, 15),
              ]),
            ),
            (
              full: '𠀀猫がいるabcd猫がいる',
              cues: _cues(<(String, int, int)>[
                ('𠀀猫がいる', 0, 6),
                ('猫がいる', 10, 4),
              ]),
            ),
            (
              full: 'あいうえおかきくけこさしすせそたちつてと',
              cues: _cues(<(String, int, int)>[
                ('なし1', 12, 3),
                ('なし2', 14, 3),
                ('かきくけこ', 5, 5),
              ]),
            ),
            ..._randomCases(),
          ];
      final NodeHarnessResult result = await runNodeHarness(
        node,
        'test/reader/sentence_audio_relocation_behavior_harness.js',
        <String, Object>{
          'script': kSentenceAudioRelocationJs,
          'foldInput': 'ＡＢｃ１２カタカナｱｲｳABC',
          'cases': <Map<String, Object>>[
            for (final c in cases)
              <String, Object>{
                'full': c.full,
                'cues': <Map<String, Object>>[
                  for (final SentenceAudioCueHint cue in c.cues)
                    <String, Object>{
                      'needle': cue.needle,
                      'hint': cue.hint,
                      'length': cue.length,
                    },
                ],
              },
          ],
        },
        timeout: const Duration(seconds: 60),
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final Map<String, Object?> decoded =
          jsonDecode(result.stdout) as Map<String, Object?>;
      expect(decoded['constants'], <int>[
        ReaderPaginationScripts.kSentenceAudioSearchWindow,
        ReaderPaginationScripts.kSentenceAudioTailOverlap,
        ReaderPaginationScripts.kSentenceAudioAdjacent,
      ]);
      expect(decoded['folded'], 'abc12かたかなあいうabc');
      final List<Object?> spans = decoded['spans']! as List<Object?>;
      expect(spans, hasLength(cases.length));
      int compared = 0;
      for (int i = 0; i < cases.length; i++) {
        final List<(int, int)> expected =
            ReaderPaginationScripts.resolveCueNormSpansForTesting(
              fullNorm: cases[i].full,
              cues: cases[i].cues,
            );
        final List<(int, int)> actual = <(int, int)>[
          for (final List<Object?> pair
              in (spans[i]! as List<Object?>).cast<List<Object?>>())
            (pair[0]! as int, pair[1]! as int),
        ];
        expect(actual, expected, reason: 'case $i full=${cases[i].full}');
        compared += expected.length;
      }
      expect(compared, greaterThan(1000), reason: '随机用例确实生成了足量 cue');
    },
    skip: runtime.skipReason,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

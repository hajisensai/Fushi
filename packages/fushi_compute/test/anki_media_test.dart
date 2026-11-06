// Anki 媒体引用扫描的原生实现（ffc_parse_anki_*）。
//
// 删除旧 Dart `MediaNameMatcher` 之前，用它在 [buildAnkiMediaCorpus] 上生成了结果摘要
// [_oldDartCorpusDigest]（命中集合与顺序都算在内）；本测试对原生实现复算并比对。另外两条
// 口径自检直接对 Dart SDK：大小写折叠表对每个码点与 `String.toLowerCase` 一致。
//
// 原生库是硬依赖：找不到库直接失败，不 skip。
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

import 'anki_media_corpus.dart';

/// 旧 Dart `MediaNameMatcher.namesInAll` 在 [buildAnkiMediaCorpus] 上的
/// [digestAnkiOutcomes]（2026-10-18 生成）。
const int _oldDartCorpusDigest = -0x115c3d42e108fb94;

/// 与 fushi_anki 的 `MediaNameMatcher.namesInEach` 同一换算：下标 → 原名，按迭代序进 Set。
List<Set<String>> _nativeScan(List<String> names, List<List<String>> groups) {
  final FfcMediaNameMatcher matcher = FfcMediaNameMatcher(names);
  try {
    return <Set<String>>[
      for (final Uint32List hits in matcher.scanGroups(groups))
        <String>{for (final int i in hits) names[i]},
    ];
  } finally {
    matcher.close();
  }
}

void main() {
  test('corpus digest matches the deleted Dart MediaNameMatcher', () {
    final List<AnkiMediaCase> corpus = buildAnkiMediaCorpus();
    expect(corpus.length, 305);
    final int digest = digestAnkiOutcomes(<String>[
      for (final AnkiMediaCase c in corpus) describeAnkiOutcome(c, _nativeScan),
    ]);
    expect(digest.toRadixString(16), _oldDartCorpusDigest.toRadixString(16));
  });

  test('representative cases (old Dart outputs)', () {
    String scan(int index) =>
        describeAnkiOutcome(kHandWrittenAnkiCases[index], _nativeScan);
    expect(scan(0), '["a.mp3","Pic.PNG"];["a.mp3"];[];[];[]');
    // 同一后缀下按「名字长度首次出现序」回切，不是按出现位置。
    expect(scan(1), '["ab.mp3","b.mp3","xab.mp3"]');
    // 后缀按名字表里首次出现序（.mp3 先于 .jpg），无扩展名的最后。
    expect(
      scan(2),
      '["a.b.mp3"];["noext","NoExt"];["Dup.jpg","dup.jpg"];'
      '["a.b.mp3","Dup.jpg","dup.jpg","noext","NoExt"]',
    );
    // Dart toLowerCase 是逐码点简单映射：İ → i、词尾 Σ → σ（不是 ς）、ß 不展开、补充平面也折叠。
    expect(
      scan(3),
      '["İ.png","i.png"];["ΟΔΟΣ.mp3","οδοσ.mp3"];["Straße.ogg"];'
      '["\u{10400}.jpg"]',
    );
    // 以 `.` 结尾的名字（后缀就是 `.`）与孤立代理码元。
    expect(scan(4), '["x.","a.","\\ud800.mp3"];["b\\udc00.mp3"]');
  });

  test('case folding equals String.toLowerCase for every code point', () {
    final StringBuffer chunk = StringBuffer();
    for (int cp = 0; cp <= 0x10FFFF; cp++) {
      chunk.writeCharCode(cp);
      if (chunk.length >= 50000 || cp == 0x10FFFF) {
        final String text = chunk.toString();
        expect(
          FfcMediaNameMatcher.foldForMatching(text) == text.toLowerCase(),
          isTrue,
          reason: 'chunk ending at U+${cp.toRadixString(16)}',
        );
        chunk.clear();
      }
    }
  });

  test('case folding keeps lone surrogates and folds surrogate pairs', () {
    for (final String text in <String>[
      'ΣΑΣ',
      'İ',
      '𐐀',
      '\uD801',
      '\uDC00\uD801',
      'A\uD801B\uDC00C',
      '',
    ]) {
      expect(FfcMediaNameMatcher.foldForMatching(text), text.toLowerCase());
    }
  });

  test('closed matcher refuses to scan; close is idempotent', () {
    final FfcMediaNameMatcher m = FfcMediaNameMatcher(<String>['a.mp3']);
    m.close();
    m.close();
    expect(() => m.scanGroups(<List<String>>[]), throwsStateError);
  });
}

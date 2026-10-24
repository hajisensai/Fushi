import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi_corpus/fushi_corpus.dart';
import 'package:test/test.dart';

/// 真原生库（硬依赖：找不到库这里直接失败，不 skip）。
///
/// 词元线格式由 fushidicts 产出；这里手写同一份格式（`N × {u32 M, M × {u32 start, u32 len,
/// str lemma}}`），钉住 Dart → Rust 的文档 / 查询编码与结果解码。
Uint8List terms(List<List<(int, int, String)>> perSentence) {
  final BytesBuilder b = BytesBuilder();
  void u32(int v) {
    final ByteData d = ByteData(4)..setUint32(0, v, Endian.little);
    b.add(d.buffer.asUint8List());
  }

  for (final List<(int, int, String)> tokens in perSentence) {
    u32(tokens.length);
    for (final (int start, int len, String lemma) in tokens) {
      final List<int> bytes = utf8.encode(lemma);
      u32(start);
      u32(len);
      u32(bytes.length);
      b.add(bytes);
    }
  }
  return b.takeBytes();
}

CorpusDocument doc(
  CorpusSourceKind kind,
  String key,
  int part,
  List<CorpusSentence> sentences, {
  String fingerprint = 'fp',
}) => CorpusDocument(
  kind: kind,
  key: key,
  part: part,
  title: 'T:$key',
  fingerprint: fingerprint,
  normalizer: 'n1',
  updatedAt: 1,
  sentences: sentences,
);

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('fushi_corpus_dart');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('put → query → docs → 跨 isolate attach → 重开', () async {
    final FushiCorpusIndex index = FushiCorpusIndex.open(dir.path);
    index.put(
      doc(CorpusSourceKind.book, 'book-1', -1, const <CorpusSentence>[
        CorpusSentence(section: 2, pos: 30, len: 8, text: '猫が魚を食べた。'),
        CorpusSentence(section: 3, pos: 0, len: 6, text: '𠮷野家で食べる'),
      ]),
      terms(<List<(int, int, String)>>[
        <(int, int, String)>[(0, 1, '猫'), (4, 3, '食べる')],
        <(int, int, String)>[(0, 3, '𠮷野家'), (5, 3, '食べる')],
      ]),
    );
    index.put(
      doc(CorpusSourceKind.video, 'vid', 2, const <CorpusSentence>[
        CorpusSentence(section: 2, pos: 61000, len: 1500, text: '早く食べて'),
      ]),
      terms(<List<(int, int, String)>>[
        <(int, int, String)>[(2, 3, '食べる')],
      ]),
    );

    final CorpusQueryResult result = index.query(<String>['食べる']);
    expect(result.total, 3);
    expect(
      result.groups.map((CorpusGroup g) => g.kind),
      <CorpusSourceKind>[CorpusSourceKind.book, CorpusSourceKind.video],
    );
    final CorpusHit first = result.groups.first.items.first;
    expect(first.key, 'book-1');
    expect(first.title, 'T:book-1');
    expect(first.section, 2);
    expect(first.pos, 30);
    expect(first.text, '猫が魚を食べた。');
    expect(first.highlights, <({int start, int length})>[(start: 4, length: 3)]);
    final CorpusHit supplementary = result.groups.first.items[1];
    expect(
      supplementary.text.substring(
        supplementary.highlights.single.start,
        supplementary.highlights.single.start +
            supplementary.highlights.single.length,
      ),
      '食べる',
    );

    final CorpusDocument? exported = index.export(
      CorpusSourceKind.book,
      'book-1',
      -1,
    );
    expect(exported!.title, 'T:book-1');
    expect(exported.sentences.map((CorpusSentence s) => s.text), <String>[
      '猫が魚を食べた。',
      '𠮷野家で食べる',
    ]);
    expect(exported.sentences.first.pos, 30);
    expect(index.export(CorpusSourceKind.book, 'nope', -1), isNull);

    final List<CorpusDocInfo> docs = index.docs(kind: CorpusSourceKind.video);
    expect(docs.single.key, 'vid');
    expect(docs.single.part, 2);
    expect(docs.single.sentences, 1);

    // 另一个 isolate 接上同一句柄写入，主 isolate 立即可见。
    final int address = index.address;
    await Isolate.run(() {
      FushiCorpusIndex.attach(address).put(
        doc(CorpusSourceKind.game, 'g1', 0, const <CorpusSentence>[
          CorpusSentence(section: 0, pos: 99, len: 0, text: 'もっと食べたい'),
        ]),
        terms(<List<(int, int, String)>>[
          <(int, int, String)>[(3, 3, '食べる')],
        ]),
      );
    });
    expect(
      index.query(<String>['食べる'], kinds: <CorpusSourceKind>[
        CorpusSourceKind.game,
      ]).groups.single.items.single.text,
      'もっと食べたい',
    );
    expect(index.stats().docs, 3);

    expect(index.remove(CorpusSourceKind.video, 'vid'), 1);
    expect(index.removeKinds(<CorpusSourceKind>[CorpusSourceKind.book]), 1);
    index.close();

    final FushiCorpusIndex reopened = FushiCorpusIndex.open(dir.path);
    expect(reopened.stats().docs, 1);
    expect(reopened.docs().single.kind, CorpusSourceKind.game);
    reopened.close();
  });

  test('词元句数对不上：原生拒收并抛 FushiCorpusException', () {
    final FushiCorpusIndex index = FushiCorpusIndex.open(dir.path);
    expect(
      () => index.put(
        doc(CorpusSourceKind.book, 'b', -1, const <CorpusSentence>[
          CorpusSentence(section: 0, pos: 0, len: 1, text: 'a'),
          CorpusSentence(section: 0, pos: 1, len: 1, text: 'b'),
        ]),
        terms(<List<(int, int, String)>>[<(int, int, String)>[]]),
      ),
      throwsA(isA<FushiCorpusException>()),
    );
    index.close();
  });

  test('splitCorpusSentences 返回 UTF-16 区间', () {
    const String text = '「行こう。」と言った。Pi is 3.14 here. Next';
    final List<String> sentences = <String>[
      for (final ({int start, int end}) s in splitCorpusSentences(text))
        text.substring(s.start, s.end),
    ];
    expect(sentences, <String>[
      '「行こう。」',
      'と言った。',
      'Pi is 3.14 here.',
      'Next',
    ]);
    expect(splitCorpusSentences(''), isEmpty);
  });
}

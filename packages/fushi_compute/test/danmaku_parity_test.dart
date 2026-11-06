// 弹幕解析原生实现（ffc_parse_danmaku_*）与旧 Dart 实现的逐条对拍。
//
// 旧实现（fushi/lib/src/media/video/video_danmaku_source.dart @ e35042dda1：
// package:xml 6.6.1 的 XmlDocument.parse + findAllElements('d')，jsonDecode + 动态取值，
// List.sort）已删除；删除前用它对 danmaku_corpus_test.dart 的确定性语料逐例求观测值
// （结局种类、FormatException 文案与偏移、每条弹幕的 startMs / text / mode / color），
// 按语料顺序做 64 位 FNV-1a 摘要冻结在下面。原生实现必须得到完全相同的摘要。
//
// 原生库是硬依赖：找不到库这里直接失败，不 skip（本地跑时用 FUSHI_COMPUTE_LIB 指向产物）。
@TestOn('vm')
library;

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

import 'danmaku_corpus_test.dart';

/// 旧实现对语料按种类求出的观测值摘要。
const Map<DanmakuCaseKind, String> _oldDigests = <DanmakuCaseKind, String>{
  DanmakuCaseKind.xml: '9466d1dfa98c80b0',
  DanmakuCaseKind.json: '38d1d84c1a6a8d59',
  DanmakuCaseKind.online: '276168614c01b052',
};

DanmakuObservedItem _item(int startMs, String text, int mode, int colorArgb) =>
    (startMs, text, mode, colorArgb);

DanmakuObservation _observe(DanmakuCase c) {
  final DanmakuNative native = DanmakuNative.instance;
  final DanmakuParseResult<DanmakuObservedItem> result = switch (c.kind) {
    DanmakuCaseKind.xml => native.parseBilibiliXml(c.input, _item),
    DanmakuCaseKind.json => native.parseDandanplayJson(
      c.input,
      _item,
      shiftMs: c.shiftMs,
    ),
    DanmakuCaseKind.online => native.parseDandanplayJson(
      c.input,
      _item,
      shiftSeconds: c.shiftSeconds,
    ),
  };
  final FormatException? error = result.formatException;
  return DanmakuObservation(
    result.outcome.index,
    error == null ? '' : '${error.message}@${error.offset}',
    result.items,
  );
}

void main() {
  setUpAll(() {
    expect(
      () => DanmakuNative.instance,
      returnsNormally,
      reason: 'set $kFushiComputeLibEnv to the built fushi_compute library',
    );
  });

  test('frozen corpus: every case matches the old Dart implementation', () {
    final List<DanmakuCase> cases = buildDanmakuCorpus();
    expect(cases.length, kDanmakuCorpusSize);
    final Map<DanmakuCaseKind, DanmakuDigest> digests =
        <DanmakuCaseKind, DanmakuDigest>{
          for (final DanmakuCaseKind kind in DanmakuCaseKind.values)
            kind: DanmakuDigest(),
        };
    for (final DanmakuCase c in cases) {
      digests[c.kind]!.addObservation(_observe(c));
    }
    expect(<DanmakuCaseKind, String>{
      for (final MapEntry<DanmakuCaseKind, DanmakuDigest> e in digests.entries)
        e.key: e.value.hex,
    }, _oldDigests);
  });

  group(
    'representative samples (expected values from the old implementation)',
    () {
      test('Bilibili XML: entities, modes, colors', () {
        final DanmakuObservation o = _observe(
          const DanmakuCase(
            DanmakuCaseKind.xml,
            '<i>\n  <d p="1.25,1,25,16777215,0,0,abc,1">こんにちは &amp; テスト</d>\n'
            '  <d p="2.5,5,25,16711680,0,0,abc,2">上固定</d>\n</i>\n',
          ),
        );
        expect(o.kind, 0);
        expect(o.items, <DanmakuObservedItem>[
          (1250, 'こんにちは & テスト', DanmakuModeIndex.scroll, 0xFFFFFFFF),
          (2500, '上固定', DanmakuModeIndex.top, 0xFFFF0000),
        ]);
      });

      test('Bilibili XML: nested <d> includes inner text; CDATA kept raw', () {
        final DanmakuObservation o = _observe(
          const DanmakuCase(
            DanmakuCaseKind.xml,
            '<i><d p="2,1,25,255">a<d p="1,4,25,255">b</d>c</d>'
            '<d p="3,1,25,255"><![CDATA[ x &amp; <y> ]]></d></i>',
          ),
        );
        expect(o.items, <DanmakuObservedItem>[
          (1000, 'b', DanmakuModeIndex.bottom, 0xFF0000FF),
          (2000, 'abc', DanmakuModeIndex.scroll, 0xFF0000FF),
          (3000, 'x &amp; <y>', DanmakuModeIndex.scroll, 0xFF0000FF),
        ]);
      });

      test(
        'Bilibili XML: malformed or non-finite input empties the whole file',
        () {
          for (final String xml in <String>[
            '<i><d p="1,1,25,255">a < b</d></i>',
            '<i><d p="1,1,25,255">x</i>',
            '<i/><i/>',
            '<i><?xml version="1.0"?></i>',
            '',
          ]) {
            expect(
              _observe(DanmakuCase(DanmakuCaseKind.xml, xml)).kind,
              1,
              reason: xml,
            );
          }
          final DanmakuObservation inf = _observe(
            const DanmakuCase(
              DanmakuCaseKind.xml,
              '<i><d p="1,1,25,255">ok</d><d p="Infinity,1,25,255">x</d></i>',
            ),
          );
          expect(inf.kind, 3);
          expect(inf.items, isEmpty);
        },
      );

      test(
        'Dandanplay JSON: tolerant rows, ?? fallbacks, toString of non-strings',
        () {
          final DanmakuObservation o = _observe(
            const DanmakuCase(
              DanmakuCaseKind.json,
              '{"comments":['
              '{"time":3.25,"mode":4,"color":255,"text":"底"},'
              '{"time":"4.5","type":"scroll","text":"文字列時間"},'
              '{"time":null,"text":"bad"},'
              '{"time":6,"mode":7,"text":"positioned"},'
              '{"time":1,"mode":"RİGHT","m":[1,2.5,{"a":null},1e21,-0.0]},'
              '{"m":"","text":"not a fallback","time":1},'
              '{"m":null,"text":" fb ","t":2}'
              ']}',
              shiftMs: -500,
            ),
          );
          expect(o.items, <DanmakuObservedItem>[
            (
              500,
              '[1, 2.5, {a: null}, 1e+21, -0.0]',
              DanmakuModeIndex.scroll,
              0xFFFFFFFF,
            ),
            (1500, 'fb', DanmakuModeIndex.scroll, 0xFFFFFFFF),
            (2750, '底', DanmakuModeIndex.bottom, 0xFF0000FF),
            (4000, '文字列時間', DanmakuModeIndex.scroll, 0xFFFFFFFF),
          ]);
        },
      );

      test('Dandanplay JSON: jsonDecode error message and offset', () {
        final DanmakuObservation o = _observe(
          const DanmakuCase(
            DanmakuCaseKind.json,
            '{"comments":[{"m":"x","time":01}]}',
          ),
        );
        expect((o.kind, o.detail), (1, 'Unexpected character@30'));
      });
    },
  );
}

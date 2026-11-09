import 'dart:convert';
import 'dart:math' show Rectangle;

import 'package:fushi/src/mining/tyrano_dom/tyrano_dom_frame.dart';
import 'package:test/test.dart';

/// 观察脚本推回的载荷（结构照实测录制，文本为自造）。
String _payload({
  bool adding = false,
  bool vertical = false,
  num dpr = 1,
  num vw = 1904,
  num vh = 1041,
  String speaker = '',
  List<Map<String, Object?>>? glyphs,
}) => jsonEncode(<String, Object?>{
  'v': 1,
  'adding': adding,
  'vertical': vertical,
  'dpr': dpr,
  'vw': vw,
  'vh': vh,
  'speaker': speaker,
  'glyphs':
      glyphs ??
      <Map<String, Object?>>[
        _g('テ', 287.25, 852.0416259765625),
        _g('ス', 321.6487731933594, 852.0416259765625),
        _g('ト', 356.0475769042969, 852.0416259765625),
      ],
});

Map<String, Object?> _g(
  String t,
  num x,
  num y, {
  num w = 34.398773193359375,
  num h = 33.73614501953125,
  bool s = true,
}) => <String, Object?>{'t': t, 'x': x, 'y': y, 'w': w, 'h': h, 's': s};

TyranoDomFrame _frame(TyranoDomFrameAssembler a, String payload) =>
    a.assemble(parseTyranoDomPayload(payload)!);

void main() {
  group('parseTyranoDomPayload', () {
    test('解析录制结构', () {
      final TyranoDomPayload? payload = parseTyranoDomPayload(
        _payload(speaker: '話者'),
      );
      expect(payload, isNotNull);
      expect(payload!.glyphs, hasLength(3));
      expect(payload.glyphs.first.left, 287.25);
      expect(payload.speaker, '話者');
      expect(payload.viewportWidth, 1904);
    });

    test('版本不符 / 非 JSON / 字段缺失返回 null', () {
      expect(parseTyranoDomPayload('not json'), isNull);
      expect(parseTyranoDomPayload('[]'), isNull);
      expect(
        parseTyranoDomPayload(
          jsonEncode(<String, Object?>{'v': 2, 'glyphs': <Object?>[]}),
        ),
        isNull,
      );
      expect(
        parseTyranoDomPayload(
          jsonEncode(<String, Object?>{
            'v': 1,
            'glyphs': <Object?>[
              <String, Object?>{'t': 'a', 'x': 1},
            ],
          }),
        ),
        isNull,
      );
    });

    test('空文本字形丢弃；dpr 非法按 1', () {
      final TyranoDomPayload payload = parseTyranoDomPayload(
        _payload(
          dpr: 0,
          glyphs: <Map<String, Object?>>[_g('', 0, 0), _g('a', 1, 2)],
        ),
      )!;
      expect(payload.glyphs.map((TyranoDomRawGlyph g) => g.text), <String>[
        'a',
      ]);
      expect(payload.devicePixelRatio, 1);
    });
  });

  group('物理像素换算', () {
    test('dpr=1：与 CSS 像素一致，客户区 = 视口', () {
      final TyranoDomFrame frame = _frame(
        TyranoDomFrameAssembler(),
        _payload(),
      );
      expect(frame.glyphs.first.rect.left, 287.25);
      expect(frame.glyphs.first.rect.top, closeTo(852.04, 0.01));
      expect(frame.glyphs.first.rect.width, closeTo(34.4, 0.01));
      expect(frame.clientWidth, 1904);
      expect(frame.clientHeight, 1041);
      expect(frame.devicePixelRatio, 1);
    });

    test('dpr=1.5：矩形与客户区都乘 1.5', () {
      final TyranoDomFrame frame = _frame(
        TyranoDomFrameAssembler(),
        _payload(
          dpr: 1.5,
          vw: 1269.3333,
          vh: 694,
          glyphs: <Map<String, Object?>>[_g('あ', 100, 200, w: 20, h: 30)],
        ),
      );
      expect(
        frame.glyphs.single.rect,
        const Rectangle<double>(150, 300, 30, 45),
      );
      expect(frame.clientWidth, 1904);
      expect(frame.clientHeight, 1041);
    });

    test('tyranoCssRectToPhysical', () {
      expect(
        tyranoCssRectToPhysical(
          left: 10,
          top: 20,
          width: 4,
          height: 8,
          devicePixelRatio: 1.25,
        ),
        const Rectangle<double>(12.5, 25, 5, 10),
      );
    });
  });

  group('正文与字形下标', () {
    test('按字形顺序拼接，下标首尾相接（UTF-16，代理对占 2）', () {
      final TyranoDomFrame frame = _frame(
        TyranoDomFrameAssembler(),
        _payload(
          glyphs: <Map<String, Object?>>[
            _g('甲', 0, 0),
            _g('𠮷', 40, 0),
            _g('乙', 80, 0),
          ],
        ),
      );
      expect(frame.text, '甲𠮷乙');
      expect(
        frame.glyphs.map(
          (TyranoDomGlyph g) => <int>[g.textStart, g.textLength],
        ),
        <List<int>>[
          <int>[0, 1],
          <int>[1, 2],
          <int>[3, 1],
        ],
      );
    });

    test('ruby：脚本只推 rb 文本与 rb 矩形，正文不含 rt', () {
      // 脚本对 <span class="char"><ruby><rb>甲</rb><rt>こう</rt></ruby></span> 推回的形状。
      final TyranoDomFrame frame = _frame(
        TyranoDomFrameAssembler(),
        _payload(
          glyphs: <Map<String, Object?>>[
            _g('甲', 208, 9, w: 39, h: 50),
            _g('乙', 247, 9, w: 39, h: 50),
          ],
        ),
      );
      expect(frame.text, '甲乙');
      expect(frame.text.contains('こう'), isFalse);
      expect(frame.glyphs.first.rect, const Rectangle<double>(208, 9, 39, 50));
    });

    test('纵排标志透传，矩形照取', () {
      final TyranoDomFrame frame = _frame(
        TyranoDomFrameAssembler(),
        _payload(
          vertical: true,
          glyphs: <Map<String, Object?>>[_g('甲', 900, 100), _g('乙', 900, 134)],
        ),
      );
      expect(frame.vertical, isTrue);
      expect(frame.text, '甲乙');
      expect(frame.glyphs[1].rect.top, 134);
    });
  });

  group('complete', () {
    test('is_adding_text=true → 未完成', () {
      expect(
        _frame(TyranoDomFrameAssembler(), _payload(adding: true)).complete,
        isFalse,
      );
    });

    test('有非空白字形未显示 → 未完成', () {
      final TyranoDomFrame frame = _frame(
        TyranoDomFrameAssembler(),
        _payload(
          glyphs: <Map<String, Object?>>[
            _g('甲', 0, 0),
            _g('乙', 1, 0, s: false),
          ],
        ),
      );
      expect(frame.complete, isFalse);
    });

    test('常驻 opacity:0 的半角空格不阻塞完成', () {
      final TyranoDomFrame frame = _frame(
        TyranoDomFrameAssembler(),
        _payload(
          glyphs: <Map<String, Object?>>[
            _g('甲', 0, 0),
            _g(' ', 1, 0, s: false),
          ],
        ),
      );
      expect(frame.complete, isTrue);
    });

    test('没有字形且不在逐字显示 → 完成（空帧）', () {
      final TyranoDomFrame frame = _frame(
        TyranoDomFrameAssembler(),
        _payload(glyphs: <Map<String, Object?>>[]),
      );
      expect(frame.complete, isTrue);
      expect(frame.text, isEmpty);
    });
  });

  group('generation', () {
    test('首帧有正文为 1；正文不变（逐字显示 / 位置变化）不 +1；正文变才 +1', () {
      final TyranoDomFrameAssembler a = TyranoDomFrameAssembler();
      final List<Map<String, Object?>> hidden = <Map<String, Object?>>[
        _g('甲', 0, 0, s: false),
        _g('乙', 34, 0, s: false),
      ];
      expect(_frame(a, _payload(adding: true, glyphs: hidden)).generation, 1);
      final List<Map<String, Object?>> shown = <Map<String, Object?>>[
        _g('甲', 0, 0),
        _g('乙', 34, 0),
      ];
      final TyranoDomFrame done = _frame(a, _payload(glyphs: shown));
      expect(done.generation, 1);
      expect(done.complete, isTrue);
      // 窗口缩放：矩形变、正文不变。
      final List<Map<String, Object?>> moved = <Map<String, Object?>>[
        _g('甲', 0, 0, w: 20),
        _g('乙', 20, 0, w: 20),
      ];
      expect(_frame(a, _payload(dpr: 1.5, glyphs: moved)).generation, 1);
      expect(
        _frame(
          a,
          _payload(glyphs: <Map<String, Object?>>[_g('丙', 0, 0)]),
        ).generation,
        2,
      );
      // 消息窗清空（换句前 / 隐藏）也是正文变化。
      expect(
        _frame(a, _payload(glyphs: <Map<String, Object?>>[])).generation,
        3,
      );
      expect(
        _frame(
          a,
          _payload(glyphs: <Map<String, Object?>>[_g('丙', 0, 0)]),
        ).generation,
        4,
      );
    });

    test('会话第一帧正文为空 → 0', () {
      final TyranoDomFrameAssembler a = TyranoDomFrameAssembler();
      expect(
        _frame(a, _payload(glyphs: <Map<String, Object?>>[])).generation,
        0,
      );
      expect(a.generation, 0);
    });
  });
}

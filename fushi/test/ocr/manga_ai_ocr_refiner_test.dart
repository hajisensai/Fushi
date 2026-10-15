import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/manga_ai_ocr_refiner.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/ppocr_line_recognizer.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

/// 漫画 OCR 大模型识别层：挑块（档位 × 置信度）、发图、本地校验、落行几何、
/// 缓存与失败处理。全部用 MockClient，不打真网。
void main() {
  final AiProviderConfig provider = AiProviderConfig(
    id: 'p',
    presetId: kAiCustomPresetId,
    name: 'p',
    baseUrl: Uri.parse('https://example.com/v1'),
    apiKey: 'k',
    model: 'vision',
  );

  final Uint8List pageBytes = Uint8List.fromList(
    img.encodePng(img.Image(width: 200, height: 100)),
  );

  MokuroBlock block(
    String text, {
    double? confidence,
    double left = 10,
    List<List<List<double>>>? linesCoords,
    List<String>? lines,
  }) => MokuroBlock(
    rectangle: MokuroRect.fromLTRB(left, 10, left + 40, 90),
    isVertical: true,
    fontSize: 20,
    zIndex: 0,
    lines: lines ?? <String>[text],
    linesCoords: linesCoords,
    confidence: confidence,
  );

  MokuroImage page(List<MokuroBlock> blocks) => MokuroImage(
    url: 'p1.png',
    size: const MokuroSize(200, 100),
    blocks: blocks,
  );

  /// 回放固定回复并记下每次请求带了几张图。
  ({AiChatClient Function() factory, List<int> imagesPerRequest}) fake(
    String Function(int call) reply, {
    int status = 200,
  }) {
    final List<int> imagesPerRequest = <int>[];
    int calls = 0;
    AiChatClient factory() => AiChatClient(
      client: MockClient((http.Request request) async {
        final Map<String, Object?> body =
            jsonDecode(request.body) as Map<String, Object?>;
        final List<Object?> messages = body['messages']! as List<Object?>;
        final Object? content =
            (messages.last! as Map<String, Object?>)['content'];
        imagesPerRequest.add(
          content is List
              ? content
                    .where(
                      (Object? part) => (part! as Map)['type'] == 'image_url',
                    )
                    .length
              : 0,
        );
        final String text = reply(calls++);
        return http.Response(
          jsonEncode(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'message': <String, Object?>{'content': text},
              },
            ],
          }),
          status,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );
    return (factory: factory, imagesPerRequest: imagesPerRequest);
  }

  group('挑块', () {
    test('只读低置信度：高分与不出分（null）的块都不送', () async {
      final f = fake((_) => '{"blocks":[{"id":1,"text":"機嫌"}]}');
      final MangaAiOcrRefiner refiner = MangaAiOcrRefiner(
        provider: provider,
        mode: MangaAiOcrMode.lowConfidence,
        clientFactory: f.factory,
      );
      final result = await refiner.refinePage(
        page(<MokuroBlock>[
          block('期限', confidence: 0.4),
          block('元気', confidence: 0.99, left: 60),
          block('不明', left: 110),
        ]),
        pageBytes,
      );
      expect(f.imagesPerRequest, <int>[1]);
      expect(result.page.blocks[0].lines, <String>['機嫌']);
      expect(result.page.blocks[0].aiRecognized, isTrue);
      expect(result.page.blocks[1].lines, <String>['元気']);
      expect(result.page.blocks[2].lines, <String>['不明']);
      expect(result.stats.candidates, 1);
      expect(result.stats.replaced, 1);
    });

    test('全部：每个块都送，同一请求按编号对回', () async {
      final f = fake(
        (_) =>
            '```json\n{"blocks":[{"id":2,"text":"B"},{"id":1,"text":"A"},'
            '{"id":3,"text":"C"}]}\n```',
      );
      final MangaAiOcrRefiner refiner = MangaAiOcrRefiner(
        provider: provider,
        mode: MangaAiOcrMode.all,
        clientFactory: f.factory,
      );
      final result = await refiner.refinePage(
        page(<MokuroBlock>[
          block('a', confidence: 0.99),
          block('b', left: 60),
          block('c', confidence: 0.1, left: 110),
        ]),
        pageBytes,
      );
      expect(f.imagesPerRequest, <int>[3]);
      expect(
        <String>[
          for (final MokuroBlock b in result.page.blocks) b.lines.join(),
        ],
        <String>['A', 'B', 'C'],
      );
    });

    test('已被大模型读过的块不再送（不重复花钱）', () async {
      final f = fake((_) => '{"blocks":[]}');
      final MangaAiOcrRefiner refiner = MangaAiOcrRefiner(
        provider: provider,
        mode: MangaAiOcrMode.all,
        clientFactory: f.factory,
      );
      final MokuroBlock done = MokuroBlock(
        rectangle: const MokuroRect.fromLTRB(10, 10, 50, 90),
        isVertical: true,
        fontSize: 20,
        zIndex: 0,
        lines: const <String>['済'],
        aiRecognized: true,
      );
      await refiner.refinePage(page(<MokuroBlock>[done]), pageBytes);
      expect(f.imagesPerRequest, isEmpty);
    });
  });

  group('本地校验与失败', () {
    test('回复过长 / 为空 / 编号越界都保留本地文字', () async {
      final f = fake(
        (_) =>
            '{"blocks":[{"id":1,"text":"${'長' * 40}"},{"id":2,"text":"  "},'
            '{"id":9,"text":"X"}]}',
      );
      final MangaAiOcrRefiner refiner = MangaAiOcrRefiner(
        provider: provider,
        mode: MangaAiOcrMode.all,
        clientFactory: f.factory,
      );
      final result = await refiner.refinePage(
        page(<MokuroBlock>[block('短い'), block('空', left: 60)]),
        pageBytes,
      );
      expect(result.page.blocks[0].lines, <String>['短い']);
      expect(result.page.blocks[1].lines, <String>['空']);
      expect(result.stats.replaced, 0);
    });

    test('鉴权失败后整卷不再发请求', () async {
      final f = fake((_) => '{}', status: 401);
      final MangaAiOcrRefiner refiner = MangaAiOcrRefiner(
        provider: provider,
        mode: MangaAiOcrMode.all,
        clientFactory: f.factory,
      );
      final first = await refiner.refinePage(
        page(<MokuroBlock>[block('一')]),
        pageBytes,
      );
      expect(first.stats.failure, 'unauthorized');
      expect(refiner.fatalFailure, 'unauthorized');
      final second = await refiner.refinePage(
        page(<MokuroBlock>[block('二')]),
        pageBytes,
      );
      expect(f.imagesPerRequest, hasLength(1));
      expect(second.page.blocks.single.lines, <String>['二']);
    });

    test('磁盘缓存命中时不发请求', () async {
      final Directory dir = await Directory.systemTemp.createTemp('ai_ocr_');
      addTearDown(() => dir.delete(recursive: true));
      final MangaAiOcrCache cache = MangaAiOcrCache.forVolume(
        dir.path,
        provider,
      );
      final f = fake((_) => '{"blocks":[{"id":1,"text":"機嫌"}]}');
      MangaAiOcrRefiner refiner() => MangaAiOcrRefiner(
        provider: provider,
        mode: MangaAiOcrMode.all,
        clientFactory: f.factory,
      );
      await refiner().refinePage(
        page(<MokuroBlock>[block('期限')]),
        pageBytes,
        cache: cache,
      );
      final result = await refiner().refinePage(
        page(<MokuroBlock>[block('期限')]),
        pageBytes,
        cache: MangaAiOcrCache.forVolume(dir.path, provider),
      );
      expect(f.imagesPerRequest, hasLength(1));
      expect(result.page.blocks.single.lines, <String>['機嫌']);
      expect(result.stats.cached, 1);
    });
  });

  group('行几何', () {
    List<List<double>> rect(double l, double t, double r, double b) =>
        <List<double>>[
          <double>[l, t],
          <double>[r, t],
          <double>[r, b],
          <double>[l, b],
        ];

    test('模型行数与原行框一致：逐行替换、保留行框', () {
      final MokuroBlock source = block(
        '',
        lines: <String>['ab', 'cd'],
        linesCoords: <List<List<double>>>[
          rect(30, 10, 40, 90),
          rect(10, 10, 20, 90),
        ],
      );
      final MokuroBlock out = applyMangaAiOcrText(source, '一二\n三四');
      expect(out.lines, <String>['一二', '三四']);
      expect(out.linesCoords, source.linesCoords);
      expect(out.aiRecognized, isTrue);
    });

    test('行数对不上：按原行框重新排版，拼回去仍是模型原文', () {
      final MokuroBlock source = block(
        '',
        lines: <String>['ab', 'cd'],
        linesCoords: <List<List<double>>>[
          rect(30, 10, 40, 90),
          rect(10, 10, 20, 90),
        ],
      );
      final MokuroBlock out = applyMangaAiOcrText(source, '一二三四');
      expect(out.lines.join(), '一二三四');
      expect(out.linesCoords, isNotNull);
      expect(out.linesCoords!.length, out.lines.length);
    });

    // Lens 块：没有 linesCoords，两列竖排的几何只在逐字 regions 里（右列「一二」、
    // 左列「三四」）。
    MokuroBlock lensTwoColumns() {
      MangaOcrTextRegion char(int at, double l, double t) => MangaOcrTextRegion(
        rectangle: MokuroRect.fromLTRB(l, t, l + 10, t + 40),
        utf16Start: at,
        utf16End: at + 1,
      );
      return MokuroBlock(
        rectangle: MokuroRect.fromLTRB(10, 10, 40, 90),
        isVertical: true,
        fontSize: 10,
        zIndex: 0,
        lines: <String>['一二三四'],
        regions: <MangaOcrTextRegion>[
          char(0, 30, 10),
          char(1, 30, 50),
          char(2, 10, 10),
          char(3, 10, 50),
        ],
      );
    }

    test('Lens 块模型读出同样的字：逐字热区原样保留', () {
      final MokuroBlock source = lensTwoColumns();
      final MokuroBlock out = applyMangaAiOcrText(source, '一二\n三四');
      expect(out.lines, source.lines);
      expect(out.regions, same(source.regions));
      expect(out.aiRecognized, isTrue);
    });

    test('Lens 块文字变了：按逐字热区聚回列框排版，不退成横跨两列的单行', () {
      final MokuroBlock out = applyMangaAiOcrText(lensTwoColumns(), '一二三四五');
      expect(out.lines.join(), '一二三四五');
      expect(out.regions, isNull, reason: '旧偏移量对新文字无效');
      expect(out.linesCoords, isNotNull);
      expect(out.linesCoords, hasLength(2));
      expect(out.lines, hasLength(2));
      // 阅读序：第一列落在右列（x 30–40），第二列落在左列（x 10–20）。
      final List<double> firstXs = <double>[
        for (final List<double> p in out.linesCoords![0]) p[0],
      ];
      final List<double> secondXs = <double>[
        for (final List<double> p in out.linesCoords![1]) p[0],
      ];
      expect(firstXs.every((double x) => x >= 30 && x <= 40), isTrue);
      expect(secondXs.every((double x) => x >= 10 && x <= 20), isTrue);
    });

    test('Lens 斜块文字变了：从逐字热区拟合出倾角，重排后的列框仍沿斜列', () {
      const double tilt = 5 * math.pi / 180;
      final double c = math.cos(tilt), s = math.sin(tilt);
      // 两列竖排各 10 个 30×30 的字，整块顺时针斜 5°；Lens 只给每个字旋转后的
      // 轴对齐外接框（协议层丢掉了字的旋转）。列向下走 = 局部 (0, 1) → (-s, c)，
      // 下一列在左边 = 局部 (-1, 0) → (-c, -s)。
      final double half = 15 * (c + s);
      final List<MangaOcrTextRegion> regions = <MangaOcrTextRegion>[];
      for (int column = 0; column < 2; column++) {
        for (int k = 0; k < 10; k++) {
          final double cx = 300 - k * 32 * s - column * 40 * c;
          final double cy = 50 + k * 32 * c - column * 40 * s;
          final int at = column * 10 + k;
          regions.add(
            MangaOcrTextRegion(
              rectangle: MokuroRect.fromLTRB(
                cx - half,
                cy - half,
                cx + half,
                cy + half,
              ),
              utf16Start: at,
              utf16End: at + 1,
            ),
          );
        }
      }
      final MokuroBlock source = MokuroBlock(
        rectangle: MokuroRect.fromLTRB(200, 20, 330, 380),
        isVertical: true,
        fontSize: 30,
        zIndex: 0,
        lines: <String>['あいうえおかきくけこさしすせそたちつてと'],
        regions: regions,
      );
      // 21 字一行：文字变了、行数也与两列对不上，走重排。
      const String text = '一二三四五六七八九十一二三四五六七八九十一';
      final MokuroBlock out = applyMangaAiOcrText(source, text);
      expect(out.lines.join(), text);
      expect(out.regions, isNull);
      expect(out.linesCoords, isNotNull);
      expect(out.linesCoords, hasLength(out.lines.length));
      expect(out.lines.length, greaterThanOrEqualTo(2));
      for (final List<List<double>> quad in out.linesCoords!) {
        final double edgeAngle = math.atan2(
          quad[1][1] - quad[0][1],
          quad[1][0] - quad[0][0],
        );
        expect(edgeAngle, closeTo(tilt, 1e-6), reason: '重排出的列框必须沿斜列');
      }
      // 阅读序：第一列仍在右边。
      double centerX(List<List<double>> quad) =>
          quad.fold<double>(0, (double sum, List<double> p) => sum + p[0]) / 4;
      expect(
        centerX(out.linesCoords!.first),
        greaterThan(centerX(out.linesCoords!.last)),
      );
    });

    test('行数对不上且原行框是斜的：重排后的行框保留原倾角', () {
      const double tilt = -20 * math.pi / 180;
      // 30×180 的列斜 20° 后外接框约 90×180（宽 = 30cos + 180sin）。
      final MokuroBlock source = block(
        '',
        lines: <String>['ab', 'cd'],
        linesCoords: <List<List<double>>>[
          mangaTiltedLineQuad(
            const OcrRect(left: 70, top: 10, right: 160, bottom: 190),
            tilt,
          ),
          mangaTiltedLineQuad(
            const OcrRect(left: 0, top: 10, right: 90, bottom: 190),
            tilt,
          ),
        ],
      );
      expect(
        mokuroOrientedRectFromQuad(source.linesCoords!.first)!.rotation,
        closeTo(tilt, 1e-6),
        reason: '夹具本身必须是合法的斜行',
      );
      final MokuroBlock out = applyMangaAiOcrText(source, '一二三四');
      expect(out.lines.join(), '一二三四');
      for (final List<List<double>> quad in out.linesCoords!) {
        expect(mokuroOrientedRectFromQuad(quad)!.rotation, closeTo(tilt, 1e-6));
      }
    });

    test('行数对不上、首列短到倾角被判可忽略：倾角取最长列，长列仍旋转', () {
      const double tilt = 3 * math.pi / 180;
      // 宽 [a]、高 [b] 的列绕 ([cx], [cy]) 斜 [tilt]（与 mangaTiltedLineQuad 同向）。
      List<List<double>> column(double cx, double cy, double a, double b) {
        final double ux = math.cos(tilt), uy = math.sin(tilt);
        final double vx = -math.sin(tilt), vy = math.cos(tilt);
        List<double> corner(double du, double dv) => <double>[
          cx + du * ux + dv * vx,
          cy + du * uy + dv * vy,
        ];
        return <List<double>>[
          corner(-a / 2, -b / 2),
          corner(a / 2, -b / 2),
          corner(a / 2, b / 2),
          corner(-a / 2, b / 2),
        ];
      }

      // 竖排右起：首列 3 个字（30×90），次列 20 个字（30×600）。
      final List<List<double>> shortColumn = column(200, 60, 30, 90);
      final List<List<double>> longColumn = column(150, 315, 30, 600);
      expect(
        mokuroOrientedRectFromQuad(shortColumn)!.rotation,
        0,
        reason: '夹具前提：短列自身的 3° 被判可忽略、归 0',
      );
      expect(
        mokuroOrientedRectFromQuad(longColumn)!.rotation,
        closeTo(tilt, 1e-9),
        reason: '夹具前提：长列的 3° 不可忽略',
      );
      final MokuroBlock source = block(
        '',
        lines: <String>['abc', 'd'],
        linesCoords: <List<List<double>>>[shortColumn, longColumn],
      );
      // 一行 23 字，与原行数（2）对不上，走重排。
      const String text = '一二三四五六七八九十一二三四五六七八九十一二三';
      final MokuroBlock out = applyMangaAiOcrText(source, text);
      expect(out.lines.join(), text);
      expect(out.linesCoords, isNotNull);
      for (final List<List<double>> quad in out.linesCoords!) {
        // 直接看首边方向：短格即便会被拟合判可忽略，写回的四边形也该是转过的。
        final double edgeAngle = math.atan2(
          quad[1][1] - quad[0][1],
          quad[1][0] - quad[0][0],
        );
        expect(edgeAngle, closeTo(tilt, 1e-6));
      }
      expect(
        out.linesCoords!.any(
          (List<List<double>> quad) =>
              (mokuroOrientedRectFromQuad(quad)!.rotation - tilt).abs() < 1e-6,
        ),
        isTrue,
        reason: '长列重排出的行格必须仍是斜的（不能全退回轴对齐）',
      );
    });

    test('没有行几何：整块单行', () {
      final MokuroBlock out = applyMangaAiOcrText(block('x'), '機嫌の\n悪い');
      expect(out.lines, <String>['機嫌の悪い']);
      expect(out.linesCoords, isNull);
    });
  });

  test('回复解析：字符串编号也收，坏条目跳过', () {
    expect(
      parseMangaAiOcrReply(
        'ok {"blocks":[{"id":"1","text":"甲"},{"id":2},{"id":2.0,"text":"乙"}]}',
        count: 2,
      ),
      <int, String>{1: '甲', 2: '乙'},
    );
    expect(parseMangaAiOcrReply('no json', count: 1), isNull);
  });

  group('置信度', () {
    test('CTC：文字与贪心解码一致，置信度取吐字帧最小概率', () {
      // 3 帧 × 3 词（0 = blank）：a(0.9) blank b(0.6)
      final Float32List probs = Float32List.fromList(<double>[
        0.05, 0.9, 0.05, //
        0.8, 0.1, 0.1, //
        0.2, 0.2, 0.6, //
      ]);
      final scored = ctcGreedyDecodeScored(probs, 3, 3, <String>['', 'a', 'b']);
      expect(scored.text, ctcGreedyDecode(probs, 3, 3, <String>['', 'a', 'b']));
      expect(scored.text, 'ab');
      expect(scored.confidence, closeTo(0.6, 1e-6));
    });

    test('OcrBlock / MokuroBlock 往返保留置信度与大模型标记', () {
      const OcrBlock ocr = OcrBlock(
        box: OcrRect(left: 0, top: 0, right: 1, bottom: 1),
        vertical: true,
        lines: <String>['字'],
        confidence: 0.42,
      );
      expect(OcrBlock.fromJson(ocr.toJson()).confidence, 0.42);
      expect(
        OcrBlock.fromJson((ocr.toJson()..remove('confidence'))).confidence,
        isNull,
      );

      final MokuroPayload payload = MokuroPayload(
        images: <MokuroImage>[
          MokuroImage(
            url: 'p1.png',
            size: const MokuroSize(10, 10),
            blocks: <MokuroBlock>[
              const MokuroBlock(
                rectangle: MokuroRect.fromLTRB(0, 0, 1, 1),
                isVertical: true,
                fontSize: 10,
                zIndex: 0,
                lines: <String>['字'],
                confidence: 0.42,
                aiRecognized: true,
              ),
            ],
          ),
        ],
      );
      final MokuroBlock back = parseMangaJson(
        jsonEncode(mangaPayloadToJson(payload)),
      ).images.single.blocks.single;
      expect(back.confidence, 0.42);
      expect(back.aiRecognized, isTrue);
    });
  });

  group('空白（英文 / 韩文 / 日文）', () {
    MokuroBlock horizontal(String text) => MokuroBlock(
      rectangle: const MokuroRect.fromLTRB(10, 10, 190, 40),
      isVertical: false,
      fontSize: 20,
      zIndex: 0,
      lines: <String>[text],
    );

    test('英文：行内空格保留、连续空白折叠成一个、行间接缝补空格', () {
      expect(
        applyMangaAiOcrText(horizontal('x'), '  sorry   I cannot  ').lines,
        <String>['sorry I cannot'],
      );
      expect(applyMangaAiOcrText(horizontal('HEY'), 'HEY\tYOU').lines, <String>[
        'HEY YOU',
      ], reason: '本地是单词块（无空白）也不能把模型给的词界删掉');
      expect(
        applyMangaAiOcrText(horizontal('x'), 'sorry I\ncannot do it').lines,
        <String>['sorry I cannot do it'],
      );
    });

    test('韩文：谚文按词分写，空格保留', () {
      expect(
        applyMangaAiOcrText(horizontal('미안'), '미안 해요\n정말  고마워').lines,
        <String>['미안 해요 정말 고마워'],
      );
    });

    test('日文：假名 / 汉字之间的空白去掉，拉丁词贴着日文也去掉', () {
      expect(applyMangaAiOcrText(block('x'), 'ありがとう ございます').lines, <String>[
        'ありがとうございます',
      ]);
      expect(applyMangaAiOcrText(block('x'), 'OK ですね\n機嫌 の 悪い').lines, <String>[
        'OKですね機嫌の悪い',
      ]);
    });
  });

  group('长度上限按框的几何', () {
    List<List<double>> column(double l, double r) => <List<double>>[
      <double>[l, 10],
      <double>[r, 10],
      <double>[r, 90],
      <double>[l, 90],
    ];

    test('本地漏读大半的低置信度块：框装得下的重读不被当成幻觉', () async {
      // 40×80 的框、列宽 10 → 约 32 字的容量；本地只认出 2 个字。
      final MokuroBlock source = block(
        '機嫌',
        confidence: 0.2,
        lines: <String>['機', '嫌'],
        linesCoords: <List<List<double>>>[column(40, 50), column(10, 20)],
      );
      expect(mangaAiOcrBlockCapacity(source), 32);
      const String reread = '機嫌の悪い日は何もしたくないんだよ';
      expect(reread.length, greaterThan('機嫌'.length * 3 + 8));
      expect(
        isPlausibleMangaAiOcrText(reread, local: '機嫌', block: source),
        isTrue,
      );
      expect(
        isPlausibleMangaAiOcrText(reread, local: '機嫌'),
        isFalse,
        reason: '不给几何时退回按本地长度的旧上限',
      );
      expect(
        isPlausibleMangaAiOcrText('長' * 60, local: '機嫌', block: source),
        isFalse,
        reason: '超出框的容量仍判为幻觉',
      );

      final f = fake((_) => '{"blocks":[{"id":1,"text":"$reread"}]}');
      final result = await MangaAiOcrRefiner(
        provider: provider,
        mode: MangaAiOcrMode.lowConfidence,
        clientFactory: f.factory,
      ).refinePage(page(<MokuroBlock>[source]), pageBytes);
      expect(result.stats.replaced, 1);
      expect(result.page.blocks.single.lines.join(), reread);
    });

    test('没有行几何时按块字号估容量；尺寸为零给不出容量', () {
      expect(mangaAiOcrBlockCapacity(block('x')), 8); // 40×80 / 20²
      expect(
        mangaAiOcrBlockCapacity(
          const MokuroBlock(
            rectangle: MokuroRect.fromLTRB(0, 0, 0, 0),
            isVertical: true,
            fontSize: 20,
            zIndex: 0,
            lines: <String>['x'],
          ),
        ),
        isNull,
      );
    });
  });

  group('取消', () {
    test('在途请求被中止，之后不再发请求、交回本地结果', () async {
      final _GatedChatClient client = _GatedChatClient(
        '{"blocks":[{"id":1,"text":"機嫌"}]}',
      );
      final MangaAiOcrRefiner refiner = MangaAiOcrRefiner(
        provider: provider,
        mode: MangaAiOcrMode.all,
        clientFactory: () => client,
      );
      final Future<({MokuroImage page, MangaAiOcrPageStats stats})> running =
          refiner.refinePage(page(<MokuroBlock>[block('期限')]), pageBytes);
      await client.started.future;
      refiner.cancel();
      final result = await running;
      expect(client.closed, isTrue, reason: '取消要关掉在途请求的客户端');
      expect(result.page.blocks.single.lines, <String>['期限']);
      expect(result.stats.replaced, 0);

      final after = await refiner.refinePage(
        page(<MokuroBlock>[block('元気')]),
        pageBytes,
      );
      expect(client.calls, 1, reason: '取消后不再发请求');
      expect(after.page.blocks.single.lines, <String>['元気']);
    });
  });

  group('缓存并发', () {
    test('同一文件两个实例并发写：条目都在，不留临时文件', () async {
      final Directory dir = await Directory.systemTemp.createTemp('ai_cache_');
      addTearDown(() => dir.delete(recursive: true));
      final MangaAiOcrCache a = MangaAiOcrCache.forVolume(dir.path, provider);
      final MangaAiOcrCache b = MangaAiOcrCache.forVolume(dir.path, provider);
      // 两个实例都先把（空的）盘上内容读进内存，再交错写。
      expect(await a.lookup('x'), isNull);
      expect(await b.lookup('x'), isNull);
      await Future.wait(<Future<void>>[
        for (int i = 0; i < 20; i++)
          (i.isEven ? a : b).storeAll(<String, String>{'k$i': 'v$i'}),
      ]);
      final MangaAiOcrCache fresh = MangaAiOcrCache.forVolume(
        dir.path,
        provider,
      );
      for (int i = 0; i < 20; i++) {
        expect(await fresh.lookup('k$i'), 'v$i', reason: 'k$i 被后写者吞掉了');
      }
      expect(
        a.file.parent.listSync().where(
          (FileSystemEntity e) => e.path.endsWith('.tmp'),
        ),
        isEmpty,
      );
    });

    test('clear 之后查不到旧条目', () async {
      final Directory dir = await Directory.systemTemp.createTemp('ai_cache_');
      addTearDown(() => dir.delete(recursive: true));
      final MangaAiOcrCache cache = MangaAiOcrCache.forVolume(
        dir.path,
        provider,
      );
      await cache.storeAll(<String, String>{'k': 'v'});
      await cache.clear();
      expect(await cache.lookup('k'), isNull);
      expect(
        await MangaAiOcrCache.forVolume(dir.path, provider).lookup('k'),
        isNull,
      );
    });
  });

  test('档位键往返；未知键退回关', () {
    for (final MangaAiOcrMode mode in MangaAiOcrMode.values) {
      expect(MangaAiOcrMode.fromStorageKey(mode.storageKey), mode);
    }
    expect(MangaAiOcrMode.fromStorageKey('bogus'), MangaAiOcrMode.off);
    expect(MangaAiOcrMode.fromStorageKey(null), MangaAiOcrMode.off);
  });
}

/// 请求挂起直到 [release] 或 [close]（close 模拟真实客户端关闭时中止在途请求）。
class _GatedChatClient extends AiChatClient {
  _GatedChatClient(this.reply);

  final String reply;
  final Completer<void> started = Completer<void>();
  final Completer<void> _gate = Completer<void>();
  int calls = 0;
  bool closed = false;

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<String> complete({
    required AiProviderConfig provider,
    required List<AiChatMessage> messages,
    int maxTokens = 2048,
  }) async {
    calls += 1;
    if (!started.isCompleted) started.complete();
    await _gate.future;
    if (closed) throw const AiChatFailure('network_error');
    return reply;
  }

  @override
  void close() {
    closed = true;
    release();
  }
}

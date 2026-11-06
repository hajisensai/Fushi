// 浏览器扩展「抓图取词」端点（POST /api/ocr/image）的契约守卫。
//
// canvas 渲染的网页阅读器（BookWalker 等）没有文本节点，扩展只能把 canvas 截图交给 app 识别。
// 这里钉住：
//   1) 请求体 image 的解码（裸 base64 / data URL / 非法）；
//   2) 识别结果摊成「一块一句 + 每字截图像素框 + 字素下标」的 JSON，扩展据此命中字；
//   3) 端点：未注入 404、缺图 400、引擎不可用回 {error:<原因>} 而不是连接错误；
//   4) 识别服务：引擎不可用时丢掉会话，下一次请求重新探测（装好模型后不必重启 app）；
//      设置变了换新会话；app 内浏览器的 `ocrImage` 消息落到同一个端点。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_stream_ocr.dart';
import 'package:fushi/src/media/video/graphic_subtitle_ocr.dart';
import 'package:fushi/src/sync/extension_image_ocr.dart';
import 'package:fushi/src/sync/extension_image_ocr_service.dart';
import 'package:fushi/src/sync/fushi_extension_api_core.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_messages.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

final Uint8List _png = Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 1, 2]);

GraphicSubtitleOcrFrame _frame() => const GraphicSubtitleOcrFrame(
  imageSize: Size(800, 600),
  chars: <GraphicSubtitleOcrChar>[
    (sentence: '吾輩は', graphemeIndex: 0, rect: Rect.fromLTWH(10, 20, 30, 40)),
    (sentence: '吾輩は', graphemeIndex: 1, rect: Rect.fromLTWH(40, 20, 30, 40)),
    (sentence: '吾輩は', graphemeIndex: 2, rect: Rect.fromLTWH(70, 20, 30, 40)),
    (sentence: '猫', graphemeIndex: 0, rect: Rect.fromLTWH(10, 80, 30, 40)),
    // 两块恰好同一句：下标回到 0 就是新块。
    (sentence: '猫', graphemeIndex: 0, rect: Rect.fromLTWH(300, 80, 30, 40)),
  ],
);

class _FakeRecognizer implements MangaStreamPageRecognizer {
  int calls = 0;
  bool closed = false;

  @override
  Future<MokuroImage> recognize(File pageFile) async {
    expect(pageFile.existsSync(), isTrue, reason: '截图应落成文件交给页级识别');
    calls++;
    return MokuroImage(
      url: 'frame.png',
      size: const MokuroSize(800, 600),
      blocks: <MokuroBlock>[
        MokuroBlock(
          rectangle: MokuroRect.fromLTRB(100, 100, 220, 140),
          isVertical: false,
          fontSize: 40,
          zIndex: 0,
          lines: const <String>['猫である'],
        ),
      ],
    );
  }

  @override
  Future<void> close() async => closed = true;
}

void main() {
  group('decodeExtensionOcrImage', () {
    test('裸 base64 与 data URL 都认；非法 / 空 / 非 base64 data URL 回 null', () {
      final String b64 = base64Encode(_png);
      expect(decodeExtensionOcrImage(b64), _png);
      expect(decodeExtensionOcrImage('data:image/png;base64,$b64'), _png);
      expect(decodeExtensionOcrImage('data:image/png,$b64'), isNull);
      expect(decodeExtensionOcrImage('***'), isNull);
      expect(decodeExtensionOcrImage(''), isNull);
      expect(decodeExtensionOcrImage(42), isNull);
    });
  });

  test('识别结果摊成「一块一句 + 每字截图像素框 + 字素下标」', () {
    final Map<String, dynamic> json = extensionOcrFrameJson(_frame());
    expect(json['width'], 800);
    expect(json['height'], 600);
    final List<dynamic> blocks = json['blocks'] as List<dynamic>;
    expect(
      blocks.map((dynamic b) => (b as Map<String, dynamic>)['text']),
      <String>['吾輩は', '猫', '猫'],
    );
    final List<dynamic> first =
        (blocks.first as Map<String, dynamic>)['chars'] as List<dynamic>;
    expect(first, hasLength(3));
    expect(first[1], <String, dynamic>{
      'i': 1,
      'x': 40.0,
      'y': 20.0,
      'w': 30.0,
      'h': 40.0,
    });
  });

  group('FushiExtensionApiCore /api/ocr/image', () {
    test('未注入识别器：404（旧 app / 配对 sync host 照旧）', () async {
      final FushiExtensionApiResponse r = await FushiExtensionApiCore().handle(
        FushiExtensionApiCore.ocrImagePath,
        <String, dynamic>{'image': base64Encode(_png)},
      );
      expect(r.status, 404);
    });

    test('缺图 400；有图交给识别器并回 JSON', () async {
      Uint8List? got;
      final FushiExtensionApiCore core = FushiExtensionApiCore(
        imageOcr: (Uint8List image) async {
          got = image;
          return _frame();
        },
      );
      expect(
        (await core.handle(
          FushiExtensionApiCore.ocrImagePath,
          <String, dynamic>{},
        )).status,
        400,
      );
      final FushiExtensionApiResponse r = await core.handle(
        FushiExtensionApiCore.ocrImagePath,
        <String, dynamic>{
          'image': 'data:image/png;base64,${base64Encode(_png)}',
        },
      );
      expect(r.ok, isTrue);
      expect(got, _png);
      expect((r.json!['blocks'] as List<dynamic>), hasLength(3));
    });

    test('引擎不可用回 {error:<原因>}（200），扩展据此提示装引擎而不是「连不上」', () async {
      final FushiExtensionApiCore core = FushiExtensionApiCore(
        imageOcr: (Uint8List _) async =>
            throw const GraphicSubtitleOcrUnavailable(
              GraphicSubtitleOcrUnavailableReason.noEngine,
            ),
      );
      final FushiExtensionApiResponse r = await core.handle(
        FushiExtensionApiCore.ocrImagePath,
        <String, dynamic>{'image': base64Encode(_png)},
      );
      expect(r.status, 200);
      expect(r.json, <String, dynamic>{
        'error': 'noEngine',
        'blocks': <Object?>[],
      });
    });

    test('识别本身失败（会话途中被关 / 拿不到 context / 识别器报错）回 200 + {error:failed}，'
        '不是 500——否则扩展会误报「连不上 Fushi」', () async {
      for (final (String label, Never Function() fail)
          in <(String, Never Function())>[
            ('session closed', () => throw StateError('session closed')),
            ('no context', () => throw StateError('No navigator context')),
            ('recognizer', () => throw Exception('recognizer crashed')),
          ]) {
        final String thrown = label;
        final FushiExtensionApiCore core = FushiExtensionApiCore(
          imageOcr: (Uint8List _) async => fail(),
        );
        final FushiExtensionApiResponse r = await core.handle(
          FushiExtensionApiCore.ocrImagePath,
          <String, dynamic>{'image': base64Encode(_png)},
        );
        expect(r.status, 200, reason: thrown);
        expect(r.json, <String, dynamic>{
          'error': kExtensionOcrRecognizeFailed,
          'blocks': <Object?>[],
        }, reason: thrown);
      }
    });

    test(
      'app 内浏览器的 canvasOcrCapture：截该标签页 WebView，回包与 background 同形',
      () async {
        WebBrowserExtensionHostServices services(
          Future<Uint8List?> Function()? capture,
        ) => WebBrowserExtensionHostServices(
          api: FushiExtensionApiCore().handle,
          openSidePanel: () {},
          openOptions: () {},
          dismissLookup: () {},
          captureViewport: capture,
        );
        final Map<String, Object?> ok = await routeWebBrowserExtensionMessage(
          <String, dynamic>{'type': 'canvasOcrCapture'},
          services(() async => _png),
        );
        expect(ok, <String, Object?>{
          'ok': true,
          'dataUrl': 'data:image/png;base64,${base64Encode(_png)}',
        });
        final Map<String, Object?> empty =
            await routeWebBrowserExtensionMessage(<String, dynamic>{
              'type': 'canvasOcrCapture',
            }, services(() async => null));
        expect(empty, <String, Object?>{'ok': false, 'error': 'empty-capture'});
        final Map<String, Object?> none = await routeWebBrowserExtensionMessage(
          <String, dynamic>{'type': 'canvasOcrCapture'},
          services(null),
        );
        expect(none, kWebBrowserExtensionUnsupported);
      },
    );

    test('app 内浏览器的 ocrImage 消息落到同一个端点，回包与扩展 background 同形', () async {
      final FushiExtensionApiCore core = FushiExtensionApiCore(
        imageOcr: (Uint8List _) async => _frame(),
      );
      final Map<String, Object?> reply = await routeWebBrowserExtensionMessage(
        <String, dynamic>{'type': 'ocrImage', 'image': base64Encode(_png)},
        WebBrowserExtensionHostServices(
          api: core.handle,
          openSidePanel: () {},
          openOptions: () {},
          dismissLookup: () {},
        ),
      );
      expect(reply['ok'], isTrue);
      expect(
        ((reply['data'] as Map<String, dynamic>)['blocks'] as List<dynamic>),
        hasLength(3),
      );
    });
  });

  group('ExtensionImageOcrService', () {
    test('引擎不可用时丢掉会话：装好引擎后下一次请求重新探测，不必重启 app', () async {
      int prepares = 0;
      final _FakeRecognizer recognizer = _FakeRecognizer();
      final ExtensionImageOcrService service = ExtensionImageOcrService(
        prepare: (String _) async => ++prepares == 1
            ? const MangaStreamOcrNoEngine()
            : MangaStreamOcrReady(MangaOcrEngineId.localOnnx, recognizer),
        configKey: () => 'k',
      );
      await expectLater(
        service.recognize(_png),
        throwsA(isA<GraphicSubtitleOcrUnavailable>()),
      );
      final GraphicSubtitleOcrFrame frame = await service.recognize(_png);
      expect(prepares, 2);
      expect(
        frame.chars.map((GraphicSubtitleOcrChar c) => c.sentence).toSet(),
        <String>{'猫である'},
      );
      // 同一设置下复用会话：引擎只解析一次。
      await service.recognize(_png);
      expect(prepares, 2);
      expect(recognizer.calls, 2);
      await service.close();
      expect(recognizer.closed, isTrue);
    });

    test('OCR 设置变了（引擎偏好 / 本机模型……）换新会话', () async {
      int prepares = 0;
      String key = 'a';
      final List<_FakeRecognizer> made = <_FakeRecognizer>[];
      final ExtensionImageOcrService service = ExtensionImageOcrService(
        prepare: (String _) async {
          prepares++;
          final _FakeRecognizer r = _FakeRecognizer();
          made.add(r);
          return MangaStreamOcrReady(MangaOcrEngineId.localOnnx, r);
        },
        configKey: () => key,
      );
      await service.recognize(_png);
      key = 'b';
      await service.recognize(_png);
      expect(prepares, 2);
      expect(made.first.closed, isTrue, reason: '换会话前要先关旧会话，免得两份模型同时常驻');
      await service.close();
    });
  });
}

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_clip_export.dart';
import 'package:hibiki/src/media/audiobook/audiobook_clip_text_render.dart';
import 'package:hibiki/src/media/audiobook/audiobook_clip_webview_render.dart';
import 'package:hibiki/src/reader/reader_selection_scripts.dart';
import 'package:image/image.dart' as img;

/// TODO-1127：有声书片段导出把「选区中间夹带的 EPUB 插图」渲进卡片。守卫抽取纯函数解析、
/// 图片按归一化位置归属、竖排 HTML 注入、以及横排栅格帧真含图。
Uint8List _solidPng(int width, int height, int r, int g, int b) {
  final img.Image image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  group('assignClipImagesToCues (TODO-1127 图片按归一化位置归属)', () {
    final Uint8List a = Uint8List.fromList(<int>[1]);
    final Uint8List b = Uint8List.fromList(<int>[2]);
    final Uint8List c = Uint8List.fromList(<int>[3]);

    test('无图 每段空列表', () {
      final List<List<Uint8List>> out = assignClipImagesToCues(
        cueNormStarts: <int?>[0, 50, 100],
        images: const <({int normOffset, Uint8List bytes})>[],
      );
      expect(out.length, 3);
      expect(out.every((List<Uint8List> l) => l.isEmpty), isTrue);
    });

    test('图归属到归一化起点<=图偏移的最后一个cue', () {
      final List<List<Uint8List>> out = assignClipImagesToCues(
        cueNormStarts: <int?>[0, 100, 200],
        images: <({int normOffset, Uint8List bytes})>[
          (normOffset: 150, bytes: a),
        ],
      );
      expect(out[0], isEmpty);
      expect(out[1], <Uint8List>[a]);
      expect(out[2], isEmpty);
    });

    test('图在所有cue之前或偏移未知(-1) 兜底挂第0段绝不丢', () {
      final List<List<Uint8List>> out = assignClipImagesToCues(
        cueNormStarts: <int?>[100, 200],
        images: <({int normOffset, Uint8List bytes})>[
          (normOffset: -1, bytes: a),
          (normOffset: 10, bytes: b),
        ],
      );
      expect(out[0], <Uint8List>[a, b]);
      expect(out[1], isEmpty);
    });

    test('多张图按normOffset升序保留文档序分配到各段', () {
      final List<List<Uint8List>> out = assignClipImagesToCues(
        cueNormStarts: <int?>[0, 100, 200],
        images: <({int normOffset, Uint8List bytes})>[
          (normOffset: 250, bytes: c),
          (normOffset: 50, bytes: a),
          (normOffset: 120, bytes: b),
        ],
      );
      expect(out[0], <Uint8List>[a]);
      expect(out[1], <Uint8List>[b]);
      expect(out[2], <Uint8List>[c]);
    });

    test('无法解码归一化偏移的cue(null)不作归属锚点', () {
      final List<List<Uint8List>> out = assignClipImagesToCues(
        cueNormStarts: <int?>[0, null, 200],
        images: <({int normOffset, Uint8List bytes})>[
          (normOffset: 150, bytes: a),
        ],
      );
      expect(out[0], <Uint8List>[a]);
      expect(out[1], isEmpty);
      expect(out[2], isEmpty);
    });

    test('cueCount==0 空结果不崩', () {
      final List<List<Uint8List>> out = assignClipImagesToCues(
        cueNormStarts: const <int?>[],
        images: <({int normOffset, Uint8List bytes})>[
          (normOffset: 0, bytes: a),
        ],
      );
      expect(out, isEmpty);
    });
  });

  group('clipSelectionImagesFromResult (JS 契约解析)', () {
    test('解析合法JSON数组', () {
      const String raw = '[{"src":"https://hoshi.local/epub/a.png",'
          '"normOffset":42},{"src":"https://hoshi.local/epub/b.jpg",'
          '"normOffset":100}]';
      final List<({String src, int normOffset})> out =
          ReaderSelectionScripts.clipSelectionImagesFromResult(raw);
      expect(out.length, 2);
      expect(out[0].src, 'https://hoshi.local/epub/a.png');
      expect(out[0].normOffset, 42);
      expect(out[1].normOffset, 100);
    });

    test('null 空 null字面量 空列表', () {
      expect(
          ReaderSelectionScripts.clipSelectionImagesFromResult(null), isEmpty);
      expect(ReaderSelectionScripts.clipSelectionImagesFromResult(''), isEmpty);
      expect(ReaderSelectionScripts.clipSelectionImagesFromResult('null'),
          isEmpty);
      expect(
          ReaderSelectionScripts.clipSelectionImagesFromResult('[]'), isEmpty);
    });

    test('缺src跳过 缺normOffset归-1兜底挂前段', () {
      const String raw = '[{"normOffset":5},'
          '{"src":"https://hoshi.local/epub/x.png"}]';
      final List<({String src, int normOffset})> out =
          ReaderSelectionScripts.clipSelectionImagesFromResult(raw);
      expect(out.length, 1);
      expect(out[0].src, 'https://hoshi.local/epub/x.png');
      expect(out[0].normOffset, -1);
    });

    test('非法JSON 空列表不抛', () {
      expect(ReaderSelectionScripts.clipSelectionImagesFromResult('{not json'),
          isEmpty);
    });
  });

  group('buildAudiobookClipVerticalHtml (竖排WebView注入插图data-uri)', () {
    final AudiobookClipTextLayout layout = computeClipTextLayout(
      textLength: 4,
      baseFontSize: 40,
      vertical: true,
      lineHeight: 1.6,
      background: const Color(0xFF000000),
      foreground: const Color(0xFFFFFFFF),
      highlight: const Color(0xFFFF0000),
    );

    test('段落含插图 HTML内联data-uri img.clip-img', () {
      final Uint8List png = _solidPng(8, 8, 0, 255, 0);
      final String html = buildAudiobookClipVerticalHtml(
        segments: <AudiobookClipTextSegment>[
          AudiobookClipTextSegment(text: '第一句', images: <Uint8List>[png]),
          const AudiobookClipTextSegment(text: '第二句'),
        ],
        layout: layout,
      );
      expect(html.contains('<img class="clip-img"'), isTrue);
      expect(html.contains('src="data:image/png;base64,'), isTrue);
      expect(html.contains('.clip-img {'), isTrue);
    });

    test('段落无插图 无img与旧行为一致零差异', () {
      final String html = buildAudiobookClipVerticalHtml(
        segments: const <AudiobookClipTextSegment>[
          AudiobookClipTextSegment(text: '第一句'),
          AudiobookClipTextSegment(text: '第二句'),
        ],
        layout: layout,
      );
      expect(html.contains('<img'), isFalse);
    });

    test('JPEG字节 data-image-jpeg魔数分辨mime', () {
      final img.Image image = img.Image(width: 8, height: 8);
      img.fill(image, color: img.ColorRgb8(10, 20, 30));
      final Uint8List jpg = Uint8List.fromList(img.encodeJpg(image));
      final String html = buildAudiobookClipVerticalHtml(
        segments: <AudiobookClipTextSegment>[
          AudiobookClipTextSegment(text: 'あ', images: <Uint8List>[jpg]),
        ],
        layout: layout,
      );
      expect(html.contains('src="data:image/jpeg;base64,'), isTrue);
    });
  });

  testWidgets(
    'Flutter栅格帧含插图 段落带图渲出帧与无图逐字节不同 图真进帧 TODO-1127',
    (WidgetTester tester) async {
      final GlobalKey<OverlayState> overlayKey = GlobalKey<OverlayState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Overlay(
            key: overlayKey,
            initialEntries: <OverlayEntry>[
              OverlayEntry(
                builder: (BuildContext context) => const SizedBox.expand(),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final OverlayState overlay = overlayKey.currentState!;
      final AudiobookClipTextLayout layout = computeClipTextLayout(
        textLength: 3,
        baseFontSize: 40,
        vertical: false,
        lineHeight: 1.6,
        background: const Color(0xFF000000),
        foreground: const Color(0xFFFFFFFF),
        highlight: const Color(0xFFFF0000),
      );

      final Uint8List greenPng = _solidPng(400, 400, 0, 255, 0);

      Future<Uint8List?> renderOnce(
        List<AudiobookClipTextSegment> segments,
      ) async {
        Uint8List? out;
        await tester.runAsync(() async {
          bool done = false;
          final Future<void> future = renderAudiobookClipFrames(
            overlay: overlay,
            segments: segments,
            layout: layout,
            highlightIndices: <int>[0],
            onFrame: (int highlightIndex, Uint8List? png) async {
              out = png;
              return false;
            },
          ).whenComplete(() => done = true);
          for (int i = 0; i < 200 && !done; i++) {
            await tester.pump(const Duration(milliseconds: 16));
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
          await future;
        });
        return out;
      }

      final Uint8List? withImage = await renderOnce(<AudiobookClipTextSegment>[
        AudiobookClipTextSegment(text: '第一句', images: <Uint8List>[greenPng]),
      ]);
      final Uint8List? withoutImage =
          await renderOnce(<AudiobookClipTextSegment>[
        const AudiobookClipTextSegment(text: '第一句'),
      ]);

      expect(withImage, isNotNull);
      expect(withoutImage, isNotNull);
      expect(withImage!.isNotEmpty, isTrue);
      expect(withImage.sublist(0, 4), <int>[0x89, 0x50, 0x4E, 0x47]);
      expect(withImage, isNot(equals(withoutImage)),
          reason: 'segment image must be rendered into the frame');
    },
  );

  test('source guard: JS侧抽取选区插图三函数在位 TODO-1127', () {
    final String source = ReaderSelectionScripts.source();
    expect(source.contains('nativeSelectionImages:'), isTrue);
    expect(source.contains('resolveClipImageSrc:'), isTrue);
    expect(source.contains('imageNormOffset:'), isTrue);
  });
}

// 反馈 Eemf0HOZhj（BUG-4069）：截屏识字引擎选 / 跟随到 Google Lens 时，Lens 的识别结果
// 转成冻结层的行，点字按 Lens 的逐字框定位。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/floating_ball/screen_ocr_picker.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_ocr_service.dart';
import 'package:fushi/src/ocr/google_lens_screen_ocr.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:material_ui/material_ui.dart';

MangaOcrTextRegion _char(int index, double left, double top) =>
    MangaOcrTextRegion(
      rectangle: MokuroRect.fromLTRB(left, top, left + 40, top + 40),
      utf16Start: index,
      utf16End: index + 1,
    );

/// Lens 一段跨两行显示：「吾輩は」在 y 100..140、「猫である」在 y 150..190，块文字是
/// 两行无分隔拼接「吾輩は猫である」。两行的 x 区间重叠。
MokuroImage _twoRowParagraph() => MokuroImage(
  url: 'screen',
  size: const MokuroSize(3840, 2160),
  blocks: <MokuroBlock>[
    MokuroBlock(
      rectangle: MokuroRect.fromLTRB(100, 100, 260, 190),
      isVertical: false,
      fontSize: 40,
      zIndex: 0,
      lines: const <String>['吾輩は猫である'],
      regions: <MangaOcrTextRegion>[
        _char(0, 100, 100),
        _char(1, 140, 100),
        _char(2, 180, 100),
        _char(3, 100, 150),
        _char(4, 140, 150),
        _char(5, 180, 150),
        _char(6, 220, 150),
      ],
    ),
  ],
);

class _FakeLensRunner implements GoogleLensMangaOcrRunner {
  _FakeLensRunner(this.page);

  final MokuroImage page;
  final List<String> languages = <String>[];

  @override
  Future<MokuroImage> recognizePageBytes(
    Uint8List source, {
    required String relativeUrl,
    required String language,
  }) async {
    languages.add(language);
    return page;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('一块一行，块框作行框、逐字框作词框，竖排沿用 Lens 的判定', () {
    final SystemOcrPageResult result = systemOcrPageFromMokuro(
      _twoRowParagraph(),
    );
    expect(result.imageWidth, 3840);
    expect(result.imageHeight, 2160);
    final SystemOcrTextLine line = result.lines.single;
    expect(line.text, '吾輩は猫である');
    expect(line.rect, const Rect.fromLTRB(100, 100, 260, 190));
    expect(line.isVertical, isFalse);
    expect(line.segments, hasLength(7));
    expect(line.segments[3].start, 3);
    expect(line.segments[3].rect, const Rect.fromLTRB(100, 150, 140, 190));
  });

  test('点第二行的「猫」命中「猫」，不会因为与第一行 x 重叠而落到「吾」', () {
    final SystemOcrPageResult result = systemOcrPageFromMokuro(
      _twoRowParagraph(),
    );
    final ScreenOcrHit hit = screenOcrHitTest(
      lines: result.lines,
      point: const Offset(120, 170),
      scale: 1,
    )!;
    expect(hit.charIndex, 3);
    expect(hit.line.text.substring(hit.charIndex), '猫である');
    expect(hit.charRect, const Rect.fromLTRB(100, 150, 140, 190));
  });

  test('乱序 / 越界的字框整块不带词框（退回等分），空文字块丢掉', () {
    final SystemOcrPageResult result = systemOcrPageFromMokuro(
      MokuroImage(
        url: 'screen',
        size: const MokuroSize(100, 100),
        blocks: <MokuroBlock>[
          MokuroBlock(
            rectangle: MokuroRect.fromLTRB(0, 0, 80, 40),
            isVertical: false,
            fontSize: 40,
            zIndex: 0,
            lines: const <String>['あい'],
            regions: <MangaOcrTextRegion>[_char(1, 40, 0), _char(0, 0, 0)],
          ),
          MokuroBlock(
            rectangle: MokuroRect.fromLTRB(0, 50, 80, 90),
            isVertical: false,
            fontSize: 40,
            zIndex: 1,
            lines: const <String>['  '],
          ),
        ],
      ),
    );
    expect(result.lines.single.text, 'あい');
    expect(result.lines.single.segments, isEmpty);
  });

  test('识别器送的是 OCR 设置里给 Lens 选的语言', () async {
    final _FakeLensRunner runner = _FakeLensRunner(_twoRowParagraph());
    final SystemOcrPageResult result = await GoogleLensScreenOcr(
      runner: runner,
      lensLanguage: 'zh',
    ).recognize(Uint8List.fromList(<int>[1]), language: 'ja');
    expect(runner.languages, <String>['zh']);
    expect(result.lines.single.text, '吾輩は猫である');
  });
}

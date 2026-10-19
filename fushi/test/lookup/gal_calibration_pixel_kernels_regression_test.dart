// galgame 查词校准的像素扫描（截图拟合网格 + OCR 墨迹几何）搬进原生内核后的回归：
// 每个用例在合成截图上跑公开入口，结果（网格参数 / 拒绝原因 / 逐字墨迹框）序列化后
// 取 SHA-256，与下面钉住的摘要比对。摘要由改用原生实现**之前**的纯 Dart 实现生成
// （2026-10-18）；截图全是 PNG（无损），解码器换了也必须逐位相同。
//
// 只覆盖 Windows 端消费的校准链路（根 CLAUDE.md「Galgame Hook 硬规则」）：这里不涉及
// 任何引擎 Hook，测试输入是合成笔画，不含游戏素材。
//
// 生成：`FUSHI_PRINT_VECTORS=1 flutter test <本文件>`，把打印的表换进 [_vectors]。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_capture.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_draft.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_image_fit.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/ocr/gal_lookup_calibration_ocr.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:image/image.dart' as img;

class _Rng {
  _Rng(int seed) : _state = seed & 0xffffffff;
  int _state;
  int next() {
    _state = (_state * 1664525 + 1013904223) & 0xffffffff;
    return _state >>> 8;
  }

  int below(int n) => next() % n;
}

/// 背景：0 纯色、1 渐变、2 噪点「美术」、3 竖条纹理。
void _paintBackground(img.Image image, int kind, img.ColorRgb8 base, _Rng rng) {
  for (int y = 0; y < image.height; y++) {
    for (int x = 0; x < image.width; x++) {
      int r = base.r.toInt(), g = base.g.toInt(), b = base.b.toInt();
      switch (kind) {
        case 1:
          final int d = (x * 40 ~/ image.width) - 20;
          r += d;
          g += d ~/ 2;
          b -= d;
        case 2:
          final int n = rng.below(41) - 20;
          r += n;
          g += rng.below(41) - 20;
          b += n ~/ 2;
        case 3:
          if (x % 9 < 2) {
            r += 25;
            g += 25;
            b += 25;
          }
      }
      image.setPixelRgb(
        x,
        y,
        r.clamp(0, 255),
        g.clamp(0, 255),
        b.clamp(0, 255),
      );
    }
  }
}

const String _gridText = '「春夏秋冬山川海空花鳥風月日光森林大地雨雪水火石土星夜朝夕音夢ー」';

GalCalibrationSample _gridSample({
  int width = 600,
  int height = 300,
  int pitch = 24,
  int lineAdvance = 31,
  int columns = 20,
  int indent = 1,
  int originX = 42,
  int originY = 110,
  int background = 0,
  img.ColorRgb8? backgroundColor,
  img.ColorRgb8? inkColor,
  bool validation = false,
  bool wrongSecondRow = false,
  bool explicitBreak = false,
  String text = _gridText,
  int seed = 1,
}) {
  final _Rng rng = _Rng(seed);
  final img.Image image = img.Image(width: width, height: height);
  _paintBackground(
    image,
    background,
    backgroundColor ?? img.ColorRgb8(30, 40, 60),
    rng,
  );
  final img.ColorRgb8 ink = inkColor ?? img.ColorRgb8(245, 245, 245);
  final double s = pitch / 24;
  for (int i = 0; i < text.length; i++) {
    final int row = i < columns ? 0 : 1 + (i - columns) ~/ (columns - indent);
    final int col = row == 0 ? i : (i - columns) % (columns - indent) + indent;
    final int x = originX + col * pitch;
    final int y =
        originY + row * lineAdvance + (row == 1 && wrongSecondRow ? 11 : 0);
    if (i == 0) {
      img.fillRect(
        image,
        x1: x + (15 * s).round(),
        y1: y,
        x2: x + (18 * s).round(),
        y2: y + (14 * s).round(),
        color: ink,
      );
      img.fillRect(
        image,
        x1: x + (9 * s).round(),
        y1: y,
        x2: x + (18 * s).round(),
        y2: y + 2,
        color: ink,
      );
    } else {
      img.drawRect(
        image,
        x1: x + (3 * s).round(),
        y1: y,
        x2: x + (20 * s).round(),
        y2: y + (19 * s).round(),
        color: ink,
        thickness: 2,
      );
      img.drawLine(
        image,
        x1: x + (4 * s).round(),
        y1: y + (10 * s).round() + i % 3 - 1,
        x2: x + (19 * s).round(),
        y2: y + (10 * s).round() + i % 3 - 1,
        color: ink,
        thickness: 2,
      );
    }
  }
  return GalCalibrationSample(
    validation: validation,
    capture: GalLookupCalibrationCapture(
      sourceText: explicitBreak
          ? '${text.substring(0, columns)}\n${text.substring(columns)}'
          : text,
      pngBytes: Uint8List.fromList(img.encodePng(image)),
      referenceClient: GalLookupReferenceClientV1(
        widthPx: width,
        heightPx: height,
        dpi: 96,
      ),
      exePath: r'C:\synthetic\grid.exe',
      exeSha256: 'a' * 64,
      sessionEpoch: 1,
      occurrenceId: 'synthetic-$seed',
      targetHwnd: 1,
      capturedAt: DateTime.utc(2026),
      selectedThreadKey: 'synthetic',
    ),
  );
}

GalLookupCalibrationDraft _gridDraft(
  List<GalCalibrationSample> samples, {
  GalLookupNormalizedRectV1 search = const GalLookupNormalizedRectV1(
    left: 0.03,
    top: 0.3,
    width: 0.94,
    height: 0.35,
  ),
}) => GalLookupCalibrationDraft(
  rect: search,
  layout: const GalLookupTextLayoutV1(fontSizePerClientHeight: 0.2),
  samples: samples,
);

/// 生成模式下顺带记一行可读摘要（看用例有没有真的拟合出网格）。
final List<String> _summaries = <String>[];

String _fitDigest(GalCalibrationImageFit fit) {
  _summaries.add(
    'fit reason=${fit.reason} sample=${fit.sampleIndex} '
    'columns=${fit.draft?.layout.cellGrid?.columns}',
  );
  return _fitDigestOf(fit);
}

String _fitDigestOf(GalCalibrationImageFit fit) => sha256
    .convert(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'reason': fit.reason,
          'sample': fit.sampleIndex,
          'detail': fit.detail,
          'draft': fit.draft?.toJson(),
        }),
      ),
    )
    .toString();

// ---- OCR 墨迹几何 ----

const String _inkText = '日月山川田目口中木本大小';
const String _inkPunctText = '日月山川田目口中木本。大小';

GalCalibrationOcrAlignment _inkAlignment(
  String text, {
  double pitchGuess = 21.7,
  double left = 33,
  double top = 9,
  double bottom = 41,
  double confidence = .99,
  int lowConfidenceEvery = 0,
}) => GalCalibrationOcrAlignment(
  confidence: .99,
  lines: <GalCalibrationOcrMatchedLine>[
    GalCalibrationOcrMatchedLine(
      sourceStart: 0,
      sourceEnd: text.length,
      cellCount: text.length,
      lineIndex: 0,
      rect: OcrRect(
        left: 22,
        top: top,
        right: 22 + text.length * 22 + 20,
        bottom: bottom,
      ),
      glyphs: <GalCalibrationOcrGlyph>[
        for (int i = 0; i < text.length; i++)
          GalCalibrationOcrGlyph(
            sourceIndex: i,
            charLength: 1,
            cellOffset: i,
            lineIndex: 0,
            confidence: lowConfidenceEvery > 0 && i % lowConfidenceEvery == 0
                ? .6
                : confidence,
            rect: OcrRect(
              left: left + i * pitchGuess,
              top: top,
              right: left + 2 + i * pitchGuess,
              bottom: bottom,
            ),
          ),
      ],
    ),
  ],
);

Uint8List _inkStrokes(
  String text, {
  int pitch = 22,
  int origin = 24,
  bool dark = false,
  int background = 0,
  int seed = 1,
  int skip = -1,
  bool tiles = false,
  int extraWidth = 0,
}) {
  final _Rng rng = _Rng(seed);
  final img.Image image = img.Image(
    width: origin + text.length * pitch + 40 + extraWidth,
    height: 55,
  );
  _paintBackground(
    image,
    background,
    dark ? img.ColorRgb8(220, 225, 230) : img.ColorRgb8(38, 53, 70),
    rng,
  );
  final img.Color ink = dark
      ? img.ColorRgb8(20, 30, 40)
      : img.ColorRgb8(241, 235, 209);
  for (int i = 0; i < text.length; i++) {
    final int left = origin + i * pitch;
    if (i == skip) {
      img.fillRect(
        image,
        x1: left + 2,
        y1: 30,
        x2: left + 5,
        y2: 34,
        color: ink,
      );
      continue;
    }
    img.fillRect(image, x1: left, y1: 14, x2: left + 2, y2: 35, color: ink);
    if (!tiles) {
      img.fillRect(
        image,
        x1: left + 11,
        y1: 14,
        x2: left + 13,
        y2: 35,
        color: ink,
      );
    }
    img.fillRect(
      image,
      x1: left,
      y1: 17 + (tiles ? 0 : i % 3 * 5),
      x2: left + 13,
      y2: 19 + (tiles ? 0 : i % 3 * 5),
      color: ink,
    );
  }
  return Uint8List.fromList(img.encodePng(image));
}

String _alignmentDigest(GalCalibrationOcrAlignment a) {
  _summaries.add(
    'ink reason=${a.reason} measured='
    '${a.lines.expand((GalCalibrationOcrMatchedLine l) => l.glyphs).where((GalCalibrationOcrGlyph g) => g.inkMeasured).length}',
  );
  List<double> r(OcrRect x) => <double>[x.left, x.top, x.right, x.bottom];
  return sha256
      .convert(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'reason': a.reason,
            'confidence': a.confidence,
            'lines': <Object?>[
              for (final GalCalibrationOcrMatchedLine l in a.lines)
                <String, Object?>{
                  'start': l.sourceStart,
                  'end': l.sourceEnd,
                  'rect': r(l.rect),
                  'glyphs': <Object?>[
                    for (final GalCalibrationOcrGlyph g in l.glyphs)
                      <Object?>[g.sourceIndex, g.inkMeasured, ...r(g.rect)],
                  ],
                },
            ],
          }),
        ),
      )
      .toString();
}

Map<String, String Function()> _cases() {
  final Map<String, String Function()> cases = <String, String Function()>{};
  final Map<String, List<GalCalibrationSample> Function()> grids =
      <String, List<GalCalibrationSample> Function()>{
        'plain': () => <GalCalibrationSample>[_gridSample()],
        'indent0': () => <GalCalibrationSample>[_gridSample(indent: 0)],
        'indent4': () => <GalCalibrationSample>[_gridSample(indent: 4)],
        'dark-on-light': () => <GalCalibrationSample>[
          _gridSample(
            backgroundColor: img.ColorRgb8(238, 238, 238),
            inkColor: img.ColorRgb8(24, 24, 24),
          ),
        ],
        'colored': () => <GalCalibrationSample>[
          _gridSample(
            backgroundColor: img.ColorRgb8(76, 108, 132),
            inkColor: img.ColorRgb8(184, 84, 156),
          ),
        ],
        'low-contrast': () => <GalCalibrationSample>[
          _gridSample(
            backgroundColor: img.ColorRgb8(120, 120, 120),
            inkColor: img.ColorRgb8(135, 135, 135),
          ),
        ],
        'gradient': () => <GalCalibrationSample>[_gridSample(background: 1)],
        'noisy-art': () => <GalCalibrationSample>[
          _gridSample(background: 2, seed: 7),
        ],
        'noisy-colored': () => <GalCalibrationSample>[
          _gridSample(
            background: 2,
            seed: 8,
            backgroundColor: img.ColorRgb8(90, 110, 140),
            inkColor: img.ColorRgb8(200, 120, 60),
          ),
        ],
        'stripes': () => <GalCalibrationSample>[_gridSample(background: 3)],
        // 宽于 1600：先缩放再扫。
        'wide-2400': () => <GalCalibrationSample>[
          _gridSample(
            width: 2400,
            height: 1200,
            pitch: 96,
            lineAdvance: 124,
            originX: 168,
            originY: 440,
          ),
        ],
        'wide-1999-noisy': () => <GalCalibrationSample>[
          _gridSample(
            width: 1999,
            height: 1001,
            pitch: 80,
            lineAdvance: 103,
            originX: 140,
            originY: 367,
            background: 2,
            seed: 9,
          ),
        ],
        'with-validation': () => <GalCalibrationSample>[
          _gridSample(),
          _gridSample(validation: true, seed: 2, background: 1),
        ],
        'validation-wrong-row': () => <GalCalibrationSample>[
          _gridSample(),
          _gridSample(validation: true, wrongSecondRow: true),
        ],
        'explicit-break': () => <GalCalibrationSample>[
          _gridSample(explicitBreak: true),
        ],
        'two-training': () => <GalCalibrationSample>[
          _gridSample(),
          _gridSample(text: '春夏秋冬山川海空花鳥風月日光森林大地雨雪水火石土星夜朝夕音夢', seed: 3),
        ],
        'three-rows': () => <GalCalibrationSample>[
          _gridSample(text: '$_gridText山川海空花鳥風月日光森林大地雨雪水火'),
        ],
        'pitch-30': () => <GalCalibrationSample>[
          _gridSample(pitch: 30, lineAdvance: 38, columns: 17, originX: 30),
        ],
        'blank': () => <GalCalibrationSample>[
          _gridSample(text: '春夏秋冬', columns: 20),
        ],
      };
  for (final MapEntry<String, List<GalCalibrationSample> Function()> e
      in grids.entries) {
    cases['grid/${e.key}'] = () =>
        _fitDigest(inferGalCalibrationGrid(_gridDraft(e.value())));
  }
  cases['grid/tight-search'] = () => _fitDigest(
    inferGalCalibrationGrid(
      _gridDraft(
        <GalCalibrationSample>[_gridSample(background: 2, seed: 4)],
        search: const GalLookupNormalizedRectV1(
          left: 0.06,
          top: 0.35,
          width: 0.82,
          height: 0.25,
        ),
      ),
    ),
  );

  final Map<
    String,
    ({Uint8List png, String text, GalCalibrationOcrAlignment a})
  >
  inks = <String, ({Uint8List png, String text, GalCalibrationOcrAlignment a})>{
    'plain': (
      png: _inkStrokes(_inkText),
      text: _inkText,
      a: _inkAlignment(_inkText),
    ),
    'dark': (
      png: _inkStrokes(_inkText, dark: true),
      text: _inkText,
      a: _inkAlignment(_inkText),
    ),
    'noisy': (
      png: _inkStrokes(_inkText, background: 2, seed: 5),
      text: _inkText,
      a: _inkAlignment(_inkText, pitchGuess: 22.3, left: 30),
    ),
    'gradient-relaxed': (
      png: _inkStrokes(_inkText, background: 1),
      text: _inkText,
      a: _inkAlignment(_inkText, lowConfidenceEvery: 2),
    ),
    'stripes': (
      png: _inkStrokes(_inkText, background: 3),
      text: _inkText,
      a: _inkAlignment(_inkText),
    ),
    'tiles': (
      png: _inkStrokes(_inkText, tiles: true),
      text: _inkText,
      a: _inkAlignment(_inkText),
    ),
    'punct': (
      png: _inkStrokes(_inkPunctText, skip: 10),
      text: _inkPunctText,
      a: _inkAlignment(_inkPunctText),
    ),
    'pitch-26': (
      png: _inkStrokes(_inkText, pitch: 26, extraWidth: 30),
      text: _inkText,
      a: _inkAlignment(_inkText, pitchGuess: 25.6, left: 35),
    ),
  };
  for (final MapEntry<
        String,
        ({Uint8List png, String text, GalCalibrationOcrAlignment a})
      >
      e
      in inks.entries) {
    for (final (String tag, GalLookupNormalizedRectV1 search)
        in <(String, GalLookupNormalizedRectV1)>[
          (
            'full',
            const GalLookupNormalizedRectV1(
              left: 0,
              top: 0,
              width: 1,
              height: 1,
            ),
          ),
          (
            'crop',
            const GalLookupNormalizedRectV1(
              left: 0.05,
              top: 0.1,
              width: 0.8,
              height: 0.8,
            ),
          ),
        ]) {
      cases['ink/${e.key}/$tag'] = () => _alignmentDigest(
        refineGalCalibrationOcrGeometry((
          pngBytes: e.value.png,
          text: e.value.text,
          searchRect: search,
          alignment: e.value.a,
        )),
      );
    }
  }
  cases['ink/garbage'] = () => _alignmentDigest(
    refineGalCalibrationOcrGeometry((
      pngBytes: Uint8List.fromList(<int>[1, 2, 3]),
      text: _inkText,
      searchRect: const GalLookupNormalizedRectV1(
        left: 0,
        top: 0,
        width: 1,
        height: 1,
      ),
      alignment: _inkAlignment(_inkText),
    )),
  );
  return cases;
}

const Map<String, String> _vectors = <String, String>{
  'grid/plain':
      'c8a6bf302fd57075f869959c6a2356e433eb08c770d6b96fa71cc6e0a9cd4ef3',
  'grid/indent0':
      '5eb695fd2b520bf2c4befc0960849d2ae42ba5ae5773f7edd61bf220250bd37f',
  'grid/indent4':
      'cadb74967c9352473732176dd680adab9f24d7f74413d2bcd2412720201c4b75',
  'grid/dark-on-light':
      '450809a01718923a37710c7e4a0c1d9e0e977668b851d7d297c200dac2df66ad',
  'grid/colored':
      'f076a52362cab33376bd7ff9e45d9b4cfb71cc11891ea95de6537ce6eb13a38b',
  'grid/low-contrast':
      'c00939524e05b53476cf79a23ad9846ca6596eeb6774d26c0d6c96c09c361fe8',
  'grid/gradient':
      'd7eb5eac0ca33455f07ff709f16d2eb5fdfaeea07f3259eb95d6e6458dffd3e8',
  'grid/noisy-art':
      'b1d9c5c1751c0df6a23170e2cfc569768a7a1c163b2817a26272137b761da765',
  'grid/noisy-colored':
      '3039f111ef4f98ec3a3f3b306505573b1b1e734c196edf5a165f7d14daec5204',
  'grid/stripes':
      '136ef41e99478110f5966146d8ffbf3514ece6114d5444aca6fd011905ddaf47',
  'grid/wide-2400':
      '21a628bbd96ec101da9709d18823e3264141a8e0d2da724a536ea718be0b759a',
  'grid/wide-1999-noisy':
      '3039f111ef4f98ec3a3f3b306505573b1b1e734c196edf5a165f7d14daec5204',
  'grid/with-validation':
      'f66659f7fa9ea9e5396b2570274d1e6e74b5b1de510fb9e67cfa5198cf76c30f',
  'grid/validation-wrong-row':
      'ada1d7d7650ddd14f20038711b832e5e6f08a412b520dead443105a0da8a68c6',
  'grid/explicit-break':
      'a6d58ee6d031c8c6a3feea226ed2b00762e6be4cad4574282effe67d5c7f39d5',
  'grid/two-training':
      '8fca75aa2ad155b4d7ea85d79722ff717481fba85cb2e640188a8186ca084363',
  'grid/three-rows':
      '3fd1e5d8d8f63b9449fb3310e68e4e618e24f9edef5cfb2ea66c85a0776503d4',
  'grid/pitch-30':
      'ce79b44feb0c6d068078b39c6aca52e3cdd078376342d0f8a4f9f18e23ee7564',
  'grid/blank':
      '3039f111ef4f98ec3a3f3b306505573b1b1e734c196edf5a165f7d14daec5204',
  'grid/tight-search':
      '46354038e24488698e04647e9623ee202cf78e340eee9637cd10d371584ee78c',
  'ink/plain/full':
      '3946d4a9456b11d761801c2fc73a8c1318bc29814f18bc828bfe3dc52c749cd2',
  'ink/plain/crop':
      '3a3ea2a25ba7bc6e0e09ace4ee7a3a137acc1add509fb9cb9853856ec9948654',
  'ink/dark/full':
      '3946d4a9456b11d761801c2fc73a8c1318bc29814f18bc828bfe3dc52c749cd2',
  'ink/dark/crop':
      '3a3ea2a25ba7bc6e0e09ace4ee7a3a137acc1add509fb9cb9853856ec9948654',
  'ink/noisy/full':
      '3946d4a9456b11d761801c2fc73a8c1318bc29814f18bc828bfe3dc52c749cd2',
  'ink/noisy/crop':
      'd87b085c016d0f7d3bbd26524c1117dd83d3744cc5a3c0630d2bdea8db7fee74',
  'ink/gradient-relaxed/full':
      'b9310f3214370c9530e72ed4d40008024d3476807c44b4bf3f0859fd46aa4568',
  'ink/gradient-relaxed/crop':
      '44aaa6f9fa7afddd3497385c54f5a4daaa6d543a9f875f597d506ce984068d99',
  'ink/stripes/full':
      '3946d4a9456b11d761801c2fc73a8c1318bc29814f18bc828bfe3dc52c749cd2',
  'ink/stripes/crop':
      '3a3ea2a25ba7bc6e0e09ace4ee7a3a137acc1add509fb9cb9853856ec9948654',
  'ink/tiles/full':
      '395a2e31b308ba9c6f16507d8101c433b2aeefd845f1871e30033c62b7f2ce0c',
  'ink/tiles/crop':
      '395a2e31b308ba9c6f16507d8101c433b2aeefd845f1871e30033c62b7f2ce0c',
  'ink/punct/full':
      '374ae16bd1d67d689f198cfe27e70a1fc154c291c5e7a7bfa44e214f13f24018',
  'ink/punct/crop':
      '374ae16bd1d67d689f198cfe27e70a1fc154c291c5e7a7bfa44e214f13f24018',
  'ink/pitch-26/full':
      '84f1572f46b7a9ff0ba394f5e71e2284c74643c855630f00b9c1a705b4c743e4',
  'ink/pitch-26/crop':
      '84f1572f46b7a9ff0ba394f5e71e2284c74643c855630f00b9c1a705b4c743e4',
  'ink/garbage':
      'eac35694e8b2899998eeb7acca663c18fe657b73a4c1524d7b1a4d29b59aea4c',
};

void main() {
  final Map<String, String Function()> cases = _cases();
  if (Platform.environment['FUSHI_PRINT_VECTORS'] == '1') {
    test('print vectors', () {
      final StringBuffer out = StringBuffer();
      for (final MapEntry<String, String Function()> e in cases.entries) {
        final String digest = e.value();
        out.writeln("  '${e.key}': '$digest', // ${_summaries.last}");
      }
      File(
        Platform.environment['FUSHI_VECTORS_OUT']!,
      ).writeAsStringSync('$out');
    });
    return;
  }
  test('every case has a pinned vector and vice versa', () {
    expect(cases.keys.toSet(), _vectors.keys.toSet());
  });
  for (final MapEntry<String, String Function()> e in cases.entries) {
    test(e.key, () => expect(e.value(), _vectors[e.key]));
  }
}

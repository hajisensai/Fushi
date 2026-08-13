/// 漫画整卷本地 OCR 的**端到端真机测试**：在真设备上跑完
/// 「渲染页图 → 检测气泡 → 逐框识别 → 落 manga.json」全链路，并断言认出的
/// 日文与已知 ground truth 一致。
///
/// 与 `manga_ocr_apple_native_itest.dart` 的分工：那条只证明 ORT native 装上了
/// （最小 Add 模型，毫秒级）；这条证明**真模型 + 真流水线**在这台设备上真能把
/// 日文读出来，并给出逐页耗时——iOS 端要不要开整卷本地 OCR，靠的就是这个数。
///
/// 页图**在设备上现渲**（Flutter 自带文字排版 + 系统日文字体），不依赖 asset、
/// 不依赖 fixture、不依赖把文件推进沙盒，所以同一份测试五端可跑。
///
/// 模型（约 472MB）解析顺序：
///   1. `--dart-define=OCR_MODEL_SEED=<dir>`：从宿主目录拷进模型目录（桌面调试
///      用，省去每次重下）。
///   2. 已在模型目录里就直接用。
///   3. 都没有 -> 走 app 自己的下载器真下一遍（顺带验证下载路径）。
///
/// 跑法：
///   flutter test integration_test/manga_ocr_volume_e2e_itest.dart -d macos \
///     --dart-define=OCR_MODEL_SEED=/path/to/models
///   flutter test integration_test/manga_ocr_volume_e2e_itest.dart -d <iPhone>
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/ocr/manga_ocr_model_manifest.dart';
import 'package:fushi/src/ocr/manga_ocr_service.dart';
import 'package:fushi/src/ocr/manga_ocr_service_impl.dart';

/// 合成页上的气泡：位置、尺寸与竖排文本（= ground truth）。
class _Bubble {
  const _Bubble(this.cx, this.cy, this.rx, this.ry, this.text);
  final double cx;
  final double cy;
  final double rx;
  final double ry;
  final String text;
}

const List<_Bubble> _kBubbles = <_Bubble>[
  _Bubble(300, 300, 190, 260, 'おはよう'),
  _Bubble(880, 620, 210, 320, 'げんきですか'),
  _Bubble(330, 1140, 200, 300, 'ありがとう'),
  _Bubble(860, 1440, 175, 230, 'またあした'),
];

const int _kPageWidth = 1200;
const int _kPageHeight = 1700;

/// 在设备上现渲一页合成漫画（白底气泡 + 竖排日文 + 分格线）。
Future<Uint8List> _renderPage() async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  final Rect pageRect =
      Rect.fromLTWH(0, 0, _kPageWidth.toDouble(), _kPageHeight.toDouble());

  // 页面底色刻意不是纯白（更像扫描页，也让气泡边界对检测器可见）。
  canvas.drawRect(pageRect, Paint()..color = const Color(0xFFE0E0DE));

  final Paint stroke = Paint()
    ..color = const Color(0xFF000000)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 6;
  canvas.drawRect(
      Rect.fromLTWH(40, 40, _kPageWidth - 80.0, _kPageHeight - 80.0), stroke);
  canvas.drawLine(
      const Offset(40, 850), Offset(_kPageWidth - 40.0, 850), stroke);

  final Paint bubbleFill = Paint()..color = const Color(0xFFFFFFFF);
  final Paint bubbleStroke = Paint()
    ..color = const Color(0xFF000000)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 5;

  for (final _Bubble b in _kBubbles) {
    final Rect oval = Rect.fromCenter(
        center: Offset(b.cx, b.cy), width: b.rx * 2, height: b.ry * 2);
    canvas.drawOval(oval, bubbleFill);
    canvas.drawOval(oval, bubbleStroke);

    // 竖排：逐字往下摆，不依赖平台的竖排排版能力。
    const double step = 78;
    final List<String> chars = b.text.split('');
    double y = b.cy - step * chars.length / 2;
    for (final String ch in chars) {
      final ui.ParagraphBuilder pb = ui.ParagraphBuilder(ui.ParagraphStyle(
        fontSize: 74,
        textAlign: TextAlign.center,
        // 不钉字体族：Apple 上系统回退到 Hiragino，Android 回退到 Noto CJK。
      ))
        ..pushStyle(ui.TextStyle(
          color: const Color(0xFF000000),
          fontSize: 74,
          fontWeight: FontWeight.w600,
        ))
        ..addText(ch);
      final ui.Paragraph paragraph = pb.build()
        ..layout(const ui.ParagraphConstraints(width: 120));
      canvas.drawParagraph(paragraph, Offset(b.cx - 60, y));
      y += step;
    }
  }

  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(_kPageWidth, _kPageHeight);
  final ByteData? png = await image.toByteData(format: ui.ImageByteFormat.png);
  picture.dispose();
  image.dispose();
  return png!.buffer.asUint8List();
}

/// 假名/汉字之外的字符全部剔掉，用于宽松比对（识别结果常带标点或空白）。
String _stripNoise(String s) =>
    s.replaceAll(RegExp(r'[\s、。，．！？!?「」『』（）()・…ー~〜]'), '');

/// [a] 与 [b] 的字符级重合率（0..1），用于报告识别质量而不是硬钉逐字相等。
double _charOverlap(String a, String b) {
  if (a.isEmpty) return 0;
  final List<String> remaining = b.split('');
  int hit = 0;
  for (final String ch in a.split('')) {
    final int idx = remaining.indexOf(ch);
    if (idx >= 0) {
      hit++;
      remaining.removeAt(idx);
    }
  }
  return hit / a.length;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory workDir;
  late Directory pagesDir;

  setUpAll(() async {
    workDir = await Directory.systemTemp.createTemp('fushi_manga_e2e_');
    pagesDir = Directory(p.join(workDir.path, 'vol1'))..createSync();
    final Uint8List png = await _renderPage();
    File(p.join(pagesDir.path, '001.png')).writeAsBytesSync(png);
  });

  tearDownAll(() async {
    if (workDir.existsSync()) {
      await workDir.delete(recursive: true);
    }
  });

  test('整卷本地 OCR 端到端：真模型认出页面上的四句日文', () async {
    // `--dart-define=OCR_MODEL_BASE_URL=http://<host>:<port>/` 把清单里的
    // HuggingFace 直链换成局域网镜像。存在的理由很实在：真机（尤其是没配代理的
    // 手机）常常根本连不上 huggingface.co，而我们要测的是**下载器 + 流水线**，
    // 不是 HF 的可达性。文件名与字节数仍走真实清单，所以长度校验照旧生效。
    const String baseUrl = String.fromEnvironment('OCR_MODEL_BASE_URL');
    final List<MangaOcrModelFile>? manifest = baseUrl.isEmpty
        ? null
        : <MangaOcrModelFile>[
            for (final MangaOcrModelFile m in kMangaOcrModelManifest)
              MangaOcrModelFile(
                fileName: m.fileName,
                url: baseUrl.endsWith('/')
                    ? '$baseUrl${m.fileName}'
                    : '$baseUrl/${m.fileName}',
                expectedBytes: m.expectedBytes,
                role: m.role,
              ),
          ];
    final MangaOcrServiceImpl service = MangaOcrServiceImpl(manifest: manifest);

    expect(service.isSupportedPlatform, isTrue,
        reason: '${Platform.operatingSystem} 上整卷本地 OCR 闸门应为真');

    // ---- 模型就位 -------------------------------------------------------
    final Directory modelsDir =
        await MangaOcrServiceImpl.defaultMangaOcrModelsDir();
    const String seed = String.fromEnvironment('OCR_MODEL_SEED');
    if (seed.isNotEmpty && Directory(seed).existsSync()) {
      modelsDir.createSync(recursive: true);
      for (final MangaOcrModelFile m in kMangaOcrModelManifest) {
        final File src = File(p.join(seed, m.fileName));
        final File dst = File(p.join(modelsDir.path, m.fileName));
        if (src.existsSync() && !isMangaOcrModelFileReady(dst)) {
          src.copySync(dst.path);
        }
      }
    }

    MangaOcrModelStatus status = await service.modelStatus();
    if (!status.allReady) {
      // ignore: avoid_print
      print('[e2e] 模型未就绪，开始下载 '
          '${(status.totalBytes / 1024 / 1024).toStringAsFixed(0)}MB ...');
      final Stopwatch dl = Stopwatch()..start();
      await for (final MangaOcrDownloadEvent _ in service.downloadModels()) {
        // 进度事件仅消费，不打印（逐字节事件会淹没日志）。
      }
      dl.stop();
      // ignore: avoid_print
      print('[e2e] 模型下载完成，用时 ${dl.elapsed.inSeconds}s');
      status = await service.modelStatus();
    }
    expect(status.allReady, isTrue, reason: '模型未能就绪，无法继续端到端');

    // ---- 真跑整卷 -------------------------------------------------------
    final Stopwatch sw = Stopwatch()..start();
    MangaOcrVolumeEvent? finished;
    MangaOcrAcceleration? acceleration;
    await for (final MangaOcrVolumeEvent e
        in service.ocrFolder(imageDirPath: pagesDir.path, volumeTitle: 'e2e')) {
      acceleration = e.acceleration ?? acceleration;
      if (e.finished) finished = e;
    }
    sw.stop();

    expect(finished, isNotNull, reason: 'ocrFolder 未产出 finished 事件');
    expect(finished!.pagesTotal, 1);

    // ignore: avoid_print
    print('[e2e] ${Platform.operatingSystem}: 1 页耗时 '
        '${sw.elapsedMilliseconds}ms，加速状态 = $acceleration');

    // ---- 断言产物 -------------------------------------------------------
    final File mangaJson = File(finished.mangaJsonPath!);
    expect(mangaJson.existsSync(), isTrue);
    final Map<String, Object?> json =
        jsonDecode(mangaJson.readAsStringSync()) as Map<String, Object?>;
    final List<Object?> pages = json['pages']! as List<Object?>;
    expect(pages, hasLength(1));
    final Map<String, Object?> page = pages.single as Map<String, Object?>;
    expect(page['width'], _kPageWidth);
    expect(page['height'], _kPageHeight);

    final List<Object?> blocks = page['blocks']! as List<Object?>;
    // ignore: avoid_print
    print('[e2e] 检出 ${blocks.length} 块，ground truth ${_kBubbles.length} 块');

    final List<String> recognised = <String>[
      for (final Object? b in blocks)
        _stripNoise(
          ((b! as Map<String, Object?>)['lines']! as List<Object?>)
              .cast<String>()
              .join(),
        ),
    ];
    // ignore: avoid_print
    print('[e2e] 识别结果: $recognised');

    // 每个 ground truth 气泡都要能在识别结果里找到一个高重合的块。
    final List<double> scores = <double>[];
    for (final _Bubble b in _kBubbles) {
      final String truth = _stripNoise(b.text);
      double best = 0;
      for (final String got in recognised) {
        final double s = _charOverlap(truth, got);
        if (s > best) best = s;
      }
      scores.add(best);
      // ignore: avoid_print
      print('[e2e]   "${b.text}" -> 最佳重合 ${(best * 100).toStringAsFixed(0)}%');
    }

    // 竖排合成页上 manga-ocr 应当基本逐字命中；阈值留出一个字的余量，
    // 既能抓住「模型没跑/跑错」这种真回归，又不会因为单字混淆变 flaky。
    for (int i = 0; i < _kBubbles.length; i++) {
      expect(scores[i], greaterThanOrEqualTo(0.75),
          reason: '气泡 "${_kBubbles[i].text}" 识别重合率过低（${scores[i]}）：'
              '检出块 = $recognised');
    }

    // 竖排标记必须落进 manga.json（阅读器覆盖层按它决定排版方向）。
    final int verticalCount = blocks
        .where((Object? b) => (b! as Map<String, Object?>)['vertical'] == true)
        .length;
    expect(verticalCount, greaterThan(0),
        reason: '全是竖排气泡，vertical 标记不应全为 false');
  }, timeout: const Timeout(Duration(minutes: 30)));
}

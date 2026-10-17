import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_model_manifest.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/ocr/manga_ocr_service_impl.dart';
import 'package:fushi_engine/ocr/ocr_host_bindings.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 字幕位图识别（[MangaOcrTextImageSession]）走真 isolate 会话：ORT 换成按模型
/// 文件名分派的 fake 会话（PP det 回一条横向概率带、CTC rec 回固定的「あい」），
/// 整条消息协议（TransferableTypedData 像素 → isolate 内整块路由识别 → 结果回发）
/// 都是生产代码。

/// 漫画检测器的文件名：`textImagesOnly` 会话里一旦有人去建它，fake 工厂直接抛，
/// 会话整体失败——「不加载检测器」由此可观测。
const String _kForbiddenDetector = 'forbidden_detector.onnx';
const String _kDetector = 'detector.onnx';
const String _kLineDet = 'pp_det.onnx';
const String _kLineRec = 'ctc_rec.onnx';

/// 词表：blank + あ + い + 空格（[buildPpOcrCtcVocab] 的形状）。
const int _kVocabSize = 4;

class _NeverRunSession implements OcrSession {
  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) async =>
      throw StateError('the manga detector must not run for text images');

  @override
  Future<void> close() async {}
}

/// PP det：输入 [1,3,H,W]，回 [1,1,H,W] 概率图，中间一条横带（行）概率 0.9。
class _BandLineDetSession implements OcrSession {
  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) async {
    final List<int> shape = inputs.values.single.shape;
    final int height = shape[2];
    final int width = shape[3];
    final Float32List prob = Float32List(width * height);
    for (int y = (height * 0.3).round(); y < (height * 0.7).round(); y++) {
      for (int x = (width * 0.1).round(); x < (width * 0.9).round(); x++) {
        prob[y * width + x] = 0.9;
      }
    }
    return <String, OcrTensor>{
      'out': OcrTensor.float32(prob, <int>[1, 1, height, width]),
    };
  }

  @override
  Future<void> close() async {}
}

/// CTC rec：四帧 あ / blank / い / blank（每帧是概率行）→「あい」。
class _FixedRecSession implements OcrSession {
  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) async {
    final Float32List probs = Float32List.fromList(<double>[
      0.05, 0.9, 0.025, 0.025, //
      0.9, 0.05, 0.025, 0.025, //
      0.05, 0.025, 0.9, 0.025, //
      0.9, 0.05, 0.025, 0.025, //
    ]);
    return <String, OcrTensor>{
      'out': OcrTensor.float32(probs, <int>[1, 4, _kVocabSize]),
    };
  }

  @override
  Future<void> close() async {}
}

class _FakeOcrSessionFactory implements OcrSessionFactory {
  @override
  Future<OcrSession> createSession(
    String modelPath, {
    required List<OcrExecutionProvider> providers,
    void Function(OcrProviderResolution resolution)? onProviderResolved,
    int? intraOpNumThreads,
    Map<String, int>? freeDimensionOverrides,
  }) async {
    switch (p.basename(modelPath)) {
      case _kForbiddenDetector:
        throw StateError('text-image session loaded the manga detector');
      case _kDetector:
        return _NeverRunSession();
      case _kLineDet:
        return _BandLineDetSession();
      case _kLineRec:
        return _FixedRecSession();
    }
    throw StateError('unexpected model $modelPath');
  }

  @override
  Future<Set<OcrExecutionProvider>> availableAcceleratedProviders() async =>
      const <OcrExecutionProvider>{};

  @override
  Future<int?> deviceMemoryBudgetBytes() async => null;
}

/// 必须是顶层函数：随 isolate 参数跨 isolate 发送。
OcrSessionFactory _fakeFactoryBuilder() => _FakeOcrSessionFactory();

/// 在后台 isolate 里直接抛，模拟 ORT 建会话失败。
OcrSessionFactory _throwingFactoryBuilder() =>
    throw StateError('no ORT in unit test');

/// 黑底白字的「文字图」像素（内容无所谓，fake det/rec 不看像素）。
Uint8List _rgba(int width, int height) {
  final Uint8List bytes = Uint8List(width * height * 4);
  for (int i = 3; i < bytes.length; i += 4) {
    bytes[i] = 255;
  }
  return bytes;
}

void main() {
  late Directory dir;
  OcrSessionFactory Function()? savedBuilder;
  OcrIsolateBootstrap? savedBootstrap;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ocr_text_image_');
    File(
      p.join(dir.path, 'inference.yml'),
    ).writeAsStringSync('character_dict:\n  - あ\n  - い\n');
    savedBuilder = ocrSessionFactoryBuilder;
    savedBootstrap = ocrIsolateBootstrap;
    ocrSessionFactoryBuilder = _fakeFactoryBuilder;
    ocrIsolateBootstrap = null;
  });

  tearDown(() {
    ocrSessionFactoryBuilder = savedBuilder;
    ocrIsolateBootstrap = savedBootstrap;
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  MangaOcrPageSessionRequest request({
    required bool textImagesOnly,
    String detector = _kForbiddenDetector,
  }) => MangaOcrPageSessionRequest(
    imageDirPath: dir.path,
    modelPaths: MangaOcrModelPaths(
      detectorPath: p.join(dir.path, detector),
      ppDetPath: p.join(dir.path, _kLineDet),
      ppRecPath: p.join(dir.path, _kLineRec),
      ppRecDictPath: p.join(dir.path, 'inference.yml'),
      ctcRecPath: p.join(dir.path, _kLineRec),
    ),
    engineSignature: 'test-signature',
    textImagesOnly: textImagesOnly,
  );

  group('生产 isolate 会话的文字图识别', () {
    test('textImagesOnly：不建检测器，整图走横排行路径读出文字与行框', () async {
      final MangaOcrPageSession session =
          const IsolateMangaOcrPageSessionRunner().open(
            request(textImagesOnly: true),
          );
      addTearDown(session.close);
      expect(session, isA<MangaOcrTextImageSession>());
      final MangaOcrTextImageSession textImages =
          session as MangaOcrTextImageSession;

      // 两张并发提交：同一串行队列按序处理，各自按编号配对回来。
      final List<OcrRecognition> results = await Future.wait(
        <Future<OcrRecognition>>[
          textImages.recognizeTextImage(_rgba(200, 40), width: 200, height: 40),
          textImages.recognizeTextImage(_rgba(300, 50), width: 300, height: 50),
        ],
      ).timeout(const Duration(seconds: 30));

      for (final OcrRecognition result in results) {
        expect(result.text, 'あい');
        expect(result.vertical, isFalse);
        expect(result.lines, <String>['あい']);
        expect(result.lineBoxes, hasLength(1));
        expect(result.confidence, closeTo(0.9, 1e-6));
      }
      final OcrRect box = results.first.lineBoxes!.single;
      expect(box.left, greaterThanOrEqualTo(0));
      expect(box.right, lessThanOrEqualTo(200));
      expect(box.bottom, lessThanOrEqualTo(40));
    });

    test('textImagesOnly 会话上的 ocrPage 以清楚的 StateError 失败，会话照常可用', () async {
      final MangaOcrPageSession session =
          const IsolateMangaOcrPageSessionRunner().open(
            request(textImagesOnly: true),
          );
      addTearDown(session.close);
      await expectLater(
        session.ocrPage('p1.png'),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('textImagesOnly'),
          ),
        ),
      );
      final OcrRecognition result = await (session as MangaOcrTextImageSession)
          .recognizeTextImage(_rgba(200, 40), width: 200, height: 40)
          .timeout(const Duration(seconds: 30));
      expect(result.text, 'あい');
    });

    test('普通页会话（带检测器）也能识别文字图', () async {
      final MangaOcrPageSession session =
          const IsolateMangaOcrPageSessionRunner().open(
            request(textImagesOnly: false, detector: _kDetector),
          );
      addTearDown(session.close);
      final OcrRecognition result = await (session as MangaOcrTextImageSession)
          .recognizeTextImage(_rgba(200, 40), width: 200, height: 40)
          .timeout(const Duration(seconds: 30));
      expect(result.text, 'あい');
    });

    test('像素长度 / 尺寸不对：调用方同步抛 ArgumentError，不进 isolate', () async {
      final MangaOcrPageSession session =
          const IsolateMangaOcrPageSessionRunner().open(
            request(textImagesOnly: true),
          );
      addTearDown(session.close);
      final MangaOcrTextImageSession textImages =
          session as MangaOcrTextImageSession;
      expect(
        () => textImages.recognizeTextImage(
          Uint8List(10),
          width: 200,
          height: 40,
        ),
        throwsArgumentError,
      );
      expect(
        () => textImages.recognizeTextImage(Uint8List(0), width: 0, height: 0),
        throwsArgumentError,
      );
      // 校验失败不毒化会话。
      final OcrRecognition ok = await textImages
          .recognizeTextImage(_rgba(200, 40), width: 200, height: 40)
          .timeout(const Duration(seconds: 30));
      expect(ok.text, 'あい');
    });

    test('textImagesOnly 不生效（建了检测器）时会话整体失败——反向锚点', () async {
      // 同一组模型路径、不开 textImagesOnly：fake 工厂被要求建检测器而抛，
      // 证明上面几条「能读出字」确实依赖于跳过检测器。
      final MangaOcrPageSession session =
          const IsolateMangaOcrPageSessionRunner().open(
            request(textImagesOnly: false),
          );
      await expectLater(
        (session as MangaOcrTextImageSession).recognizeTextImage(
          _rgba(200, 40),
          width: 200,
          height: 40,
        ),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('loaded the manga detector'),
          ),
        ),
      );
      await session.close().timeout(const Duration(seconds: 20));
    });

    test('close 让挂起的文字图请求失败，之后请求以 closed 失败', () async {
      final MangaOcrPageSession session =
          const IsolateMangaOcrPageSessionRunner().open(
            request(textImagesOnly: true),
          );
      final MangaOcrTextImageSession textImages =
          session as MangaOcrTextImageSession;
      final Future<OcrRecognition> pending = textImages.recognizeTextImage(
        _rgba(200, 40),
        width: 200,
        height: 40,
      );
      final Future<void> closing = session.close();
      await expectLater(pending, throwsA(isA<StateError>()));
      await closing.timeout(const Duration(seconds: 20));
      await expectLater(
        textImages.recognizeTextImage(_rgba(200, 40), width: 200, height: 40),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });

    test('建会话失败：挂起与后续文字图请求都以该错误失败', () async {
      ocrSessionFactoryBuilder = _throwingFactoryBuilder;
      final MangaOcrPageSession session =
          const IsolateMangaOcrPageSessionRunner().open(
            request(textImagesOnly: true),
          );
      final MangaOcrTextImageSession textImages =
          session as MangaOcrTextImageSession;
      await expectLater(
        textImages.recognizeTextImage(_rgba(200, 40), width: 200, height: 40),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('no ORT in unit test'),
          ),
        ),
      );
      await expectLater(
        textImages.recognizeTextImage(_rgba(200, 40), width: 200, height: 40),
        throwsA(isA<StateError>()),
      );
      await session.close().timeout(const Duration(seconds: 20));
    });
  });

  group('服务层透传 textImagesOnly', () {
    test('openPageSession(textImagesOnly) 原样进会话请求；默认 false', () async {
      final Directory models = Directory(p.join(dir.path, 'models'))
        ..createSync();
      for (final MangaOcrModelFile model in _tinyCtcManifest) {
        File(p.join(models.path, model.fileName)).writeAsBytesSync(<int>[7]);
      }
      final _RecordingPageSessionRunner runner = _RecordingPageSessionRunner();
      final MangaOcrServiceImpl service = MangaOcrServiceImpl(
        localModel: MangaOcrLocalModel.mangaCtc,
        modelsDirProvider: () async => models,
        manifest: _tinyCtcManifest,
        pageSessionRunner: runner,
        platformSupport: () => true,
      );
      await service.openPageSession(
        imageDirPath: dir.path,
        textImagesOnly: true,
      );
      await service.openPageSession(imageDirPath: dir.path);
      expect(
        runner.requests.map((MangaOcrPageSessionRequest r) => r.textImagesOnly),
        <bool>[true, false],
      );
    });
  });
}

/// 默认本地模型（逐列 CTC）的清单文件名，测试里缩成 1 字节的假文件。
const List<MangaOcrModelFile> _tinyCtcManifest = <MangaOcrModelFile>[
  MangaOcrModelFile(
    fileName: 'detector-v4-s_int8.onnx',
    url: 'http://unused.invalid/detector',
    expectedBytes: 1,
    role: MangaOcrModelRole.detector,
  ),
  MangaOcrModelFile(
    fileName: kMangaCtcRecFileName,
    url: 'http://unused.invalid/ctc',
    expectedBytes: 1,
    role: MangaOcrModelRole.recognizer,
  ),
  MangaOcrModelFile(
    fileName: kPpOcrDetFileName,
    url: 'http://unused.invalid/det',
    expectedBytes: 1,
    role: MangaOcrModelRole.recognizer,
  ),
  MangaOcrModelFile(
    fileName: kPpOcrRecFileName,
    url: 'http://unused.invalid/rec',
    expectedBytes: 1,
    role: MangaOcrModelRole.recognizer,
  ),
  MangaOcrModelFile(
    fileName: kPpOcrRecDictFileName,
    url: 'http://unused.invalid/dict',
    expectedBytes: 1,
    role: MangaOcrModelRole.recognizer,
  ),
];

class _NoopPageSession implements MangaOcrPageSession {
  @override
  Future<String> ocrPage(String relativeUrl) async => '';

  @override
  Future<void> close() async {}
}

class _RecordingPageSessionRunner implements MangaOcrPageSessionRunner {
  final List<MangaOcrPageSessionRequest> requests =
      <MangaOcrPageSessionRequest>[];

  @override
  MangaOcrPageSession open(
    MangaOcrPageSessionRequest request, {
    void Function(MangaOcrAcceleration acceleration)? onAcceleration,
  }) {
    requests.add(request);
    return _NoopPageSession();
  }
}

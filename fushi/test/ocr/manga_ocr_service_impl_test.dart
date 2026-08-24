import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ocr/manga_ocr_model_manifest.dart';
import 'package:fushi/src/ocr/manga_ocr_pipeline.dart';
import 'package:fushi/src/ocr/manga_ocr_service.dart';
import 'package:fushi/src/ocr/manga_ocr_service_impl.dart';
import 'package:fushi/src/ocr/ocr_inference.dart';
import 'package:fushi/src/ocr/ocr_inference_ort.dart'
    show isLocalOnnxRuntimeAvailable;
import 'package:path/path.dart' as p;

/// 与真实清单同名同形（detector + encoder/decoder/vocab），尺寸缩成几字节，
/// 让 modelStatus/_resolveModelPaths 的路径逻辑全程走真实分支。
const List<MangaOcrModelFile> _tinyManifest = <MangaOcrModelFile>[
  MangaOcrModelFile(
    fileName: 'detector-v4-s_int8.onnx',
    url: 'http://unused.invalid/detector-v4-s_int8.onnx',
    expectedBytes: 4,
    role: MangaOcrModelRole.detector,
  ),
  MangaOcrModelFile(
    fileName: 'encoder_model.onnx',
    url: 'http://unused.invalid/encoder_model.onnx',
    expectedBytes: 5,
    role: MangaOcrModelRole.recognizer,
  ),
  MangaOcrModelFile(
    fileName: 'decoder_model.onnx',
    url: 'http://unused.invalid/decoder_model.onnx',
    expectedBytes: 6,
    role: MangaOcrModelRole.recognizer,
  ),
  MangaOcrModelFile(
    fileName: 'vocab.txt',
    url: 'http://unused.invalid/vocab.txt',
    expectedBytes: 7,
    role: MangaOcrModelRole.recognizer,
  ),
];

/// 进程内可编排的 fake 任务。
class _FakeJob implements MangaOcrVolumeJob {
  final Completer<String> completer = Completer<String>();
  bool cancelled = false;

  @override
  Future<String> get result => completer.future;

  @override
  void cancel() {
    cancelled = true;
    if (!completer.isCompleted) {
      completer.completeError(const OcrCancelledException());
    }
  }
}

class _FakeRunner implements MangaOcrVolumeJobRunner {
  final List<MangaOcrVolumeJobRequest> requests = <MangaOcrVolumeJobRequest>[];
  _FakeJob? lastJob;
  void Function(int, int)? lastOnProgress;
  void Function(MangaOcrAcceleration)? lastOnAcceleration;

  @override
  MangaOcrVolumeJob start(
    MangaOcrVolumeJobRequest request, {
    required void Function(int pagesDone, int pagesTotal) onProgress,
    void Function(MangaOcrAcceleration acceleration)? onAcceleration,
  }) {
    requests.add(request);
    lastOnProgress = onProgress;
    lastOnAcceleration = onAcceleration;
    return lastJob = _FakeJob();
  }
}

void main() {
  late Directory modelsDir;

  setUp(() {
    modelsDir = Directory.systemTemp.createTempSync('manga_ocr_models_');
  });

  tearDown(() {
    if (modelsDir.existsSync()) {
      modelsDir.deleteSync(recursive: true);
    }
  });

  /// [platformSupported] 显式钉死平台闸门，让 `ocrFolder` 的编排断言在任何宿主
  /// 上都跑同一条分支，而不是跟着宿主平台漂。
  ///
  /// 真实 `isSupportedPlatform` 现在就是 ORT native 可用性（出包五端全真，
  /// 含 Android，BUG-1780），所以「平台不支持」那条分支只能靠这个参数注入才走得到。
  MangaOcrServiceImpl service(
    _FakeRunner runner, {
    bool platformSupported = true,
  }) =>
      MangaOcrServiceImpl(
        modelsDirProvider: () async => modelsDir,
        manifest: _tinyManifest,
        jobRunner: runner,
        platformSupport: () => platformSupported,
      );

  void writeAllModels() {
    for (final MangaOcrModelFile model in _tinyManifest) {
      File(p.join(modelsDir.path, model.fileName))
          .writeAsBytesSync(List<int>.filled(model.expectedBytes, 1));
    }
  }

  group('modelStatus / deleteModels', () {
    test('空目录：全不就绪，totalBytes = 清单总和', () async {
      final MangaOcrServiceImpl impl = service(_FakeRunner());
      final MangaOcrModelStatus status = await impl.modelStatus();
      expect(status.detectorReady, isFalse);
      expect(status.recognizerReady, isFalse);
      expect(status.allReady, isFalse);
      expect(status.diskBytes, 0);
      expect(status.totalBytes, 4 + 5 + 6 + 7);
    });

    test('只有检测器就绪：detectorReady 单独为真', () async {
      File(p.join(modelsDir.path, 'detector-v4-s_int8.onnx'))
          .writeAsBytesSync(<int>[1, 2, 3, 4]);
      final MangaOcrModelStatus status =
          await service(_FakeRunner()).modelStatus();
      expect(status.detectorReady, isTrue);
      expect(status.recognizerReady, isFalse);
      expect(status.diskBytes, 4);
    });

    test('obtainedBytes 把 .part 残留算进「已下多少」', () async {
      // 一个已就绪档 + 一个下到一半的 .part：用户看到的进度必须是两者之和，
      // 否则每次重进设置页那半截下载就像白下了（下载器一直有 Range 续传）。
      File(p.join(modelsDir.path, 'detector-v4-s_int8.onnx'))
          .writeAsBytesSync(<int>[1, 2, 3, 4]);
      File(p.join(modelsDir.path, 'encoder_model.onnx.part'))
          .writeAsBytesSync(<int>[1, 2, 3]);

      final MangaOcrModelStatus status =
          await service(_FakeRunner()).modelStatus();

      expect(status.obtainedBytes, 4 + 3);
      expect(status.hasResumableDownload, isTrue);
    });

    test('全新安装：obtainedBytes 为 0，不显示「继续下载」', () async {
      final MangaOcrModelStatus status =
          await service(_FakeRunner()).modelStatus();
      expect(status.obtainedBytes, 0);
      expect(status.hasResumableDownload, isFalse);
    });

    test('全部就绪后不再是「可续传」状态', () async {
      writeAllModels();
      final MangaOcrModelStatus status =
          await service(_FakeRunner()).modelStatus();
      expect(status.obtainedBytes, status.totalBytes);
      expect(status.hasResumableDownload, isFalse,
          reason: '已经下完了还提示「继续下载」只会让人以为没下完');
    });

    test('零字节文件不算就绪', () async {
      File(p.join(modelsDir.path, 'detector-v4-s_int8.onnx')).createSync();
      final MangaOcrModelStatus status =
          await service(_FakeRunner()).modelStatus();
      expect(status.detectorReady, isFalse);
    });

    test('全就绪 + deleteModels 释放磁盘', () async {
      writeAllModels();
      final MangaOcrServiceImpl impl = service(_FakeRunner());
      MangaOcrModelStatus status = await impl.modelStatus();
      expect(status.allReady, isTrue);
      expect(status.diskBytes, status.totalBytes);

      final int freed = await impl.deleteModels();
      expect(freed, status.totalBytes);
      expect(modelsDir.existsSync(), isFalse);
      status = await impl.modelStatus();
      expect(status.allReady, isFalse);
      expect(status.diskBytes, 0);
    });

    // BUG-1732：占用与释放量的真相源是磁盘，不是清单。中断留下的 `.part`、上游
    // 换档后的遗留档都不在清单里——按清单记账时它们既不显示也「删不掉」（用户
    // 只看到删了清单那点体积），于是「显示 450 MB / 磁盘上却是另一个数」。
    test('清单外的残留档一样计入占用，并计入删除释放量', () async {
      writeAllModels();
      File(p.join(modelsDir.path, 'encoder_model.onnx.part'))
          .writeAsBytesSync(List<int>.filled(1000, 1));
      File(p.join(modelsDir.path, 'legacy-detector-fp32.onnx'))
          .writeAsBytesSync(List<int>.filled(500, 1));
      final MangaOcrServiceImpl impl = service(_FakeRunner());

      final MangaOcrModelStatus status = await impl.modelStatus();
      expect(status.allReady, isTrue);
      expect(status.totalBytes, 4 + 5 + 6 + 7);
      expect(status.diskBytes, 4 + 5 + 6 + 7 + 1000 + 500);
      expect(status.hasAnyFiles, isTrue);

      expect(await impl.deleteModels(), 4 + 5 + 6 + 7 + 1000 + 500);
      expect(modelsDir.existsSync(), isFalse);
    });

    test('模型不全但残留占着磁盘：hasAnyFiles 为真，可被删除释放', () async {
      File(p.join(modelsDir.path, 'encoder_model.onnx.part'))
          .writeAsBytesSync(List<int>.filled(2048, 1));
      final MangaOcrServiceImpl impl = service(_FakeRunner());

      final MangaOcrModelStatus status = await impl.modelStatus();
      expect(status.allReady, isFalse);
      expect(status.hasAnyFiles, isTrue);
      expect(status.diskBytes, 2048);
      expect(await impl.deleteModels(), 2048);
    });

    test('目录不存在：删除返回 0 而不是抛错', () async {
      modelsDir.deleteSync(recursive: true);
      expect(await service(_FakeRunner()).deleteModels(), 0);
    });
  });

  group('ocrFolder 编排', () {
    test('模型未就绪：error 结束流，任务不启动', () async {
      final _FakeRunner runner = _FakeRunner();
      final MangaOcrServiceImpl impl = service(runner);
      await expectLater(
        impl.ocrFolder(imageDirPath: 'D:/whatever').toList(),
        throwsA(isA<StateError>()),
      );
      expect(runner.requests, isEmpty);
    });

    test('平台不支持：error 结束流，任务不启动，且不去碰模型目录', () async {
      writeAllModels(); // 模型齐全，排除「未就绪」这条先决路径干扰。
      final _FakeRunner runner = _FakeRunner();
      final MangaOcrServiceImpl impl =
          service(runner, platformSupported: false);
      expect(impl.isSupportedPlatform, isFalse);
      await expectLater(
        impl.ocrFolder(imageDirPath: 'D:/vol1').toList(),
        throwsA(isA<StateError>().having((StateError e) => e.message, 'message',
            contains('manga OCR is not supported on'))),
      );
      expect(runner.requests, isEmpty);
    });

    test('平台闸门 = ORT native 可用性本身（含 Android，出包五端全开）', () {
      expect(
        MangaOcrServiceImpl.defaultPlatformSupport(),
        isLocalOnnxRuntimeAvailable,
        reason: '整卷本地 OCR 的闸门必须**就是** ORT native 可用性；'
            '要调整平台支持面就去改 isLocalOnnxRuntimeAvailable（BUG-1780）',
      );
      expect(
        MangaOcrServiceImpl.defaultPlatformSupport(),
        isTrue,
        reason: '${Platform.operatingSystem} 是出包五端之一，ORT native 应可用',
      );
    });

    test('闸门实现里不许再长出第二份平台白名单（源码守卫，任何宿主都有效）', () {
      // 这条不能靠「按宿主算 expected」来守。旧写法是
      //   expected = isWindows || isLinux || isMacOS || isIOS
      // 它在 Windows / macOS / Linux 宿主上改前改后都是 true，**只有 Android 宿主
      // 才会红**——而单测从不在 Android 上跑。于是「Android 被漏在白名单外」这件事
      // 有守卫却测不出来，一路活到用户报障（BUG-1780）。
      //
      // 换成扫实现体：只要有人再把 `Platform.isXxx` 写回闸门里，任何宿主都当场红。
      final String source =
          File('lib/src/ocr/manga_ocr_service_impl.dart').readAsStringSync();
      final RegExpMatch? match = RegExp(
        r'static bool defaultPlatformSupport\(\)\s*=>([\s\S]*?);',
      ).firstMatch(source);
      expect(
        match,
        isNotNull,
        reason: '找不到 defaultPlatformSupport 的定义；改了签名要同步改本守卫',
      );
      final String body = match!.group(1)!;
      expect(
        body.contains('Platform.'),
        isFalse,
        reason: '闸门体里又出现了 Platform.xxx —— 第二份平台白名单回来了。\n'
            'ORT 可用性的唯一真相源是 ocr_inference_ort.dart 的 '
            'isLocalOnnxRuntimeAvailable，要改支持面就去改它。\n'
            '当前实现体：$body',
      );
    });

    test('默认构造走真实平台闸门（不被注入桩悄悄替换）', () {
      expect(
        MangaOcrServiceImpl(
          modelsDirProvider: () async => modelsDir,
          manifest: _tinyManifest,
          jobRunner: _FakeRunner(),
        ).isSupportedPlatform,
        MangaOcrServiceImpl.defaultPlatformSupport(),
      );
    });

    test('happy path：逐页事件转发 + finished 携带 manga.json 路径', () async {
      writeAllModels();
      final _FakeRunner runner = _FakeRunner();
      final MangaOcrServiceImpl impl = service(runner);

      final List<MangaOcrVolumeEvent> events = <MangaOcrVolumeEvent>[];
      final Future<void> done = impl
          .ocrFolder(imageDirPath: 'D:/vol1', volumeTitle: '第1卷')
          .forEach(events.add);
      // 等 onListen 异步链启动。
      await Future<void>.delayed(Duration.zero);
      expect(runner.requests.single.imageDirPath, 'D:/vol1');
      expect(runner.requests.single.volumeTitle, '第1卷');
      // 模型路径接线：detector/encoder/decoder/vocab 各归其位。
      final MangaOcrModelPaths paths = runner.requests.single.modelPaths;
      expect(p.basename(paths.detectorPath), 'detector-v4-s_int8.onnx');
      expect(p.basename(paths.encoderPath), 'encoder_model.onnx');
      expect(p.basename(paths.decoderPath), 'decoder_model.onnx');
      expect(p.basename(paths.vocabPath), 'vocab.txt');

      runner.lastOnProgress!(1, 2);
      runner.lastOnProgress!(2, 2);
      runner.lastJob!.completer.complete('D:/vol1/manga_ocr_out/manga.json');
      await done;

      expect(events, hasLength(3));
      expect(events[0].pagesDone, 1);
      expect(events[0].pagesTotal, 2);
      expect(events[0].finished, isFalse);
      expect(events[1].pagesDone, 2);
      expect(events[2].finished, isTrue);
      expect(events[2].pagesDone, 2);
      expect(events[2].mangaJsonPath, 'D:/vol1/manga_ocr_out/manga.json');
    });

    test('取消订阅：job.cancel 被调、流静默收尾（无 error）', () async {
      writeAllModels();
      final _FakeRunner runner = _FakeRunner();
      final MangaOcrServiceImpl impl = service(runner);

      final List<MangaOcrVolumeEvent> events = <MangaOcrVolumeEvent>[];
      Object? streamError;
      final StreamSubscription<MangaOcrVolumeEvent> sub = impl
          .ocrFolder(imageDirPath: 'D:/vol1')
          .listen(events.add, onError: (Object e) => streamError = e);
      await Future<void>.delayed(Duration.zero);
      runner.lastOnProgress!(1, 3);
      await Future<void>.delayed(Duration.zero);

      await sub.cancel();
      expect(runner.lastJob!.cancelled, isTrue, reason: '取消订阅必须传导为任务取消');
      await Future<void>.delayed(Duration.zero);
      expect(streamError, isNull, reason: '取消不是错误');
      expect(events.map((MangaOcrVolumeEvent e) => e.finished),
          isNot(contains(true)));
    });

    // BUG-1163：EP 降级不允许静默。runner 回报的加速状态必须挂到每一个
    // 进度事件和 finished 事件上，UI 才有东西可显示。
    test('加速状态随每个事件回传，降级原因不丢', () async {
      writeAllModels();
      final _FakeRunner runner = _FakeRunner();
      final MangaOcrServiceImpl impl = service(runner);

      final List<MangaOcrVolumeEvent> events = <MangaOcrVolumeEvent>[];
      final Future<void> done =
          impl.ocrFolder(imageDirPath: 'D:/vol1').forEach(events.add);
      await Future<void>.delayed(Duration.zero);
      expect(runner.lastOnAcceleration, isNotNull,
          reason: '服务必须订阅加速回调，否则降级无从观测');

      // 加速状态尚未回报前先来一页进度：该页只能是 null，不能瞎猜成 GPU。
      runner.lastOnProgress!(1, 2);
      runner.lastOnAcceleration!(const MangaOcrAcceleration(
        detection: OcrExecutionProvider.cpu,
        recognition: OcrExecutionProvider.cpu,
        degradeReasons: <String>[
          'detector: directml -> cpu (INVALID_PROVIDER)'
        ],
      ));
      runner.lastOnProgress!(2, 2);
      runner.lastJob!.completer.complete('D:/vol1/manga_ocr_out/manga.json');
      await done;

      expect(events[0].acceleration, isNull);
      final MangaOcrAcceleration? mid = events[1].acceleration;
      expect(mid, isNotNull);
      expect(mid!.degraded, isTrue);
      expect(mid.label, 'CPU');
      expect(mid.degradeReasons.single, contains('INVALID_PROVIDER'));
      expect(events.last.finished, isTrue);
      expect(events.last.acceleration?.degraded, isTrue,
          reason: 'finished 事件也要带上降级状态，收尾提示才能显示');
    });

    test('未降级时加速状态不报降级', () async {
      writeAllModels();
      final _FakeRunner runner = _FakeRunner();
      final MangaOcrServiceImpl impl = service(runner);
      final List<MangaOcrVolumeEvent> events = <MangaOcrVolumeEvent>[];
      final Future<void> done =
          impl.ocrFolder(imageDirPath: 'D:/vol1').forEach(events.add);
      await Future<void>.delayed(Duration.zero);
      runner.lastOnAcceleration!(const MangaOcrAcceleration(
        detection: OcrExecutionProvider.cuda,
        recognition: OcrExecutionProvider.cpu,
      ));
      runner.lastOnProgress!(1, 1);
      runner.lastJob!.completer.complete('D:/vol1/manga_ocr_out/manga.json');
      await done;

      expect(events.first.acceleration!.degraded, isFalse);
      expect(events.first.acceleration!.label, 'CUDA/CPU');
    });

    test('任务失败：error 事件结束流', () async {
      writeAllModels();
      final _FakeRunner runner = _FakeRunner();
      final MangaOcrServiceImpl impl = service(runner);
      final Future<List<MangaOcrVolumeEvent>> future =
          impl.ocrFolder(imageDirPath: 'D:/vol1').toList();
      await Future<void>.delayed(Duration.zero);
      runner.lastJob!.completer.completeError(StateError('boom'));
      await expectLater(future, throwsA(isA<StateError>()));
    });
  });

  group('EP 策略接线（纯函数组合）', () {
    test('resolveOcrPlatform 映射', () {
      expect(resolveOcrPlatform('windows'), OcrPlatform.windows);
      expect(resolveOcrPlatform('macos'), OcrPlatform.macos);
      expect(resolveOcrPlatform('ios'), OcrPlatform.ios);
      expect(resolveOcrPlatform('android'), OcrPlatform.android);
      expect(resolveOcrPlatform('linux'), OcrPlatform.linux);
      expect(resolveOcrPlatform('fuchsia'), OcrPlatform.linux,
          reason: '未知平台落纯 CPU 档');
    });

    test('Windows 有 CUDA：检测与识别都走 CUDA→CPU', () {
      for (final OcrModelKind kind in OcrModelKind.values) {
        expect(
          selectOcrExecutionProviders(
            kind: kind,
            platform: resolveOcrPlatform('windows'),
            cudaAvailable: true,
          ),
          <OcrExecutionProvider>[
            OcrExecutionProvider.cuda,
            OcrExecutionProvider.cpu,
          ],
        );
      }
    });

    test('Windows 无 CUDA：检测 DirectML→CPU，识别纯 CPU', () {
      expect(
        selectOcrExecutionProviders(
          kind: OcrModelKind.detection,
          platform: resolveOcrPlatform('windows'),
          cudaAvailable: false,
        ),
        <OcrExecutionProvider>[
          OcrExecutionProvider.directml,
          OcrExecutionProvider.cpu,
        ],
      );
      expect(
        selectOcrExecutionProviders(
          kind: OcrModelKind.recognition,
          platform: resolveOcrPlatform('windows'),
          cudaAvailable: false,
        ),
        <OcrExecutionProvider>[OcrExecutionProvider.cpu],
      );
    });

    test('BUG-1613 macOS / iOS：检测与识别都是纯 CPU，绝不选 CoreML', () {
      // 这条测试**改之前钉的正好是相反的结论**（Apple 检测走 CoreML）——实现和
      // 测试同源于一个从未被执行过的假设（当时 Apple 的 ORT native 整个被 gate
      // 掉，这段分支不可达）。真机对拍后才知道：iOS 上 CoreML EP 把 int8 检测
      // 模型交给 ANE 会**静默返回空结果**，而且两端都比 CPU 慢。
      for (final String os in <String>['macos', 'ios']) {
        for (final OcrModelKind kind in OcrModelKind.values) {
          final List<OcrExecutionProvider> got = selectOcrExecutionProviders(
            kind: kind,
            platform: resolveOcrPlatform(os),
            cudaAvailable: false,
          );
          expect(got, <OcrExecutionProvider>[OcrExecutionProvider.cpu],
              reason: '$os/$kind 不应再出现 CoreML（BUG-1613）');
          expect(got, isNot(contains(OcrExecutionProvider.coreml)));
        }
      }
    });

    test('Linux / Android：纯 CPU', () {
      for (final String os in <String>['linux', 'android']) {
        for (final OcrModelKind kind in OcrModelKind.values) {
          expect(
            selectOcrExecutionProviders(
              kind: kind,
              platform: resolveOcrPlatform(os),
              cudaAvailable: false,
            ),
            <OcrExecutionProvider>[OcrExecutionProvider.cpu],
          );
        }
      }
    });
  });
}

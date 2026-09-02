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

    test('BUG-2050 Windows：运行时报告 CUDA+DirectML 也照样纯 CPU', () {
      // Windows 偏好表是空的，所以「可用性」再全也选不出加速 EP。
      // DirectML 是实测排除（int8 检测器建不出会话 / 自回归解码负优化）；CUDA
      // 则是**我们出的包里根本没有**——`third_party/flutter_onnxruntime/windows/
      // CMakeLists.txt` 钉死 DirectML 版 NuGet，随包只有 onnxruntime.dll /
      // onnxruntime_providers_shared.dll / DirectML.dll，没有
      // onnxruntime_providers_cuda.dll。这条同时钉住「别把恒不可满足的 CUDA
      // 塞回偏好表」——那只会让每卷多两条用户消不掉的假告警。
      for (final OcrModelKind kind in OcrModelKind.values) {
        final List<OcrExecutionProvider> got = selectOcrExecutionProviders(
          kind: kind,
          platform: resolveOcrPlatform('windows'),
          availableProviders: const <OcrExecutionProvider>{
            OcrExecutionProvider.cuda,
            OcrExecutionProvider.directml,
          },
        );
        expect(got, <OcrExecutionProvider>[OcrExecutionProvider.cpu],
            reason: '$kind：Windows 偏好表为空，可用性再全也不该选出加速 EP');
        expect(got, isNot(contains(OcrExecutionProvider.cuda)));
        expect(got, isNot(contains(OcrExecutionProvider.directml)));
      }
    });

    test('BUG-2050 Windows 无 CUDA 但有 DirectML：检测与识别都走纯 CPU', () {
      // 2026-09-02 本机实测拍板（RTX 5090 / ORT 1.22.0 DirectML build）：出包用的
      // int8 RT-DETR-v2 在 DML EP 上**建不出会话**——挂在
      // MLOperatorAuthorImpl.cpp(2851)，E_INVALIDARG，白付 1547ms。
      // 对照组隔离出变量：同架构 fp32 档在同一台机器同一个运行时上建得起来、
      // 且比 CPU 快 19.4 倍，D3D12CreateDevice 也正常 ⇒ 不是显卡、不是打包，
      // 就是 int8 量化。所以 DirectML 即使可用也不该被请求。
      for (final OcrModelKind kind in OcrModelKind.values) {
        final List<OcrExecutionProvider> got = selectOcrExecutionProviders(
          kind: kind,
          platform: resolveOcrPlatform('windows'),
          availableProviders: const <OcrExecutionProvider>{
            OcrExecutionProvider.directml,
          },
        );
        expect(got, <OcrExecutionProvider>[OcrExecutionProvider.cpu],
            reason: '$kind：DirectML 可用也不选（int8 建不出会话 / 解码负优化）');
        expect(got, isNot(contains(OcrExecutionProvider.directml)));
      }
    });

    test('BUG-2050 DirectML 不出现在任何平台/模型种类的偏好表里', () {
      // 这条是「别再凭那句 ~25 倍把 DirectML 加回来」的守卫。那个数量的是 fp32
      // 档（实测 19.4x，同量级），检测器换成 int8 小档后前提就没了。要加回来，
      // 前提是换模型 + 重新在真机上拿数，而不是改这条测试。
      for (final OcrPlatform platform in OcrPlatform.values) {
        for (final OcrModelKind kind in OcrModelKind.values) {
          expect(
            acceleratedProviderPreference(kind: kind, platform: platform),
            isNot(contains(OcrExecutionProvider.directml)),
            reason: '$platform/$kind 不该偏好 DirectML（BUG-2050 实测）',
          );
        }
      }
    });

    test('BUG-2050 Windows 运行时没有 DirectML：检测直接纯 CPU，不请求 DML', () {
      // 这条是本 bug 的核心：ORT 打成 CPU-only archive（BUG-1968 前的状态）或
      // DML DLL 没随包时，运行时不会回报 DirectML。原实现在这里硬假设 DML 可用，
      // 于是每个任务都白付一次注定失败的建会话再退 CPU；现在提前避开。
      for (final OcrModelKind kind in OcrModelKind.values) {
        final List<OcrExecutionProvider> got = selectOcrExecutionProviders(
          kind: kind,
          platform: resolveOcrPlatform('windows'),
          availableProviders: const <OcrExecutionProvider>{},
        );
        expect(got, <OcrExecutionProvider>[OcrExecutionProvider.cpu],
            reason: '$kind：运行时没有的 EP 绝不能出现在请求列表里');
        expect(got, isNot(contains(OcrExecutionProvider.directml)));
        expect(got, isNot(contains(OcrExecutionProvider.cuda)));
      }
    });

    test('BUG-2050 探测到的 EP 不在平台偏好里时不会被误选', () {
      // 运行时回报 CoreML（Apple 上真实会发生），但 Windows 偏好表里没有它。
      expect(
        selectOcrExecutionProviders(
          kind: OcrModelKind.detection,
          platform: resolveOcrPlatform('windows'),
          availableProviders: const <OcrExecutionProvider>{
            OcrExecutionProvider.coreml,
          },
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
            // 关键：**故意**把 CoreML 报成可用。BUG-1613 的结论是「就算能用也不
            // 许选」，探测层拆出来之后这条才真正测得到——旧签名下 CoreML 可用性
            // 根本无法表达，测的只是「代码里没写 coreml 这个词」。
            availableProviders: const <OcrExecutionProvider>{
              OcrExecutionProvider.coreml,
            },
          );
          expect(got, <OcrExecutionProvider>[OcrExecutionProvider.cpu],
              reason: '$os/$kind 不应再出现 CoreML（BUG-1613）');
          expect(got, isNot(contains(OcrExecutionProvider.coreml)));
        }
      }
    });

    test('Linux / Android：纯 CPU（即使运行时报告全部加速 EP）', () {
      for (final String os in <String>['linux', 'android']) {
        for (final OcrModelKind kind in OcrModelKind.values) {
          expect(
            selectOcrExecutionProviders(
              kind: kind,
              platform: resolveOcrPlatform(os),
              availableProviders: const <OcrExecutionProvider>{
                OcrExecutionProvider.cuda,
                OcrExecutionProvider.directml,
                OcrExecutionProvider.coreml,
              },
            ),
            <OcrExecutionProvider>[OcrExecutionProvider.cpu],
            reason: '$os/$kind：偏好表为空时，可用性再全也不该选出加速 EP',
          );
        }
      }
    });

    test('BUG-2050 偏好表与可用性是两个独立概念', () {
      // 偏好表只说「想要什么」，与本机装了什么无关——它必须是纯的。
      // 当前五端全空：Windows 见 BUG-2050（DirectML 实测排除；CUDA 没随包，写
      // 进去只会制造永久假告警），Apple 见 BUG-1613，linux/android 同档。
      for (final OcrPlatform platform in OcrPlatform.values) {
        for (final OcrModelKind kind in OcrModelKind.values) {
          expect(
            acceleratedProviderPreference(kind: kind, platform: platform),
            isEmpty,
            reason: '$platform/$kind 应当没有任何加速 EP 偏好',
          );
        }
      }
      // 偏好表里永远不含 CPU：CPU 是 selectOcrExecutionProviders 缀上的兜底档，
      // 不是「偏好」，也不参与探测。
      for (final OcrPlatform platform in OcrPlatform.values) {
        for (final OcrModelKind kind in OcrModelKind.values) {
          expect(
            acceleratedProviderPreference(kind: kind, platform: platform),
            isNot(contains(OcrExecutionProvider.cpu)),
          );
        }
      }
    });
  });

  group('BUG-2050 请求前的加速计划（planOcrAcceleration）', () {
    // 这组补的是审查里活下来的变异 M5：降级说明原先散在 `_volumeJobIsolateMain`
    // 里的两句 `recordUnavailable(...)`，删掉两句测试全绿——那条 isolate 直连真
    // ORT，单测够不到。现在决策与说明装进同一个 [OcrAccelerationPlan]，isolate
    // 拿了 provider 列表就必然带着说明，丢它只能改这里被测到的代码。

    test('五端偏好表全空 ⇒ 一条降级说明都不产生（不许弹用户消不掉的假告警）', () {
      // 这条同时是「偏好表被重新填非空」的绊线。Windows 曾经写 [cuda]，而我们出
      // 的包是 DirectML 版 NuGet，`onnxruntime_providers_cuda.dll` 根本不随包
      // ⇒ 每个整卷任务都会产出两条 `cuda not built into this ONNX Runtime -> cpu`
      // 并弹黄条，能力却与写空表时逐字相同（都是纯 CPU）。
      // 谁要把偏好表填回非空，这条会红：请连同「想要的 EP 没编进运行时」这条
      // 降级说明一起想清楚，别让降级重新变静默。
      for (final OcrPlatform platform in OcrPlatform.values) {
        for (final Set<OcrExecutionProvider> available
            in <Set<OcrExecutionProvider>>[
          const <OcrExecutionProvider>{},
          const <OcrExecutionProvider>{
            OcrExecutionProvider.cuda,
            OcrExecutionProvider.directml,
            OcrExecutionProvider.coreml,
          },
        ]) {
          final OcrAccelerationPlan plan = planOcrAcceleration(
            platform: platform,
            availableProviders: available,
          );
          expect(plan.degradeReasons, isEmpty,
              reason: '$platform / 可用=$available：纯 CPU 是本平台的正常档，不是降级');
          expect(plan.detectionProviders,
              <OcrExecutionProvider>[OcrExecutionProvider.cpu]);
          expect(plan.recognitionProviders,
              <OcrExecutionProvider>[OcrExecutionProvider.cpu]);
        }
      }
    });

    test('BUG-1163 探测失败必须留一条可读降级，不许静默', () {
      final OcrAccelerationPlan plan = planOcrAcceleration(
        platform: OcrPlatform.windows,
        availableProviders: const <OcrExecutionProvider>{},
        probeError: StateError('no ORT native'),
      );

      expect(plan.degradeReasons, hasLength(1));
      expect(plan.degradeReasons.single,
          contains('accelerated provider probe failed'));
      expect(plan.degradeReasons.single, contains('no ORT native'),
          reason: '原始异常必须带出去，否则排查时只剩「退到 CPU 了」这一句废话');
      // 探测失败不改变请求列表：偏好表为空时本来就只请求 CPU。
      expect(plan.detectionProviders,
          <OcrExecutionProvider>[OcrExecutionProvider.cpu]);
    });

    test('toAcceleration 无条件带出请求前的降级说明，再缀上建会话时的那批', () {
      // M5 的正面靶子：`degradeReasons` 一旦从这里漏掉，用户就再也看不到探测
      // 失败——而那正是「有 N 卡也退了 CPU」的唯一线索。
      const OcrAccelerationPlan plan = OcrAccelerationPlan(
        detectionProviders: <OcrExecutionProvider>[OcrExecutionProvider.cpu],
        recognitionProviders: <OcrExecutionProvider>[OcrExecutionProvider.cpu],
        degradeReasons: <String>['accelerated provider probe failed: boom'],
      );

      final MangaOcrAcceleration merged = plan.toAcceleration(
        detection: OcrExecutionProvider.cpu,
        recognition: OcrExecutionProvider.cpu,
        runtimeDegradeReasons: const <String>[
          'detector: directml -> cpu (ORT_ERROR: 80070057)',
        ],
      );

      expect(merged.degradeReasons, <String>[
        'accelerated provider probe failed: boom',
        'detector: directml -> cpu (ORT_ERROR: 80070057)',
      ]);
      expect(merged.detection, OcrExecutionProvider.cpu);
      expect(merged.recognition, OcrExecutionProvider.cpu);
      expect(() => merged.degradeReasons.add('x'), throwsUnsupportedError,
          reason: '上报给 UI 的降级列表必须是不可变快照');
    });

    test('toAcceleration 不传运行期降级时只剩请求前那批', () {
      const OcrAccelerationPlan plan = OcrAccelerationPlan(
        detectionProviders: <OcrExecutionProvider>[OcrExecutionProvider.cpu],
        recognitionProviders: <OcrExecutionProvider>[OcrExecutionProvider.cpu],
        degradeReasons: <String>['accelerated provider probe failed: boom'],
      );

      expect(
        plan
            .toAcceleration(
              detection: OcrExecutionProvider.cpu,
              recognition: OcrExecutionProvider.cpu,
            )
            .degradeReasons,
        <String>['accelerated provider probe failed: boom'],
      );
    });

    test('isolate 只能经 plan.toAcceleration 产出加速状态（源码守卫）', () {
      // `_volumeJobIsolateMain` 跑在 `Isolate.spawn` 里、直连真 ORT，单测够不到
      // 它——M5 能活下来正是因为这条缝。守法：不许它自己手搓
      // `MangaOcrAcceleration(...)`，只能走 [OcrAccelerationPlan.toAcceleration]，
      // 而那个出口是上面几条测出来的。
      final String source =
          File('lib/src/ocr/manga_ocr_service_impl.dart').readAsStringSync();
      final int start = source.indexOf('Future<void> _volumeJobIsolateMain(');
      expect(start, isNonNegative,
          reason: '找不到 _volumeJobIsolateMain；改了签名要同步改本守卫');
      // 顶层函数的收尾大括号是唯一顶格的 `}`（Dart 里嵌套块一律缩进）。
      final int end = source.indexOf('\n}\n', start);
      expect(end, isNonNegative, reason: '找不到 _volumeJobIsolateMain 的收尾大括号');
      final String body = source.substring(start, end);
      expect(
        body.contains('plan.toAcceleration('),
        isTrue,
        reason: 'isolate 不再经 plan.toAcceleration 上报加速状态 —— '
            '请求前的降级说明（探测失败等）会被静默丢掉，而这条路径没有单测能抓。',
      );
      expect(
        body.contains('MangaOcrAcceleration('),
        isFalse,
        reason: 'isolate 里又手搓了 MangaOcrAcceleration —— '
            '绕过 plan.toAcceleration 就等于绕过降级说明的唯一出口。',
      );
    });
  });
}

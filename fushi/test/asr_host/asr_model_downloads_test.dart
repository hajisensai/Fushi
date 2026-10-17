import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_asr_core/asr_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/asr_host/asr_model_downloads.dart';
import 'package:fushi/src/asr_host/gpu_runtime_pack.dart';

/// 按语言开目录的服务：只给 `plan` 用（变体 / EP 推荐按语言取）。下载与状态
/// 不该经它——登记表按包开目录。
class _FakeService extends AsrTranscriptionService {
  _FakeService(
    Directory root, {
    AsrAudioProfile profile = AsrAudioProfile.cleanSpeech,
  }) : super(
         audioProfile: profile,
         backend: const AsrIsolateBackend(buildFactory: _unusedOnnxFactory),
         openStore: (AsrLanguage l, AsrAudioProfile profile) async =>
             AsrModelStore(
               Directory(
                 p.join(root.path, asrModelPackFor(l, profile: profile).id),
               ),
               asrModelPackFor(l, profile: profile),
             ),
         jobsRoot: () async => root,
       );

  /// 被问过推荐的语言（看清楚是哪份服务被问）。
  final List<AsrLanguage> planned = <AsrLanguage>[];

  @override
  Future<AsrTranscribePlan> plan({
    required AsrLanguage language,
    required AsrAccelerationPreference preference,
  }) async {
    planned.add(language);
    return super.plan(language: language, preference: preference);
  }

  @override
  Stream<ModelDownloadEvent> downloadModel({
    required AsrLanguage language,
    required AsrEncoderVariant variant,
  }) => throw StateError('登记表必须按包下载，不能按语言经服务下载');
}

/// 某个包的目录：下载流由测试手动推，状态按包 id 编程。
class _FakeStore extends AsrModelStore {
  _FakeStore(super.dir, super.pack, this.owner);

  final _Stores owner;

  @override
  Future<AsrModelStatus> status(AsrEncoderVariant variant) async {
    final bool ready = owner.ready[pack.id] ?? false;
    return AsrModelStatus(
      ready: ready,
      diskBytes: ready ? 300 : 0,
      totalBytes: 300,
      obtainedBytes: ready ? 300 : 0,
    );
  }

  @override
  Stream<ModelDownloadEvent> download(
    AsrEncoderVariant variant, {
    ModelFileDownloader? downloader,
  }) {
    owner.downloaded.add(pack.id);
    final StreamController<ModelDownloadEvent> c =
        StreamController<ModelDownloadEvent>();
    owner.controller = c;
    return c.stream;
  }
}

class _Stores {
  _Stores(this.root);

  final Directory root;
  final Map<String, bool> ready = <String, bool>{};
  final List<String> downloaded = <String>[];
  StreamController<ModelDownloadEvent>? controller;

  Future<AsrModelStore> open(AsrModelPack pack) async =>
      _FakeStore(Directory(p.join(root.path, pack.id)), pack, this);
}

/// 顺带的 GPU 环境：报一段进度后装失败（不走真实安装与激活）。
class _FailingGpuStore extends GpuRuntimeStore {
  _FailingGpuStore(Directory root)
    : super(
        root,
        const GpuRuntimeEnvironment(
          kind: GpuRuntimeKind.directml,
          version: 'test-1',
          archives: <GpuRuntimeArchive>[],
        ),
      );

  int installs = 0;

  @override
  int get pendingDownloadBytes => 1000;

  @override
  Stream<GpuRuntimeInstallProgress> install() async* {
    installs++;
    yield const GpuRuntimeInstallProgress(
      phase: GpuRuntimeInstallPhase.download,
      received: 400,
      total: 1000,
      fileName: 'DirectML.dll',
      memberReceived: 400,
      memberTotal: 1000,
    );
    throw const SocketException('gpu boom');
  }
}

OnnxSessionFactory _unusedOnnxFactory() =>
    throw UnimplementedError('本用例不该建 ONNX 后端');

AsrTranscribePlan _plan({int obtained = 0}) => AsrTranscribePlan(
  language: AsrLanguage.japanese,
  variant: AsrEncoderVariant.int8,
  expectedProvider: OnnxExecutionProvider.cpu,
  modelStatus: AsrModelStatus(
    ready: false,
    diskBytes: obtained,
    totalBytes: 300,
    obtainedBytes: obtained,
  ),
);

/// 让 `start` 里打开目录 / 查 GPU 环境的异步段走完，下载流挂上。
Future<void> _settle() async {
  for (int i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late Directory tmp;
  late _FakeService service;
  late _Stores stores;
  final AsrModelPack pack = asrModelPackFor(AsrLanguage.japanese);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asr_model_downloads_test_');
    service = _FakeService(tmp);
    stores = _Stores(tmp);
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  AsrModelDownloads registry({
    void Function(AsrModelPack pack, {Object? error})? onFinished,
    void Function(AsrModelPack pack, Object error)? onGpuRuntimeError,
    GpuRuntimeStore? gpu,
    AsrTranscriptionService Function(AsrAudioProfile profile)?
    serviceForProfile,
  }) => AsrModelDownloads(
    onFinished: onFinished,
    onGpuRuntimeError: onGpuRuntimeError,
    openPackStore: stores.open,
    gpuRuntimeToDownload: () async => gpu,
    serviceForProfile:
        serviceForProfile ??
        (AsrAudioProfile _) => throw StateError('本用例不该按素材另建服务'),
  );

  test('逐文件事件累计成整包进度；同一个包不重复发起；结束后释放槽位', () async {
    final List<Object?> finished = <Object?>[];
    final AsrModelDownloads downloads = registry(
      onFinished: (AsrModelPack _, {Object? error}) => finished.add(error),
    );
    expect(downloads.start(pack, plan: _plan()), isTrue);
    expect(downloads.isActive(pack.id), isTrue);
    expect(downloads.start(pack, plan: _plan()), isFalse);
    await _settle();
    expect(stores.downloaded, <String>[pack.id]);

    stores.controller!
      ..add(
        const ModelDownloadEvent(
          fileName: 'a',
          receivedBytes: 100,
          totalBytes: 100,
        ),
      )
      ..add(
        const ModelDownloadEvent(
          fileName: 'b',
          receivedBytes: 50,
          totalBytes: 200,
        ),
      );
    await _settle();
    final AsrModelDownloadProgress progress = downloads.progressOf(pack.id)!;
    expect(progress.receivedBytes, 150);
    expect(progress.totalBytes, 300);
    expect(progress.currentFile, 'b');

    await stores.controller!.close();
    await _settle();
    expect(downloads.isActive(pack.id), isFalse);
    expect(downloads.lastErrorOf(pack.id), isNull);
    expect(finished, <Object?>[null]);
  });

  test('失败原因进登记表（之后 CLI 查得到），重新下载时清掉', () async {
    final List<Object?> finished = <Object?>[];
    final AsrModelDownloads downloads = registry(
      onFinished: (AsrModelPack _, {Object? error}) => finished.add(error),
    );
    downloads.start(pack, plan: _plan());
    await _settle();
    stores.controller!.addError(const SocketException('boom'));
    await _settle();
    expect(downloads.isActive(pack.id), isFalse);
    expect(downloads.lastErrorOf(pack.id), contains('boom'));
    expect(finished.single, isA<SocketException>());

    downloads.start(pack, plan: _plan());
    expect(downloads.lastErrorOf(pack.id), isNull);
  });

  test('取消：槽位释放、不记失败、不回调结束', () async {
    final List<Object?> finished = <Object?>[];
    final AsrModelDownloads downloads = registry(
      onFinished: (AsrModelPack _, {Object? error}) => finished.add(error),
    );
    downloads.start(pack, plan: _plan(obtained: 40));
    expect(downloads.progressOf(pack.id)!.receivedBytes, 40);
    await _settle();
    await downloads.cancel(pack.id);
    expect(downloads.isActive(pack.id), isFalse);
    expect(downloads.lastErrorOf(pack.id), isNull);
    expect(finished, isEmpty);
  });

  test('打开目录期间就取消：不再起下载', () async {
    final AsrModelDownloads downloads = registry();
    downloads.start(pack, plan: _plan());
    await downloads.cancel(pack.id);
    await _settle();
    expect(stores.downloaded, isEmpty);
    expect(downloads.isActive(pack.id), isFalse);
  });

  test('按包：同语言的另一个包有自己的计划状态与下载目录', () async {
    final AsrModelPack other = kAsrOptionalModelPacks.firstWhere(
      (AsrModelPack p) => p.language == AsrLanguage.japanese,
    );
    expect(other.id, isNot(pack.id));
    stores.ready[pack.id] = true;
    final AsrModelDownloads downloads = registry();

    final AsrTranscribePlan defaultPlan = await downloads.planFor(
      service,
      pack,
    );
    final AsrTranscribePlan otherPlan = await downloads.planFor(service, other);
    expect(defaultPlan.modelStatus.ready, isTrue);
    expect(otherPlan.modelStatus.ready, isFalse);

    downloads.start(other, plan: otherPlan);
    await _settle();
    expect(stores.downloaded, <String>[other.id]);
  });

  test('顺带装 GPU 环境：进度合进总量；GPU 失败不算模型失败、原因可查', () async {
    final List<Object?> finished = <Object?>[];
    final List<Object> gpuErrors = <Object>[];
    final AsrModelDownloads downloads = registry(
      onFinished: (AsrModelPack _, {Object? error}) => finished.add(error),
      onGpuRuntimeError: (AsrModelPack _, Object error) => gpuErrors.add(error),
      gpu: _FailingGpuStore(tmp),
    );
    downloads.start(pack, plan: _plan());
    await _settle();
    expect(downloads.progressOf(pack.id)!.totalBytes, 300 + 1000);

    stores.controller!
      ..add(
        const ModelDownloadEvent(
          fileName: 'a',
          receivedBytes: 300,
          totalBytes: 300,
        ),
      )
      ..add(
        const ModelDownloadEvent(
          fileName: '',
          receivedBytes: 0,
          totalBytes: 0,
          done: true,
        ),
      );
    await stores.controller!.close();
    await _settle();

    expect(gpuErrors.single, isA<SocketException>());
    expect(downloads.lastGpuRuntimeErrorOf(pack.id), contains('gpu boom'));
    expect(downloads.isActive(pack.id), isFalse);
    expect(downloads.lastErrorOf(pack.id), isNull);
    expect(finished, <Object?>[null]);

    // 重新下载时清掉上一次的 GPU 失败原因。
    downloads.start(pack, plan: _plan());
    expect(downloads.lastGpuRuntimeErrorOf(pack.id), isNull);
  });

  test('模型下载失败：以失败结束，不再去装 GPU 环境', () async {
    final List<Object?> finished = <Object?>[];
    final _FailingGpuStore gpu = _FailingGpuStore(tmp);
    final AsrModelDownloads downloads = registry(
      onFinished: (AsrModelPack _, {Object? error}) => finished.add(error),
      gpu: gpu,
    );
    downloads.start(pack, plan: _plan());
    await _settle();
    stores.controller!.addError(const SocketException('model boom'));
    await _settle();
    expect(finished.single, isA<SocketException>());
    expect(downloads.lastErrorOf(pack.id), contains('model boom'));
    expect(gpu.installs, 0);
  });

  test('顺带 GPU 环境时下载卡住也能立刻取消', () async {
    final AsrModelDownloads downloads = registry(gpu: _FailingGpuStore(tmp));
    downloads.start(pack, plan: _plan());
    await _settle();
    await downloads.cancel(pack.id);
    expect(downloads.isActive(pack.id), isFalse);
  });

  test('只服务视频的包（Parakeet）：推荐问 mixedAudio 服务，状态 / 下载按自己的包', () async {
    final List<AsrAudioProfile> built = <AsrAudioProfile>[];
    _FakeService? video;
    final AsrModelDownloads downloads = registry(
      serviceForProfile: (AsrAudioProfile profile) {
        built.add(profile);
        return video ??= _FakeService(tmp, profile: profile);
      },
    );
    stores.ready[pack.id] = true;
    expect(
      kAsrParakeetJapanesePack.servesProfile(service.audioProfile),
      isFalse,
    );

    final AsrTranscribePlan plan = await downloads.planFor(
      service,
      kAsrParakeetJapanesePack,
    );
    // 第二次问同一种素材复用同一份服务。
    await downloads.planFor(service, kAsrParakeetJapanesePack);
    expect(built, <AsrAudioProfile>[AsrAudioProfile.mixedAudio]);
    expect(video!.planned, <AsrLanguage>[
      AsrLanguage.japanese,
      AsrLanguage.japanese,
    ]);
    expect(service.planned, isEmpty);
    expect(plan.modelStatus.ready, isFalse);

    downloads.start(kAsrParakeetJapanesePack, plan: plan);
    await _settle();
    expect(stores.downloaded, <String>[kAsrParakeetJapanesePack.id]);
  });
}

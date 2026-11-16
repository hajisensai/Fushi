// BUG-4372 / 反馈 jbTZ4GIEyU：Android 低内存机跑设备端 ASR 被系统按低内存杀掉。
// BUG-4758 / 反馈 EnDAyv9ouF、_4fe2p5UsT：iPhone 15 视频页生成字幕被 jetsam 杀掉
// （门槛原先只在 Android 生效）。
// 守的是「开跑前按设备可用内存判门槛，跑不动就抛带原因与更小模型建议的异常，
// 且在碰模型目录 / 起 isolate 之前就拦下」，以及开跑时留下带模型名的活动面包屑。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_asr_core/asr_core.dart';
import 'package:fushi/src/asr_host/asr_host.dart'
    show createAsrTranscriptionService;
import 'package:fushi/src/asr_host/asr_memory_gate.dart';
import 'package:fushi/src/media/audiobook/audiobook_auto_transcribe.dart';
import 'package:fushi_engine/media/audiobook/audiobook_transcribe_import_queue.dart';

const int _mb = 1024 * 1024;
const int _gb = 1024 * _mb;

/// 只为满足构造参数；这些用例都不会真的建 ONNX 会话。
OnnxSessionFactory _unusedOnnxFactory() =>
    throw StateError('ONNX factory must not be built in memory gate tests');

/// 一个 int8 / fp32 模型都是 [bytes] 字节的 CTC 包（tokens / vad 记 0 字节）。
AsrModelPack _pack(String id, int bytes, {String? name}) => AsrModelPack(
  languages: const <AsrLanguage>[AsrLanguage.japanese],
  id: id,
  displayName: name ?? id,
  sourceUrl: 'https://example.invalid/$id',
  architecture: AsrModelArchitecture.ctc,
  files: <AsrModelFile>[
    AsrModelFile(
      fileName: 'model.onnx',
      url: 'https://example.invalid/$id/model.onnx',
      expectedBytes: bytes,
      role: AsrModelRole.ctcModelFp32,
    ),
    AsrModelFile(
      fileName: 'model.int8.onnx',
      url: 'https://example.invalid/$id/model.int8.onnx',
      expectedBytes: bytes,
      role: AsrModelRole.ctcModelInt8,
    ),
    AsrModelFile(
      fileName: 'tokens.txt',
      url: 'https://example.invalid/$id/tokens.txt',
      expectedBytes: 0,
      role: AsrModelRole.tokens,
    ),
    AsrModelFile(
      fileName: 'silero_vad.onnx',
      url: 'https://example.invalid/$id/silero_vad.onnx',
      expectedBytes: 0,
      role: AsrModelRole.vad,
    ),
  ],
);

/// 只给到「模型未就绪」的计划，并记下有没有被要求下载模型；用来守自动转录
/// 队列在下载之前就过内存门槛。
class _ModelMissingGatedService extends MemoryGatedAsrTranscriptionService {
  _ModelMissingGatedService({required DeviceMemorySnapshot? Function() probe})
    : super(
        audioProfile: AsrAudioProfile.cleanSpeech,
        backend: const AsrIsolateBackend(buildFactory: _unusedOnnxFactory),
        memoryProbe: probe,
      );

  int downloads = 0;

  @override
  Future<String?> finishedSrtPath(
    List<String> audioPaths,
    AsrLanguage language, {
    List<AsrSegmentSpan>? segments,
  }) async => null;

  @override
  Future<AsrTranscribePlan> plan({
    required AsrLanguage language,
    required AsrAccelerationPreference preference,
  }) async => AsrTranscribePlan(
    language: language,
    variant: AsrEncoderVariant.int8,
    expectedProvider: OnnxExecutionProvider.cpu,
    modelStatus: const AsrModelStatus(
      ready: false,
      diskBytes: 0,
      totalBytes: 100,
      obtainedBytes: 0,
    ),
  );

  @override
  Stream<ModelDownloadEvent> downloadModel({
    required AsrLanguage language,
    required AsrEncoderVariant variant,
  }) {
    downloads++;
    return const Stream<ModelDownloadEvent>.empty();
  }
}

/// jbTZ4GIEyU 那台 ZTE A103ZT 的量级：约 3.7 GB 物理内存，开跑时进程 RSS
/// 540 MB，系统此刻可用 1.2 GB。
const AndroidMemorySnapshot _lowEndPhone = AndroidMemorySnapshot(
  totalBytes: 3790 * _mb,
  availableBytes: 1200 * _mb,
  processRssBytes: 540 * _mb,
);

/// 12 GB 旗舰机，可用 6 GB。
const AndroidMemorySnapshot _flagship = AndroidMemorySnapshot(
  totalBytes: 12 * _gb,
  availableBytes: 6 * _gb,
  processRssBytes: 600 * _mb,
);

void main() {
  group('估算与余量（纯函数）', () {
    test('峰值 = 模型字节 × 倍数 + 固定工作集', () {
      expect(
        estimateAsrPeakMemoryBytes(
          _pack('a', 161 * _mb),
          AsrEncoderVariant.int8,
        ),
        161 * _mb * kAsrMemoryModelMultiplier + kAsrMemoryBaseWorkingSetBytes,
      );
    });

    test('余量取「进程天花板 − RSS」与 MemAvailable 的较小者', () {
      final int ceiling =
          (_lowEndPhone.totalBytes * kAndroidAsrProcessCeilingFraction)
              .floor() -
          _lowEndPhone.processRssBytes;
      expect(asrMemoryHeadroomBytes(_lowEndPhone), ceiling);
      const AndroidMemorySnapshot tightNow = AndroidMemorySnapshot(
        totalBytes: 12 * _gb,
        availableBytes: 300 * _mb,
        processRssBytes: 600 * _mb,
      );
      expect(asrMemoryHeadroomBytes(tightNow), 300 * _mb);
    });

    test('读不到 MemAvailable 时只按天花板判', () {
      const AndroidMemorySnapshot noAvailable = AndroidMemorySnapshot(
        totalBytes: 4 * _gb,
        availableBytes: null,
        processRssBytes: 0,
      );
      expect(
        asrMemoryHeadroomBytes(noAvailable),
        (4 * _gb * kAndroidAsrProcessCeilingFraction).floor(),
      );
    });
  });

  group('门槛判定', () {
    test('反馈机型 + ReazonSpeech 量级（161 MB int8）→ 拦下', () {
      final AsrModelPack reazonSized = _pack(
        'reazon',
        161 * _mb,
        name: 'ReazonSpeech',
      );
      final AsrInsufficientMemoryException? failure = asrMemoryGateVerdict(
        pack: reazonSized,
        variant: AsrEncoderVariant.int8,
        memory: _lowEndPhone,
        alternatives: <AsrModelPack>[reazonSized],
      );
      expect(failure, isNotNull);
      expect(failure!.modelName, 'ReazonSpeech');
      expect(failure.requiredBytes, greaterThan(failure.headroomBytes));
      expect(failure.suggestedModelName, isNull);
      // 给用户的那句话带模型名，且说清没有更小的可换。
      expect(failure.toString(), contains('ReazonSpeech'));
      expect(failure.toString(), isNot(contains('Instance of')));
    });

    test('拦下时建议注册表顺序里第一个放得下的更小模型，跳过放不下的', () {
      final AsrModelPack current = _pack('big', 1000 * _mb, name: 'Big');
      final AsrModelPack stillTooBig = _pack('mid', 500 * _mb, name: 'Mid');
      final AsrModelPack fits = _pack('tiny', 40 * _mb, name: 'Tiny');
      final AsrInsufficientMemoryException? failure = asrMemoryGateVerdict(
        pack: current,
        variant: AsrEncoderVariant.int8,
        memory: _lowEndPhone,
        alternatives: <AsrModelPack>[current, stillTooBig, fits],
      );
      expect(failure, isNotNull);
      expect(failure!.suggestedModelName, 'Tiny');
      expect(failure.toString(), contains('Tiny'));
    });

    test('旗舰机放得下 → 不拦', () {
      expect(
        asrMemoryGateVerdict(
          pack: _pack('reazon', 161 * _mb),
          variant: AsrEncoderVariant.int8,
          memory: _flagship,
          alternatives: const <AsrModelPack>[],
        ),
        isNull,
      );
    });
  });

  group('/proc 解析', () {
    test('meminfo 取 MemTotal / MemAvailable（kB → 字节）', () {
      const String meminfo =
          'MemTotal:        3881236 kB\n'
          'MemFree:          102400 kB\n'
          'MemAvailable:    1228800 kB\n';
      expect(parseProcMeminfoBytes(meminfo, 'MemTotal'), 3881236 * 1024);
      expect(parseProcMeminfoBytes(meminfo, 'MemAvailable'), 1228800 * 1024);
      expect(parseProcMeminfoBytes(meminfo, 'SwapTotal'), isNull);
    });

    test('status 取 VmRSS，不误认 VmRSSx 之类的前缀', () {
      const String status =
          'Name:\tapp.fushi.reader\n'
          'VmHWM:\t  560000 kB\n'
          'VmRSS:\t  552960 kB\n';
      expect(parseProcStatusRssBytes(status), 552960 * 1024);
    });
  });

  group('MemoryGatedAsrTranscriptionService.start', () {
    MemoryGatedAsrTranscriptionService service({
      required DeviceMemorySnapshot? Function() probe,
      required void Function() onOpenStore,
      AsrTranscribeBreadcrumb? breadcrumb,
    }) => MemoryGatedAsrTranscriptionService(
      audioProfile: AsrAudioProfile.cleanSpeech,
      backend: const AsrIsolateBackend(buildFactory: _unusedOnnxFactory),
      openStore: (AsrLanguage language, AsrAudioProfile profile) async {
        onOpenStore();
        throw StateError('reached model store');
      },
      memoryProbe: probe,
      breadcrumb:
          breadcrumb ?? AsrTranscribeBreadcrumb(mark: (_) {}, clear: () {}),
    );

    Future<void> startJapanese(AsrTranscriptionService s) => s.start(
      audioPaths: const <String>['/nonexistent/book.m4b'],
      language: AsrLanguage.japanese,
      variant: AsrEncoderVariant.int8,
      preference: AsrAccelerationPreference.cpuOnly,
    );

    test('内存不够：在打开模型目录 / 起转录之前就抛 AsrInsufficientMemoryException', () async {
      int storeOpened = 0;
      final MemoryGatedAsrTranscriptionService s = service(
        probe: () => const AndroidMemorySnapshot(
          totalBytes: 3790 * _mb,
          availableBytes: 200 * _mb,
          processRssBytes: 900 * _mb,
        ),
        onOpenStore: () => storeOpened++,
      );
      await expectLater(
        startJapanese(s),
        throwsA(isA<AsrInsufficientMemoryException>()),
      );
      expect(storeOpened, 0);
    });

    test('内存够：照常进入原转录流程', () async {
      int storeOpened = 0;
      final MemoryGatedAsrTranscriptionService s = service(
        probe: () => _flagship,
        onOpenStore: () => storeOpened++,
      );
      await expectLater(
        startJapanese(s),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            'reached model store',
          ),
        ),
      );
      expect(storeOpened, 1);
    });

    test('桌面端（探测返回 null）：不设门槛', () async {
      int storeOpened = 0;
      final MemoryGatedAsrTranscriptionService s = service(
        probe: () => null,
        onOpenStore: () => storeOpened++,
      );
      await expectLater(startJapanese(s), throwsA(isA<StateError>()));
      expect(storeOpened, 1);
    });

    test('开跑前写下带模型名与余量的活动面包屑，起转录失败时清掉', () async {
      final List<String> marks = <String>[];
      final List<int> storeOpenedAtMark = <int>[];
      int storeOpened = 0;
      int clears = 0;
      final MemoryGatedAsrTranscriptionService s = service(
        probe: () => _flagship,
        onOpenStore: () => storeOpened++,
        breadcrumb: AsrTranscribeBreadcrumb(
          mark: (String detail) {
            marks.add(detail);
            storeOpenedAtMark.add(storeOpened);
          },
          clear: () => clears++,
        ),
      );
      await expectLater(startJapanese(s), throwsA(isA<StateError>()));
      final AsrModelPack pack = asrModelPackFor(
        AsrLanguage.japanese,
        profile: AsrAudioProfile.cleanSpeech,
      );
      expect(marks, hasLength(1));
      expect(marks.single, contains('model=${pack.id}'));
      expect(marks.single, contains('variant=int8'));
      expect(marks.single, contains('headroom='));
      // 面包屑在打开模型目录（之后才建会话 / 起 isolate）之前就落盘。
      expect(storeOpenedAtMark, <int>[0]);
      expect(clears, 1);
    });

    test('被门槛拦下：不写面包屑', () async {
      final List<String> marks = <String>[];
      final MemoryGatedAsrTranscriptionService s = service(
        probe: () => const IosJetsamMemorySnapshot(
          availableBytes: 100 * _mb,
          processRssBytes: 700 * _mb,
        ),
        onOpenStore: () {},
        breadcrumb: AsrTranscribeBreadcrumb(mark: marks.add, clear: () {}),
      );
      await expectLater(
        startJapanese(s),
        throwsA(isA<AsrInsufficientMemoryException>()),
      );
      expect(marks, isEmpty);
    });
  });

  group('iOS jetsam 额度（BUG-4758）', () {
    test('余量就是 os_proc_available_memory，不再套物理内存比例', () {
      const IosJetsamMemorySnapshot memory = IosJetsamMemorySnapshot(
        availableBytes: 1600 * _mb,
        processRssBytes: 700 * _mb,
      );
      expect(asrMemoryHeadroomBytes(memory), 1600 * _mb);
    });

    test('系统回 0（无 jetsam 额度：模拟器 / Mac 上的 iOS app）不设门槛', () {
      expect(
        iosJetsamMemorySnapshotFrom(availableBytes: 0, processRssBytes: 1),
        isNull,
      );
      expect(
        iosJetsamMemorySnapshotFrom(
          availableBytes: 2 * _gb,
          processRssBytes: 600 * _mb,
        )?.headroomBytes,
        2 * _gb,
      );
    });

    test('反馈场景：iPhone 视频页（mixedAudio）日语默认模型放不下，开跑前拦下并建议更小的', () {
      // EnDAyv9ouF：视频页 RSS 约 0.5~0.7 GB 时开跑，随后被 jetsam 杀掉。6 GB 机型
      // 前台额度约 3 GB，视频页开着时剩 1.6 GB 量级。
      final MemoryGatedAsrTranscriptionService s =
          MemoryGatedAsrTranscriptionService(
            audioProfile: AsrAudioProfile.mixedAudio,
            backend: const AsrIsolateBackend(buildFactory: _unusedOnnxFactory),
            memoryProbe: () => const IosJetsamMemorySnapshot(
              availableBytes: 1600 * _mb,
              processRssBytes: 650 * _mb,
            ),
          );
      final AsrModelPack videoPack = asrModelPackFor(
        AsrLanguage.japanese,
        profile: AsrAudioProfile.mixedAudio,
      );
      expect(
        estimateAsrPeakMemoryBytes(videoPack, AsrEncoderVariant.int8),
        greaterThan(1600 * _mb),
      );
      AsrInsufficientMemoryException? failure;
      try {
        s.ensureMemoryFor(AsrLanguage.japanese, AsrEncoderVariant.int8);
      } on AsrInsufficientMemoryException catch (error) {
        failure = error;
      }
      expect(failure, isNotNull);
      expect(failure!.modelName, videoPack.displayName);
      expect(failure.suggestedModelName, isNotNull);
      expect(failure.suggestedModelName, isNot(videoPack.displayName));
    });

    test('额度够：放行，返回带模型名的诊断行', () {
      final MemoryGatedAsrTranscriptionService s =
          MemoryGatedAsrTranscriptionService(
            audioProfile: AsrAudioProfile.mixedAudio,
            backend: const AsrIsolateBackend(buildFactory: _unusedOnnxFactory),
            memoryProbe: () => const IosJetsamMemorySnapshot(
              availableBytes: 4 * _gb,
              processRssBytes: 300 * _mb,
            ),
          );
      final AsrModelPack videoPack = asrModelPackFor(
        AsrLanguage.japanese,
        profile: AsrAudioProfile.mixedAudio,
      );
      final String diagnostic = s.ensureMemoryFor(
        AsrLanguage.japanese,
        AsrEncoderVariant.int8,
      );
      expect(diagnostic, contains('model=${videoPack.id}'));
      expect(diagnostic, contains('profile=mixedAudio'));
      expect(diagnostic, contains('headroom=4096MB'));
    });
  });

  group('转录活动面包屑', () {
    test('多路转录按引用计数：最后一路结束才清，结束回调只生效一次', () {
      final List<String> marks = <String>[];
      int clears = 0;
      final AsrTranscribeBreadcrumb crumb = AsrTranscribeBreadcrumb(
        mark: marks.add,
        clear: () => clears++,
      );
      final void Function() endA = crumb.begin('a');
      final void Function() endB = crumb.begin('b');
      endA();
      endA();
      expect(clears, 0);
      endB();
      expect(clears, 1);
      expect(marks, <String>[
        'a',
        'a${AsrTranscribeBreadcrumb.separator}b',
        'b',
      ]);
    });

    test('后开的一路先结束：面包屑改回仍在跑那一路的模型，不残留已结束的', () {
      String? current;
      final AsrTranscribeBreadcrumb crumb = AsrTranscribeBreadcrumb(
        mark: (String detail) => current = detail,
        clear: () => current = null,
      );
      final void Function() endBook = crumb.begin('model=reazon');
      final void Function() endVideo = crumb.begin('model=parakeet');
      expect(current, contains('model=reazon'));
      expect(current, contains('model=parakeet'));
      endVideo();
      expect(current, 'model=reazon');
      endBook();
      expect(current, isNull);
    });

    test('事件流结束即调结束回调，dispose 也会调（回调幂等由 begin 保证）', () async {
      int ends = 0;
      final _FakeRunning inner = _FakeRunning();
      final AsrRunningTranscription wrapped = asrTranscriptionEndingBreadcrumb(
        inner,
        () => ends++,
      );
      expect(wrapped.encoderResolution, same(inner.encoderResolution));
      final Future<List<AsrTranscribeEvent>> events = wrapped.run().toList();
      await inner.events.close();
      await events;
      expect(ends, 1);
      await wrapped.dispose();
      expect(inner.disposed, isTrue);
      expect(ends, 2);
    });

    test('从没订阅事件流、直接 dispose 也会结束', () async {
      int ends = 0;
      final _FakeRunning inner = _FakeRunning();
      await asrTranscriptionEndingBreadcrumb(inner, () => ends++).dispose();
      expect(ends, 1);
    });
  });

  test('有声书自动转录：内存不够时在下载模型之前就失败，不白下一次', () async {
    final _ModelMissingGatedService service = _ModelMissingGatedService(
      probe: () => const AndroidMemorySnapshot(
        totalBytes: 3790 * _mb,
        availableBytes: 200 * _mb,
        processRssBytes: 900 * _mb,
      ),
    );
    final AppAudiobookTranscriber transcriber = AppAudiobookTranscriber(
      serviceFactory: () => service,
      preferredLanguageTag: () => 'ja',
    );
    final List<AudiobookTranscribeJobPhase> phases =
        <AudiobookTranscribeJobPhase>[];
    await expectLater(
      transcriber.transcribe(
        AudiobookTranscribeJob(
          id: 'job',
          title: 'book',
          audioPaths: const <String>['/nonexistent/book.m4b'],
          createdAt: 0,
          updatedAt: 0,
        ),
        onProgress: (AudiobookTranscribeJobPhase phase, double? _) =>
            phases.add(phase),
        cancel: AudiobookTranscribeCancelToken(),
      ),
      throwsA(isA<AsrInsufficientMemoryException>()),
    );
    expect(service.downloads, 0);
    expect(
      phases,
      isNot(contains(AudiobookTranscribeJobPhase.downloadingModel)),
    );
  });

  group('设备内存探针分派（BUG-4758 根因：默认探针原先只认 Android）', () {
    const AndroidMemorySnapshot android = AndroidMemorySnapshot(
      totalBytes: 4 * _gb,
      availableBytes: _gb,
      processRssBytes: 500 * _mb,
    );
    const IosJetsamMemorySnapshot ios = IosJetsamMemorySnapshot(
      availableBytes: 1600 * _mb,
      processRssBytes: 650 * _mb,
    );

    test('iOS 走 jetsam 额度，Android 走 /proc，桌面不设门槛', () {
      expect(
        deviceMemorySnapshotFor(
          isAndroid: false,
          isIOS: true,
          android: () => android,
          ios: () => ios,
        ),
        same(ios),
      );
      expect(
        deviceMemorySnapshotFor(
          isAndroid: true,
          isIOS: false,
          android: () => android,
          ios: () => ios,
        ),
        same(android),
      );
      expect(
        deviceMemorySnapshotFor(
          isAndroid: false,
          isIOS: false,
          android: () => android,
          ios: () => ios,
        ),
        isNull,
      );
    });

    test('生产服务的默认探针是跨平台的 readDeviceMemorySnapshot', () {
      final AsrTranscriptionService service = createAsrTranscriptionService(
        audioProfile: AsrAudioProfile.mixedAudio,
      );
      expect(
        identical(
          (service as MemoryGatedAsrTranscriptionService).memoryProbe,
          readDeviceMemorySnapshot,
        ),
        isTrue,
      );
    });
  });

  test('生产装配点返回带门槛的服务（所有入口经它，门槛只此一处）', () {
    expect(
      createAsrTranscriptionService(),
      isA<MemoryGatedAsrTranscriptionService>(),
    );
    expect(
      createAsrTranscriptionService(audioProfile: AsrAudioProfile.mixedAudio),
      isA<MemoryGatedAsrTranscriptionService>(),
    );
  });
}

class _FakeRunning implements AsrRunningTranscription {
  final StreamController<AsrTranscribeEvent> events =
      StreamController<AsrTranscribeEvent>();
  bool disposed = false;

  @override
  final OnnxProviderResolution encoderResolution = const OnnxProviderResolution(
    requested: <OnnxExecutionProvider>[OnnxExecutionProvider.cpu],
    effective: OnnxExecutionProvider.cpu,
  );

  @override
  bool get greedyGraphAvailable => true;

  @override
  String? get greedyUnavailableReason => null;

  @override
  bool get encoderFp16 => false;

  @override
  AsrDecodeStats? get decodeStats => null;

  @override
  Stream<AsrTranscribeEvent> run() => events.stream;

  @override
  void requestPause({bool discardPending = false}) {}

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

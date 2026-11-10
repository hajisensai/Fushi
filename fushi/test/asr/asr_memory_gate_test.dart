// BUG-4372 / 反馈 jbTZ4GIEyU：Android 低内存机跑设备端 ASR 被系统按低内存杀掉。
// 守的是「开跑前按设备可用内存判门槛，跑不动就抛带原因与更小模型建议的异常，
// 且在碰模型目录 / 起 isolate 之前就拦下」。
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
const DeviceMemorySnapshot _lowEndPhone = DeviceMemorySnapshot(
  totalBytes: 3790 * _mb,
  availableBytes: 1200 * _mb,
  processRssBytes: 540 * _mb,
);

/// 12 GB 旗舰机，可用 6 GB。
const DeviceMemorySnapshot _flagship = DeviceMemorySnapshot(
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
      const DeviceMemorySnapshot tightNow = DeviceMemorySnapshot(
        totalBytes: 12 * _gb,
        availableBytes: 300 * _mb,
        processRssBytes: 600 * _mb,
      );
      expect(asrMemoryHeadroomBytes(tightNow), 300 * _mb);
    });

    test('读不到 MemAvailable 时只按天花板判', () {
      const DeviceMemorySnapshot noAvailable = DeviceMemorySnapshot(
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
    }) => MemoryGatedAsrTranscriptionService(
      audioProfile: AsrAudioProfile.cleanSpeech,
      backend: const AsrIsolateBackend(buildFactory: _unusedOnnxFactory),
      openStore: (AsrLanguage language, AsrAudioProfile profile) async {
        onOpenStore();
        throw StateError('reached model store');
      },
      memoryProbe: probe,
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
        probe: () => const DeviceMemorySnapshot(
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

    test('非 Android（探测返回 null）：不设门槛', () async {
      int storeOpened = 0;
      final MemoryGatedAsrTranscriptionService s = service(
        probe: () => null,
        onOpenStore: () => storeOpened++,
      );
      await expectLater(startJapanese(s), throwsA(isA<StateError>()));
      expect(storeOpened, 1);
    });
  });

  test('有声书自动转录：内存不够时在下载模型之前就失败，不白下一次', () async {
    final _ModelMissingGatedService service = _ModelMissingGatedService(
      probe: () => const DeviceMemorySnapshot(
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

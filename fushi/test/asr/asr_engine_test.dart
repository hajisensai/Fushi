import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_engine.dart';
import 'package:fushi/src/asr/asr_model_manifest.dart';
import 'package:fushi/src/asr/asr_model_store.dart';
import 'package:fushi/src/onnx/onnx_inference.dart';
import 'package:fushi/src/onnx/onnx_inference_ort.dart';
import 'package:path/path.dart' as p;

const List<OnnxExecutionProvider> _cpu = <OnnxExecutionProvider>[
  OnnxExecutionProvider.cpu,
];

class _FakeSession implements OnnxSession {
  _FakeSession(this.path, this.providers);

  final String path;
  final List<OnnxExecutionProvider> providers;
  bool closed = false;

  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async =>
      const <String, OnnxTensor>{};

  @override
  Future<void> close() async => closed = true;
}

class _FakeRuntime extends OnnxRuntime {
  @override
  Future<List<OrtProvider>> getAvailableProviders() async =>
      const <OrtProvider>[OrtProvider.CPU];
}

/// 模拟共享工厂：记录每个模型路径拿到的 providers，可让首选 EP「建失败」
/// 以触发回退，可让探测抛错，可让指定文件建会话失败。
class _FakeFactory extends OrtOnnxSessionFactory {
  _FakeFactory({
    this.available = const <OnnxExecutionProvider>{},
    this.probeError,
    this.rejectAccelerated = false,
    this.failOnPathSuffix,
  }) : super(runtime: _FakeRuntime());

  final Set<OnnxExecutionProvider> available;
  final Error? probeError;
  final bool rejectAccelerated;
  final String? failOnPathSuffix;
  final Map<String, _FakeSession> sessions = <String, _FakeSession>{};
  int probeCalls = 0;

  @override
  Future<Set<OnnxExecutionProvider>> availableAcceleratedProviders() async {
    probeCalls++;
    final Error? error = probeError;
    if (error != null) throw error;
    return available;
  }

  @override
  Future<OnnxSession> createSession(
    String modelPath, {
    required List<OnnxExecutionProvider> providers,
    void Function(OnnxProviderResolution resolution)? onProviderResolved,
  }) async {
    final String? suffix = failOnPathSuffix;
    if (suffix != null && modelPath.endsWith(suffix)) {
      throw StateError('cannot open $modelPath');
    }
    final _FakeSession session =
        await createOnnxSessionWithProviderFallback<_FakeSession>(
          providers: providers,
          onResolved: onProviderResolved,
          create: (List<OnnxExecutionProvider> effective) async {
            if (rejectAccelerated &&
                effective.first != OnnxExecutionProvider.cpu) {
              // 真实形态：ORT 在建 session 之中抛 PlatformException（BUG-2034）。
              throw PlatformException(
                code: 'ORT_ERROR',
                message: '${effective.first.name} rejected',
              );
            }
            return _FakeSession(
              modelPath,
              List<OnnxExecutionProvider>.from(effective),
            );
          },
        );
    sessions[p.basename(modelPath)] = session;
    return session;
  }
}

void main() {
  group('selectAsrEncoderProviders', () {
    const Set<OnnxExecutionProvider> all = <OnnxExecutionProvider>{
      OnnxExecutionProvider.cuda,
      OnnxExecutionProvider.directml,
      OnnxExecutionProvider.coreml,
    };

    test('cpuOnly 恒 CPU，不看平台、可用集合、变体', () {
      for (final AsrPlatform platform in AsrPlatform.values) {
        for (final AsrEncoderVariant variant in AsrEncoderVariant.values) {
          expect(
            selectAsrEncoderProviders(
              platform: platform,
              available: all,
              preference: AsrAccelerationPreference.cpuOnly,
              variant: variant,
            ),
            _cpu,
            reason: '${platform.name}/${variant.name}',
          );
        }
      }
    });

    test('int8 编码器恒 CPU（BUG-2050：int8 在 DML 上建不出会话）', () {
      for (final AsrPlatform platform in AsrPlatform.values) {
        expect(
          selectAsrEncoderProviders(
            platform: platform,
            available: all,
            preference: AsrAccelerationPreference.auto,
            variant: AsrEncoderVariant.int8,
          ),
          _cpu,
          reason: platform.name,
        );
      }
    });

    group('Windows fp32', () {
      List<OnnxExecutionProvider> select(
        Set<OnnxExecutionProvider> available,
      ) => selectAsrEncoderProviders(
        platform: AsrPlatform.windows,
        available: available,
        preference: AsrAccelerationPreference.auto,
        variant: AsrEncoderVariant.fp32,
      );

      test('DirectML 可用 → [directml, cpu]', () {
        expect(
          select(const <OnnxExecutionProvider>{OnnxExecutionProvider.directml}),
          const <OnnxExecutionProvider>[
            OnnxExecutionProvider.directml,
            OnnxExecutionProvider.cpu,
          ],
        );
      });

      test('CUDA 与 DirectML 都可用 → CUDA 优先', () {
        expect(
          select(const <OnnxExecutionProvider>{
            OnnxExecutionProvider.directml,
            OnnxExecutionProvider.cuda,
          }),
          const <OnnxExecutionProvider>[
            OnnxExecutionProvider.cuda,
            OnnxExecutionProvider.cpu,
          ],
        );
      });

      test('只有 CUDA → [cuda, cpu]', () {
        expect(
          select(const <OnnxExecutionProvider>{OnnxExecutionProvider.cuda}),
          const <OnnxExecutionProvider>[
            OnnxExecutionProvider.cuda,
            OnnxExecutionProvider.cpu,
          ],
        );
      });

      test('一个加速 EP 都没有 → CPU；CoreML 在 Windows 上不被选', () {
        expect(select(const <OnnxExecutionProvider>{}), _cpu);
        expect(
          select(const <OnnxExecutionProvider>{OnnxExecutionProvider.coreml}),
          _cpu,
        );
      });
    });

    test('macOS / iOS fp32：CoreML 即使可用也不开（BUG-1613，待真机拿数）', () {
      for (final AsrPlatform platform in <AsrPlatform>[
        AsrPlatform.macos,
        AsrPlatform.ios,
      ]) {
        expect(
          selectAsrEncoderProviders(
            platform: platform,
            available: all,
            preference: AsrAccelerationPreference.auto,
            variant: AsrEncoderVariant.fp32,
          ),
          _cpu,
          reason: platform.name,
        );
      }
    });

    test('Linux / Android fp32：CPU', () {
      for (final AsrPlatform platform in <AsrPlatform>[
        AsrPlatform.linux,
        AsrPlatform.android,
      ]) {
        expect(
          selectAsrEncoderProviders(
            platform: platform,
            available: all,
            preference: AsrAccelerationPreference.auto,
            variant: AsrEncoderVariant.fp32,
          ),
          _cpu,
          reason: platform.name,
        );
      }
    });

    test('任何加速 EP 后面都缀 CPU 兜底，且列表恰两项', () {
      for (final AsrPlatform platform in AsrPlatform.values) {
        final List<OnnxExecutionProvider> providers = selectAsrEncoderProviders(
          platform: platform,
          available: all,
          preference: AsrAccelerationPreference.auto,
          variant: AsrEncoderVariant.fp32,
        );
        expect(providers.last, OnnxExecutionProvider.cpu);
        expect(providers.length, lessThanOrEqualTo(2));
        expect(providers.toSet().length, providers.length);
      }
    });
  });

  group('recommendAsrEncoderVariant', () {
    test('Windows 有 DirectML → fp32；没有 → int8', () {
      expect(
        recommendAsrEncoderVariant(
          platform: AsrPlatform.windows,
          available: const <OnnxExecutionProvider>{
            OnnxExecutionProvider.directml,
          },
          preference: AsrAccelerationPreference.auto,
        ),
        AsrEncoderVariant.fp32,
      );
      expect(
        recommendAsrEncoderVariant(
          platform: AsrPlatform.windows,
          available: const <OnnxExecutionProvider>{},
          preference: AsrAccelerationPreference.auto,
        ),
        AsrEncoderVariant.int8,
      );
    });

    test('cpuOnly → int8，即使有 GPU EP', () {
      expect(
        recommendAsrEncoderVariant(
          platform: AsrPlatform.windows,
          available: const <OnnxExecutionProvider>{OnnxExecutionProvider.cuda},
          preference: AsrAccelerationPreference.cpuOnly,
        ),
        AsrEncoderVariant.int8,
      );
    });

    test('Apple / Linux / Android → int8', () {
      for (final AsrPlatform platform in <AsrPlatform>[
        AsrPlatform.macos,
        AsrPlatform.ios,
        AsrPlatform.linux,
        AsrPlatform.android,
      ]) {
        expect(
          recommendAsrEncoderVariant(
            platform: platform,
            available: const <OnnxExecutionProvider>{
              OnnxExecutionProvider.coreml,
              OnnxExecutionProvider.cuda,
            },
            preference: AsrAccelerationPreference.auto,
          ),
          AsrEncoderVariant.int8,
          reason: platform.name,
        );
      }
    });
  });

  group('AsrEngineLoader.load', () {
    late Directory tempDir;
    late AsrModelStore store;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('asr_engine_');
      store = AsrModelStore(tempDir);
      // 会话是 fake，模型文件只需存在；tokens 需要真内容。
      for (final AsrModelFile f in kAsrModelFiles) {
        final File file = store.fileFor(f.role);
        if (f.role == AsrModelRole.tokens) {
          file.writeAsStringSync(
            '<blk>\t0\nあ\t1\nい\t2\n<unk>\t3\n<sos/eos>\t4\n',
          );
        } else {
          file.writeAsBytesSync(<int>[1]);
        }
      }
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    // 策略按真实宿主平台算——load 不接受平台注入（它就是要读真机）。
    List<OnnxExecutionProvider> expectedEncoder({
      required Set<OnnxExecutionProvider> available,
      required AsrEncoderVariant variant,
      AsrAccelerationPreference preference = AsrAccelerationPreference.auto,
    }) => selectAsrEncoderProviders(
      platform: currentAsrPlatform(),
      available: available,
      preference: preference,
      variant: variant,
    );

    test(
      'encoder 用策略选出的 providers，decoder/joiner/vad 恒 CPU，resolution 透传',
      () async {
        const Set<OnnxExecutionProvider> available = <OnnxExecutionProvider>{
          OnnxExecutionProvider.cuda,
          OnnxExecutionProvider.directml,
        };
        final _FakeFactory factory = _FakeFactory(available: available);
        final AsrEngineSessions sessions =
            await AsrEngineLoader(factory: factory).load(
              store: store,
              variant: AsrEncoderVariant.fp32,
              preference: AsrAccelerationPreference.auto,
            );

        final List<OnnxExecutionProvider> expected = expectedEncoder(
          available: available,
          variant: AsrEncoderVariant.fp32,
        );
        expect(factory.probeCalls, 1);
        expect(
          factory.sessions[kAsrEncoderFp32File.fileName]!.providers,
          expected,
        );
        expect(
          factory.sessions.containsKey(kAsrEncoderInt8File.fileName),
          isFalse,
          reason: '只建请求的变体',
        );
        for (final String name in <String>[
          kAsrDecoderFp32File.fileName,
          kAsrJoinerFp32File.fileName,
          kAsrVadFile.fileName,
        ]) {
          expect(factory.sessions[name]!.providers, _cpu, reason: name);
        }
        expect(sessions.variant, AsrEncoderVariant.fp32);
        expect(sessions.encoderResolution.requested, expected);
        expect(sessions.encoderResolution.effective, expected.first);
        expect(sessions.encoderResolution.didFallBack, isFalse);
        expect(sessions.tokens.size, 5);
        expect(sessions.tokens.blankId, 0);
        expect(sessions.tokens.tokenAt(1), 'あ');
        expect(
          identical(
            sessions.encoder,
            factory.sessions[kAsrEncoderFp32File.fileName],
          ),
          isTrue,
        );
        expect(
          identical(
            sessions.decoder,
            factory.sessions[kAsrDecoderFp32File.fileName],
          ),
          isTrue,
        );
        expect(
          identical(
            sessions.joiner,
            factory.sessions[kAsrJoinerFp32File.fileName],
          ),
          isTrue,
        );
        expect(
          identical(sessions.vad, factory.sessions[kAsrVadFile.fileName]),
          isTrue,
        );
      },
    );

    test('int8 变体：encoder 也是 CPU，用 int8 文件', () async {
      final _FakeFactory factory = _FakeFactory(
        available: const <OnnxExecutionProvider>{
          OnnxExecutionProvider.directml,
        },
      );
      final AsrEngineSessions sessions = await AsrEngineLoader(factory: factory)
          .load(
            store: store,
            variant: AsrEncoderVariant.int8,
            preference: AsrAccelerationPreference.auto,
          );
      expect(factory.sessions[kAsrEncoderInt8File.fileName]!.providers, _cpu);
      expect(
        factory.sessions.containsKey(kAsrEncoderFp32File.fileName),
        isFalse,
      );
      expect(sessions.encoderResolution.effective, OnnxExecutionProvider.cpu);
      expect(
        sessions.encoderResolution.didFallBack,
        isFalse,
        reason: '按策略本来就该走 CPU 不是降级',
      );
    });

    test('cpuOnly：不探测，全部 CPU', () async {
      final _FakeFactory factory = _FakeFactory(
        available: const <OnnxExecutionProvider>{
          OnnxExecutionProvider.directml,
        },
      );
      final AsrEngineSessions sessions = await AsrEngineLoader(factory: factory)
          .load(
            store: store,
            variant: AsrEncoderVariant.fp32,
            preference: AsrAccelerationPreference.cpuOnly,
          );
      expect(factory.probeCalls, 0);
      for (final _FakeSession session in factory.sessions.values) {
        expect(session.providers, _cpu, reason: session.path);
      }
      expect(sessions.encoderResolution.effective, OnnxExecutionProvider.cpu);
      expect(sessions.encoderResolution.didFallBack, isFalse);
    });

    test('加速 EP 运行期建失败 → 退 CPU 且 resolution 带原因（BUG-1163 / 2034）', () async {
      const Set<OnnxExecutionProvider> available = <OnnxExecutionProvider>{
        OnnxExecutionProvider.directml,
      };
      final List<OnnxExecutionProvider> expected = expectedEncoder(
        available: available,
        variant: AsrEncoderVariant.fp32,
      );
      if (expected.first == OnnxExecutionProvider.cpu) {
        // 本宿主策略本来就是 CPU（Apple / Linux），无降级可测。
        return;
      }
      final _FakeFactory factory = _FakeFactory(
        available: available,
        rejectAccelerated: true,
      );
      final AsrEngineSessions sessions = await AsrEngineLoader(factory: factory)
          .load(
            store: store,
            variant: AsrEncoderVariant.fp32,
            preference: AsrAccelerationPreference.auto,
          );
      expect(factory.sessions[kAsrEncoderFp32File.fileName]!.providers, _cpu);
      expect(sessions.encoderResolution.requested, expected);
      expect(sessions.encoderResolution.effective, OnnxExecutionProvider.cpu);
      expect(sessions.encoderResolution.didFallBack, isTrue);
      expect(sessions.encoderResolution.fallbackReason, contains('rejected'));
    });

    test('探测抛错 → 按 CPU 装载，但原因写进 resolution（探测失败也是降级）', () async {
      final _FakeFactory factory = _FakeFactory(
        probeError: StateError('no ORT native'),
      );
      final AsrEngineSessions sessions = await AsrEngineLoader(factory: factory)
          .load(
            store: store,
            variant: AsrEncoderVariant.fp32,
            preference: AsrAccelerationPreference.auto,
          );
      expect(factory.sessions[kAsrEncoderFp32File.fileName]!.providers, _cpu);
      expect(sessions.encoderResolution.effective, OnnxExecutionProvider.cpu);
      expect(sessions.encoderResolution.didFallBack, isTrue);
      expect(
        sessions.encoderResolution.fallbackReason,
        contains('no ORT native'),
      );
    });

    test('中途建会话失败：已建的会话全部关闭，异常原样抛出', () async {
      final _FakeFactory factory = _FakeFactory(
        failOnPathSuffix: kAsrJoinerInt8File.fileName,
      );
      await expectLater(
        AsrEngineLoader(factory: factory).load(
          store: store,
          variant: AsrEncoderVariant.int8,
          preference: AsrAccelerationPreference.cpuOnly,
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        factory.sessions.keys,
        containsAll(<String>[
          kAsrEncoderInt8File.fileName,
          kAsrDecoderInt8File.fileName,
        ]),
      );
      for (final _FakeSession session in factory.sessions.values) {
        expect(session.closed, isTrue, reason: '${session.path} 泄漏');
      }
    });

    test('close 关掉四个会话', () async {
      final _FakeFactory factory = _FakeFactory();
      final AsrEngineSessions sessions = await AsrEngineLoader(factory: factory)
          .load(
            store: store,
            variant: AsrEncoderVariant.int8,
            preference: AsrAccelerationPreference.cpuOnly,
          );
      await sessions.close();
      expect(factory.sessions, hasLength(4));
      for (final _FakeSession session in factory.sessions.values) {
        expect(session.closed, isTrue, reason: session.path);
      }
    });
  });

  test('currentAsrPlatform 与宿主一致', () {
    final AsrPlatform platform = currentAsrPlatform();
    if (Platform.isWindows) expect(platform, AsrPlatform.windows);
    if (Platform.isMacOS) expect(platform, AsrPlatform.macos);
    if (Platform.isLinux) expect(platform, AsrPlatform.linux);
  });
}

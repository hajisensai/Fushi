import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/gal_hook_failure_text.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';
import '../helpers/source_guard.dart';

/// BUG-1216：共享内存打不开的真实原因不得在返回值处被丢弃。
///
/// 现场是「同一台机器、同一个 app，一个游戏能捕获、另一个不能」，而失败侧只给出一句
/// 「捕获通道无法打开，请重启 Hibiki。」——拒绝访问、helper 版本不符、映射根本不存在
/// 三种处置完全不同的现场长得一模一样，重启对其中两种毫无意义。
///
/// 信息在三层各丢一次：native `Open` 四条出口一律返回全零 status；channel 把它压成一句
/// 固定英文串；Dart 侧连那句串都没读。本文件按层守卫「原因必须活着到达用户」。
void main() {
  group('open 失败 token → 结构化原因 (BUG-1216)', () {
    test('拒绝访问归类成 accessDenied：处置是以管理员运行，不是重启', () {
      expect(
        galHookFailureFromVoiceHookOpenError('access_denied'),
        GalHookInjectorFailure.accessDenied,
      );
    });

    test('契约不符归类成 protocolMismatch：处置是更新 helper，重启永远不会好', () {
      expect(
        galHookFailureFromVoiceHookOpenError('protocol_mismatch'),
        GalHookInjectorFailure.protocolMismatch,
      );
      expect(
        galHookFailureIsRetryable(GalHookInjectorFailure.protocolMismatch),
        isFalse,
        reason: '版本不符重试多少次都一样，不能挂进自动重试链',
      );
    });

    test('映射不存在/MapView 失败/pid 非法：native 没定出处置，交回 stderr 归类', () {
      for (final String token in <String>[
        'mapping_not_found',
        'map_view_failed',
        'mapping_open_failed',
        'invalid_pid',
      ]) {
        expect(
          galHookFailureFromVoiceHookOpenError(token),
          isNull,
          reason: '$token 只说明读侧没找到映射，没说为什么——不能盖掉 injector 的解释',
        );
      }
    });

    test('未知 token / null 不编造更具体的原因', () {
      expect(galHookFailureFromVoiceHookOpenError(null), isNull);
      expect(galHookFailureFromVoiceHookOpenError('what_is_this'), isNull);
    });

    test('native 未定出处置时，injector stderr 的更可执行原因必须活下来', () {
      // 回归守卫：`resolved` 一度对**每个** token 都非空，于是 `mapping_not_found`
      // 这类「只知道映射不在」的出口把 injector stderr 归类整个短路掉——hook DLL 缺失
      // 会被降级成一句通用的「捕获通道无法打开」。那正是 BUG-1216 要消灭的信息丢弃，
      // 只是从 native 的 return 挪到了 Dart 的归类层。
      expect(
        classifyGalHookInjectorFailure(
          'hook DLL not found\nvoice_hook open mapping_not_found win32=2',
          fallback: GalHookInjectorFailure.sharedMemoryUnavailable,
        ),
        GalHookInjectorFailure.hookDllMissing,
      );
      // 而真定出处置的两条不受影响：它们盖过 stderr。
      expect(
        galHookFailureFromVoiceHookOpenError('access_denied'),
        GalHookInjectorFailure.accessDenied,
      );
    });

    test('每个归类都有可执行处置文案（不能落回内部代码）', () {
      for (final GalHookInjectorFailure failure in <GalHookInjectorFailure>[
        GalHookInjectorFailure.accessDenied,
        GalHookInjectorFailure.protocolMismatch,
        GalHookInjectorFailure.sharedMemoryUnavailable,
      ]) {
        expect(galHookFailureLabel(failure), isNotNull, reason: failure.name);
      }
    });

    test('detail 压行保留 token 与 native 事实（win32 码 / 版本对照）', () {
      expect(
        galHookOpenFailureDetail(<Object?, Object?>{
          'error': 'access_denied',
          'detail': r'name=Local\HibikiVoiceHook_1234 win32=5',
        }),
        r'voice_hook open access_denied name=Local\HibikiVoiceHook_1234 win32=5',
      );
      expect(
        galHookOpenFailureDetail(<Object?, Object?>{
          'error': 'protocol_mismatch',
          'detail': 'shm=11/want 12',
        }),
        'voice_hook open protocol_mismatch shm=11/want 12',
      );
      // 没有事实时不编造内容，只保留「哪一步失败」。
      expect(
        galHookOpenFailureDetail(<Object?, Object?>{'error': 'invalid_pid'}),
        'voice_hook open invalid_pid',
      );
    });

    test('带上本次实际用的 helper 架构：两套只更新一套时才分得清', () {
      expect(
        galHookOpenFailureDetail(
          <Object?, Object?>{'error': 'protocol_mismatch'},
          injectorPath: r'C:\App\galgame_helper\x86\hibiki_gal_injector.exe',
        ),
        'voice_hook open protocol_mismatch helper=x86',
      );
      expect(
        galHookHelperArchTag('/opt/galgame_helper/x64/injector'),
        'x64',
      );
      // 认不出来就不猜一个架构出来。
      expect(galHookHelperArchTag(null), '');
      expect(galHookHelperArchTag(''), '');
      expect(galHookHelperArchTag(r'C:\somewhere\injector.exe'), '');
    });
  });

  group('open 失败的一手证据必须走到用户看见的那句话 (BUG-1216)', () {
    const String channelName = 'app.hibiki.reader/voice_hook';

    setUp(TestWidgetsFlutterBinding.ensureInitialized);

    void setHandler(Future<Object?>? Function(MethodCall)? handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(channelName), handler);
    }

    tearDown(() => setHandler(null));

    /// 跑一次「helper 宣告 hooked → app 打开共享内存失败」的真实路径。
    Future<GalHookInjectorDiagnostics> runOpenFailure(
      Map<Object?, Object?> openResponse, {
      String injectorStdout = 'OK hooked pid=4321 mode=attach\n',
    }) async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'hibiki_gal_shm_open_test_',
      );
      final File injector =
          File('${temp.path}${Platform.pathSeparator}fake.exe');
      await injector.writeAsBytes(const <int>[0]);
      final _FakeProcess process = _FakeProcess();

      setHandler((MethodCall call) async {
        switch (call.method) {
          case 'open':
            return openResponse;
          case 'close':
            return null;
        }
        return null;
      });

      final EngineHookGalAudioSource source = EngineHookGalAudioSource(
        targetPid: 4321,
        injectorPath: injector.path,
        processStarter: (String executable, List<String> arguments) async {
          scheduleMicrotask(() {
            process.stdoutController.add(injectorStdout.codeUnits);
          });
          return process;
        },
        readyTimeout: const Duration(milliseconds: 200),
        pollInterval: Duration.zero,
      );
      try {
        expect(await source.start(), isNull);
        return source.lastFailure;
      } finally {
        await source.stop();
        await process.dispose();
        await temp.delete(recursive: true);
      }
    }

    test('拒绝访问：原因是 accessDenied，win32 码进诊断', () async {
      final GalHookInjectorDiagnostics diagnostics =
          await runOpenFailure(<Object?, Object?>{
        'error': 'access_denied',
        'detail': r'name=Local\HibikiVoiceHook_4321 win32=5',
        'win32': 5,
      });
      expect(diagnostics.failure, GalHookInjectorFailure.accessDenied);
      expect(diagnostics.stderrTail, contains('win32=5'));
      expect(
        galHookDiagnosticsDetail(diagnostics),
        contains('access_denied'),
        reason: '诊断末行是读侧结论，必须是它进入文案而不是 injector 的进度行',
      );
    });

    test('契约不符：原因是 protocolMismatch，双方版本进诊断', () async {
      final GalHookInjectorDiagnostics diagnostics =
          await runOpenFailure(<Object?, Object?>{
        'error': 'protocol_mismatch',
        'detail': 'shm=11/want 12 ipc=1/want 2',
        'win32': 0,
      });
      expect(diagnostics.failure, GalHookInjectorFailure.protocolMismatch);
      expect(diagnostics.stderrTail, contains('shm=11/want 12'));
    });

    test('injector 一路全绿时不得用它的 stdout 把确定原因猜回 unknown', () async {
      final GalHookInjectorDiagnostics diagnostics =
          await runOpenFailure(<Object?, Object?>{
        'error': 'mapping_not_found',
        'detail': r'name=Local\HibikiVoiceHook_4321 win32=2',
        'win32': 2,
      });
      expect(
        diagnostics.failure,
        GalHookInjectorFailure.sharedMemoryUnavailable,
      );
      expect(diagnostics.stderrTail, contains('mapping_not_found'));
    });

    test('native 没定出处置时，injector 说出的原因必须一路活到 failure 上', () async {
      // 端到端回归守卫（走真实 _captureFailure 路径）：`mapping_not_found` 不得把
      // injector 的「hook DLL 缺失」短路成通用的 sharedMemoryUnavailable。
      final GalHookInjectorDiagnostics diagnostics = await runOpenFailure(
        <Object?, Object?>{
          'error': 'mapping_not_found',
          'detail': r'name=Local\HibikiVoiceHook_4321 win32=2',
          'win32': 2,
        },
        injectorStdout: 'hook DLL not found\n',
      );
      expect(
        diagnostics.failure,
        GalHookInjectorFailure.hookDllMissing,
        reason: 'native 只知道映射不在，injector 知道为什么——不能被前者盖掉',
      );
    });

    test('归类得出原因时**也**要把 native 证据带给用户', () {
      final GalHookInjectorDiagnostics diagnostics = GalHookInjectorDiagnostics(
        failure: GalHookInjectorFailure.accessDenied,
        stderrTail: 'OK hooked pid=4321\nvoice_hook open access_denied win32=5',
      );
      final String? message = galHookLaunchOutcomeMessage(
        outcome: GalHookLaunchOutcome.failed,
        result: GalHookLaunchResult.failed(
          GalHookLaunchFailureReason.injectionFailed,
          diagnostics: diagnostics,
        ),
        failure: GalHookInjectorFailure.accessDenied,
      );
      expect(message, isNotNull);
      expect(
        message,
        contains('win32=5'),
        reason: 'BUG-1142 只在归类不出来时才附证据，归类得越准信息越少',
      );
      expect(
          message,
          contains(galHookFailureLabel(
            GalHookInjectorFailure.accessDenied,
          )!));
    });

    test('降级路径的证据从会话状态取（result 是 launched，诊断不在它身上）', () {
      final String? message = galHookLaunchOutcomeMessage(
        outcome: GalHookLaunchOutcome.degradedLoopback,
        result: const GalHookLaunchResult.launched(),
        failure: GalHookInjectorFailure.sharedMemoryUnavailable,
        injectorDetail: 'voice_hook open mapping_not_found win32=2',
      );
      expect(message, contains('mapping_not_found'));
    });

    test('没有证据时不生造括号后缀', () {
      final String? message = galHookLaunchOutcomeMessage(
        outcome: GalHookLaunchOutcome.degradedLoopback,
        result: const GalHookLaunchResult.launched(),
        failure: GalHookInjectorFailure.none,
      );
      expect(message, isNot(contains('（')));
    });
  });

  group('native ↔ Dart token 契约守卫 (BUG-1216)', () {
    File resolve(String relative) {
      final File direct = File(relative);
      return direct.existsSync() ? direct : File('hibiki/$relative');
    }

    test('native 为每条 open 出口发机器可读 token，Dart 侧逐个认得', () {
      final String native = maskComments(
        resolve('windows/runner/voice_hook_reader.cpp').readAsStringSync(),
      );
      const List<String> tokens = <String>[
        'invalid_pid',
        'mapping_not_found',
        'access_denied',
        'mapping_open_failed',
        'map_view_failed',
        'protocol_mismatch',
      ];
      for (final String token in tokens) {
        expect(
          native,
          contains('"$token"'),
          reason: 'native 少了 token $token，Dart 侧就归类不出这条出口',
        );
      }
      // access_denied / protocol_mismatch 是**唯二**改变处置的 token：Dart 必须显式认。
      final String dart = maskComments(
        resolve('lib/src/mining/galgame_audio_source.dart').readAsStringSync(),
      );
      expect(dart, contains("'access_denied'"));
      expect(dart, contains("'protocol_mismatch'"));
    });

    test('Open 的每条出口都必须带原因（不认某一种违规写法，认枚举是否齐）', () {
      final String native = maskComments(
        resolve('windows/runner/voice_hook_reader.cpp').readAsStringSync(),
      );
      final int openAt =
          native.indexOf('VoiceHookOpenResult VoiceHookReader::Open');
      expect(openAt, greaterThan(0), reason: 'Open 必须返回结构化结果，不是裸 status');
      final int openEnd = native.indexOf('\n}', openAt);
      expect(openEnd, greaterThan(openAt), reason: '扫不到函数体就判红，别让空集假绿');
      final String body = native.substring(openAt, openEnd);
      // 判据不是「没写某一句违规代码」——`return VoiceHookStatus{}`、
      // `VoiceHookOpenResult r; return r;`、`return {}` 都能达到同样的「丢掉原因」效果。
      // 唯一抗等价改写的判据是：**每条失败出口对应的枚举值都得在函数体里被赋出来**，
      // 少赋一条，那条出口就必然退回「无原因」。
      for (final String error in <String>[
        'kInvalidPid',
        'kMappingNotFound',
        'kAccessDenied',
        'kMappingOpenFailed',
        'kMapViewFailed',
        'kProtocolMismatch',
      ]) {
        expect(
          body,
          contains('VoiceHookOpenError::$error'),
          reason: 'Open 少给一条出口定原因：$error',
        );
      }
      expect(
        body,
        contains('GetLastError'),
        reason: 'win32 码是区分「映射不存在」与「拒绝访问」的唯一事实',
      );
      expect(
        body.contains('return VoiceHookStatus{}'),
        isFalse,
        reason: '原因是在 return 那一刻丢掉的，任何下游文案层补丁都救不回来',
      );
    });

    test('channel 的 open 失败分支必须回 token + detail，不是固定英文串', () {
      final String window = maskComments(
        resolve('windows/runner/flutter_window.cpp').readAsStringSync(),
      );
      final int openAt = window.indexOf('if (method == "open")');
      expect(openAt, greaterThan(0), reason: '扫不到 open 分支就判红，别让空集假绿');
      final int nextMethod = window.indexOf('if (method == "status")', openAt);
      expect(nextMethod, greaterThan(openAt));
      final String branch = window.substring(openAt, nextMethod);
      // 判据不是「没写那一句英文串」——换成任何别的固定串都同样把原因压没了。
      // 抗等价改写的判据是：`"error"` 这个键的值必须**来自** VoiceHookOpenErrorToken。
      final int errorKeyAt = branch.indexOf('EncodableValue("error")');
      expect(errorKeyAt, greaterThan(0), reason: 'open 失败必须回 error 键');
      expect(
        branch.substring(errorKeyAt),
        contains('VoiceHookOpenErrorToken'),
        reason: 'error 的值必须是结构化 token，不能是任何写死的串',
      );
      expect(
        branch,
        contains('"detail"'),
        reason: 'win32 码 / 映射名 / 双方版本这些一手事实必须一起过河',
      );
      expect(
        branch,
        contains('opened.ok()'),
        reason: '失败判据必须是 Open 自己报的 error，不能拿 hooked 位当映射存在的代理',
      );
    });
  });
}

/// 只做「拉起后立刻宣告 hooked」的假 injector 进程。
class _FakeProcess implements Process {
  final StreamController<List<int>> stdoutController =
      StreamController<List<int>>();
  final StreamController<List<int>> stderrController =
      StreamController<List<int>>();
  final Completer<int> _exit = Completer<int>();
  bool killed = false;

  Future<void> dispose() async {
    await stdoutController.close();
    await stderrController.close();
    if (!_exit.isCompleted) _exit.complete(0);
  }

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!_exit.isCompleted) _exit.complete(-1);
    return true;
  }

  @override
  int get pid => 4242;

  @override
  Stream<List<int>> get stderr => stderrController.stream;

  @override
  IOSink get stdin => throw UnimplementedError();

  @override
  Stream<List<int>> get stdout => stdoutController.stream;
}

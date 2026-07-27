import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/gal_hook_failure_text.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';

/// injector 的 `CMakeLists.txt` 无条件加了 MSVC `/utf-8`（同时设 execution-charset），
/// 所以它 stderr 里的中文诊断在二进制里就是 UTF-8 字节。这里从**字节**造输入，而不是
/// 直接写 Dart 字符串字面量——后者已经是「解码正确」的结果，测不出解码环节的错。
List<int> _nativeStderrBytes(String diagnostics) => utf8.encode(diagnostics);

void main() {
  // BUG-1091：injector 输出按系统 ANSI 代码页（中文 Windows = CP936）解码，导致
  // ① 会话事件里 native 诊断显示成乱码；② 更严重的是 classifyGalHookInjectorFailure
  // 靠中文串识别旧 helper 的失败原因，解错码后这些分支永远匹配不上，失败分类永久
  // 退化成 fallback，用户拿不到「位数不符 / 需要管理员 / 缺文件」这类可执行处置。
  group('injector 诊断编码契约是 UTF-8 (BUG-1091)', () {
    // 每条都是 injector 真实会打印的中文诊断（对应 classify 里的中文分支）。
    const Map<String, GalHookInjectorFailure> cases =
        <String, GalHookInjectorFailure>{
      '位数不匹配：目标是 64 位进程，请改用对应 arch 的注入器\n':
          GalHookInjectorFailure.bitnessMismatch,
      '目标 exe 不存在\n': GalHookInjectorFailure.gameExeMissing,
      '已存在但不可复用的 hook 会话\n': GalHookInjectorFailure.staleSession,
      '未收到就绪信号\n': GalHookInjectorFailure.readyTimeout,
      'Steam 已接受启动请求，但目标进程未出现\n': GalHookInjectorFailure.steamTimeout,
    };

    test('按 UTF-8 解码后中文诊断能正确归类', () {
      cases.forEach((String diagnostics, GalHookInjectorFailure expected) {
        final String decoded = const Utf8Decoder(allowMalformed: true)
            .convert(_nativeStderrBytes(diagnostics));
        expect(
          classifyGalHookInjectorFailure(decoded),
          expected,
          reason: '「$diagnostics」按 UTF-8 解码后应归类为 $expected',
        );
      });
    });

    test('按单字节代码页误解码会让中文分支全部失配，退化成 fallback', () {
      // latin1 在所有平台行为一致，用它确定性地模拟「拿单字节代码页解 UTF-8」这类
      // 错误解码（真实故障是中文 Windows 的 CP936）。断言的是「错解码 → 分类丢失」，
      // 这正是本 bug 的伤害面：不是显示难看，而是失败原因彻底消失。
      cases.forEach((String diagnostics, GalHookInjectorFailure expected) {
        final String mojibake = latin1.decode(_nativeStderrBytes(diagnostics));
        expect(mojibake, isNot(contains('位数')));
        expect(
          classifyGalHookInjectorFailure(mojibake),
          GalHookInjectorFailure.unknown,
          reason: '误解码后不应还能命中 $expected —— 若能命中说明本测试没有真的在测解码',
        );
      });
    });

    test('ASCII 诊断（ERR reason= / CreateProcessW）两种解码都不受影响', () {
      // 说明为什么这个 bug 能藏这么久：新 helper 的机器可读行是纯 ASCII，主路径照常
      // 工作，只有旧 helper 的中文兼容路径是死的。
      const String ascii = 'ERR reason=elevationRequired\n';
      expect(
        classifyGalHookInjectorFailure(
          const Utf8Decoder(allowMalformed: true)
              .convert(_nativeStderrBytes(ascii)),
        ),
        GalHookInjectorFailure.elevationRequired,
      );
      expect(
        classifyGalHookInjectorFailure(
            latin1.decode(_nativeStderrBytes(ascii))),
        GalHookInjectorFailure.elevationRequired,
      );
    });

    test('allowMalformed：夹杂非法字节不得抛异常而丢掉整条诊断', () {
      // stderr 里 `%ls` 宽字符经 C locale 转换后可能夹带非法字节，单个坏字节不能让
      // 整条诊断流炸掉——那会连同后面的合法证据一起丢。
      final List<int> bytes = <int>[
        ...utf8.encode('位数不匹配'),
        0xFF, // 非法 UTF-8 起始字节
        0xFE,
        ...utf8.encode('：目标是 64 位进程'),
      ];
      final String decoded =
          const Utf8Decoder(allowMalformed: true).convert(bytes);
      expect(decoded, contains('位数不匹配'));
      expect(
        classifyGalHookInjectorFailure(decoded),
        GalHookInjectorFailure.bitnessMismatch,
      );
    });

    test('源码守卫：injector 输出解码不得回退到 SystemEncoding', () {
      final File source = File('lib/src/mining/galgame_audio_source.dart');
      expect(source.existsSync(), isTrue, reason: '测试须在 hibiki/ 下运行才能读到源码');
      final String code = source.readAsStringSync();
      // 匹配「构造调用」而不是「文字提及」：文件里有一段注释解释本 bug 为什么发生，
      // 会提到 SystemEncoding 这个名字，那是文档不是回归。
      expect(
        RegExp(r'SystemEncoding\s*\(').hasMatch(code),
        isFalse,
        reason: 'injector 用 /utf-8 编译，输出恒为 UTF-8；'
            '用 SystemEncoding() 解码会在中文 Windows 上重现 BUG-1091',
      );
      expect(code, contains('Utf8Decoder(allowMalformed: true)'));
    });
  });

  // BUG-1089：launchGame 返回 bool，把「彻底失败 / 游戏在跑但注入降级 / 完全成功」
  // 三种结果压成两个值，于是每个调用方自己去 state 里翻，翻得还不一样——游戏库页
  // 一个字都不提示。用户点完「启动游戏」既看不到游戏也看不到报错。
  group('classifyGalHookLaunchOutcome (BUG-1089)', () {
    test('launchGame 返回失败结果 → failed', () {
      expect(
        classifyGalHookLaunchOutcome(
          result: const GalHookLaunchResult.failed(
            GalHookLaunchFailureReason.helperMissing,
          ),
          hasBoundWindow: false,
          injectorFailure: GalHookInjectorFailure.helperMissing,
        ),
        GalHookLaunchOutcome.failed,
      );
    });

    test('游戏在跑但窗口从未出现 → windowMissing（现场真实组合）', () {
      // 真机现场：injector 打了 `LAUNCH pid=` 和 `OK hooked`，Dart 侧 30s 握手超时
      // 降级 loopback、launchGame 返回 true，但游戏主线程一直停在挂起态，窗口永不
      // 出现。用户感知就是「点了没反应、游戏没打开」，必须报出来。
      expect(
        classifyGalHookLaunchOutcome(
          result: const GalHookLaunchResult.launched(),
          hasBoundWindow: false,
          injectorFailure: GalHookInjectorFailure.handshakeTimeout,
        ),
        GalHookLaunchOutcome.windowMissing,
      );
    });

    test('windowMissing 优先于 degradedLoopback', () {
      // 两者同时成立时，用户首要感知是「游戏没打开」，不是「音频降级了」。
      expect(
        classifyGalHookLaunchOutcome(
          result: const GalHookLaunchResult.launched(),
          hasBoundWindow: false,
          injectorFailure: GalHookInjectorFailure.injectionFailed,
        ),
        GalHookLaunchOutcome.windowMissing,
      );
    });

    test('有窗口 + 注入失败 → degradedLoopback', () {
      expect(
        classifyGalHookLaunchOutcome(
          result: const GalHookLaunchResult.launched(),
          hasBoundWindow: true,
          injectorFailure: GalHookInjectorFailure.injectionFailed,
        ),
        GalHookLaunchOutcome.degradedLoopback,
      );
    });

    test('文本 hook 就绪（injectorFailure=none）+ 有窗口 → running，不误报降级', () {
      // _activateTextWithLoopback 同样把 phase 设成 degraded，但显式把 injectorFailure
      // 清成 none：那是「有台词、音频用混音兜底」的可接受模式。判据用 injectorFailure
      // 而不是 phase，就是为了不拿这个去烦用户。
      expect(
        classifyGalHookLaunchOutcome(
          result: const GalHookLaunchResult.launched(),
          hasBoundWindow: true,
          injectorFailure: GalHookInjectorFailure.none,
        ),
        GalHookLaunchOutcome.running,
      );
    });

    test('全部失败原因都有确定分级，不留未定义组合', () {
      for (final GalHookInjectorFailure failure
          in GalHookInjectorFailure.values) {
        for (final bool hasWindow in <bool>[true, false]) {
          final GalHookLaunchOutcome outcome = classifyGalHookLaunchOutcome(
            result: const GalHookLaunchResult.launched(),
            hasBoundWindow: hasWindow,
            injectorFailure: failure,
          );
          if (!hasWindow) {
            expect(outcome, GalHookLaunchOutcome.windowMissing);
          } else {
            expect(
              outcome,
              failure == GalHookInjectorFailure.none
                  ? GalHookLaunchOutcome.running
                  : GalHookLaunchOutcome.degradedLoopback,
            );
          }
        }
      }
    });
  });

  // BUG-1138：launchGame 曾返回 `bool`，五条 `return false` 出口里有四条**不带任何
  // 原因**（会话被抢占那几条连 state 都不碰）。UI 只能事后去 state 里翻，翻到
  // `injectorFailure == none` + `lastError == null`，于是甩给用户一句「游戏启动或捕获
  // 失败」——零可执行信息。原因是在 `return false` 那一刻丢的，下游补丁救不回来
  // （下游只拿得到一个比特），所以修在返回类型上。
  group('启动失败必须带原因 (BUG-1138)', () {
    test('失败结果不允许把原因留空', () {
      expect(
        () => GalHookLaunchResult.failed(GalHookLaunchFailureReason.none),
        throwsA(isA<AssertionError>()),
        reason: '「没有原因的失败」正是本 bug 的形态，必须在构造处就挡掉',
      );
    });

    test('被取代的启动 → superseded，且不播报任何文案', () {
      const GalHookLaunchResult result = GalHookLaunchResult.failed(
        GalHookLaunchFailureReason.superseded,
      );
      final GalHookLaunchOutcome outcome = classifyGalHookLaunchOutcome(
        result: result,
        hasBoundWindow: false,
        injectorFailure: GalHookInjectorFailure.none,
      );
      expect(outcome, GalHookLaunchOutcome.superseded);
      expect(
        galHookLaunchOutcomeMessage(
          outcome: outcome,
          result: result,
          failure: GalHookInjectorFailure.none,
        ),
        isNull,
        reason: '取代它的那次操作会播报自己的结果；这里再弹一句会把真实结局盖掉',
      );
    });

    test('每个失败原因都有确定分级，不留未定义组合', () {
      for (final GalHookLaunchFailureReason reason
          in GalHookLaunchFailureReason.values) {
        if (reason == GalHookLaunchFailureReason.none) continue;
        expect(
          classifyGalHookLaunchOutcome(
            result: GalHookLaunchResult.failed(reason),
            hasBoundWindow: false,
            injectorFailure: GalHookInjectorFailure.none,
          ),
          reason == GalHookLaunchFailureReason.superseded
              ? GalHookLaunchOutcome.superseded
              : GalHookLaunchOutcome.failed,
          reason: '$reason 必须有确定分级',
        );
      }
    });

    // 本组的核心断言：即便 injector 诊断归类不出来（unknown），native 的一手证据也
    // 必须到达用户。旧实现在这条路径上只剩一句兜底文案，stderr 尾部停在 controller
    // 内部——用户无法自愈，报障时也提供不出线索。
    test('归类不出来时，native 诊断必须进入文案', () {
      const GalHookLaunchResult result = GalHookLaunchResult.failed(
        GalHookLaunchFailureReason.injectionFailed,
        diagnostics: GalHookInjectorDiagnostics(
          failure: GalHookInjectorFailure.unknown,
          exitCode: 3,
          stderrTail: '[luna] LunaHook32.dll 已注入 pid=1234，等待连接...\n'
              'engine bootstrap aborted: unexpected module layout',
        ),
      );
      final String? message = galHookLaunchOutcomeMessage(
        outcome: GalHookLaunchOutcome.failed,
        result: result,
        failure: GalHookInjectorFailure.unknown,
      );
      expect(message, isNotNull);
      expect(message, contains('exit=3'));
      expect(message, contains('engine bootstrap aborted'));
    });

    test('诊断摘要取 stderr 最后一行结论，不是中途进度', () {
      const GalHookInjectorDiagnostics diagnostics = GalHookInjectorDiagnostics(
        failure: GalHookInjectorFailure.unknown,
        exitCode: 1,
        stderrTail: '[luna] connected pid=1\n\n  final failure line  \n',
      );
      final String detail = galHookDiagnosticsDetail(diagnostics);
      expect(detail, 'exit=1 final failure line');
      expect(detail, isNot(contains('connected')));
    });

    test('没有任何诊断时不编造原因，只给兜底文案', () {
      const GalHookLaunchResult result = GalHookLaunchResult.failed(
        GalHookLaunchFailureReason.injectionFailed,
      );
      final String? message = galHookLaunchOutcomeMessage(
        outcome: GalHookLaunchOutcome.failed,
        result: result,
        failure: GalHookInjectorFailure.unknown,
      );
      expect(message, isNotNull);
      expect(message, isNot(contains('exit=')));
    });

    test('源码守卫：launchGame 不得退回 bool 返回值', () {
      final File source =
          File('lib/src/mining/gal_hook_session_controller.dart');
      expect(source.existsSync(), isTrue, reason: '测试须在 hibiki/ 下运行才能读到源码');
      final String code = source.readAsStringSync();
      expect(
        code.contains('Future<GalHookLaunchResult> launchGame('),
        isTrue,
        reason: '返回 bool 会让失败原因重新在 return 处丢失（BUG-1138 根因）',
      );
      expect(
        RegExp(r'Future<bool>\s+launchGame\(').hasMatch(code),
        isFalse,
        reason: 'bool 返回值把五种失败压成一个比特，正是本 bug 的根因',
      );
    });
  });
}

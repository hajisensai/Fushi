import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/galgame_japanese_locale.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/sync/texthooker_ws_client.dart';

/// 转区（日文区域 / CP932）必须是**会话里看得见的事实**，而不是只存在于 injector 命令行。
///
/// 背景：`auto` 的判据是「系统 ANSI 代码页 ≠ 932 且目标 exe 是 32 位」。中文系统
/// （ACP=936）上跑任何 32 位 galgame 都会命中它——包括自带多语言的版本和汉化版，而
/// 那些游戏的字符串本来就不是 Shift-JIS，套 CP932 反而会解坏（窗口标题乱码、脚本
/// 加载失败）。[resolveJapaneseLocale] 的注释已经承认 `auto` 不可能总判对、真正兜底
/// 的是用户手动选 [GalJapaneseLocaleMode.off]；但用户在设置页只看得到「自动」，
/// 出问题时没有任何线索指向转区。这组测试锁住「本局到底转没转」这条信息的通路。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('resolveJapaneseLocale auto 判据（锁定现状，说明误伤从哪来）', () {
    test('中文系统 + 32 位目标 => 自动转区（多语言版/汉化版正是落在这一格）', () {
      expect(
        resolveJapaneseLocale(
          mode: GalJapaneseLocaleMode.auto,
          launchMode: true,
          is32Bit: true,
          systemAnsiCodePage: 936,
        ),
        isTrue,
      );
    });

    test('日文系统 => 不转区（本来就是 932，转了纯属有害无益）', () {
      expect(
        resolveJapaneseLocale(
          mode: GalJapaneseLocaleMode.auto,
          launchMode: true,
          is32Bit: true,
          systemAnsiCodePage: 932,
        ),
        isFalse,
      );
    });

    test('off 是用户兜底档：任何情况下都不转区', () {
      expect(
        resolveJapaneseLocale(
          mode: GalJapaneseLocaleMode.off,
          launchMode: true,
          is32Bit: true,
          systemAnsiCodePage: 936,
        ),
        isFalse,
      );
    });

    test('attach 模式必然短路：进程早已存在，改不了它的区域', () {
      expect(
        resolveJapaneseLocale(
          mode: GalJapaneseLocaleMode.on,
          launchMode: false,
          is32Bit: true,
          systemAnsiCodePage: 936,
        ),
        isFalse,
      );
    });
  });

  test('转区的会话：状态置位并记一条事件', () async {
    final _LocaleHarness harness = _LocaleHarness(localeApplied: true);
    final GalHookSessionController controller = harness.build();

    expect(
      (await controller.launchGame(r'D:\game\tenshi.exe')).launched,
      isTrue,
    );

    expect(
      controller.state.japaneseLocaleApplied,
      isTrue,
      reason: '会话状态必须带上本局真的转了区，UI 才有东西可显示',
    );
    expect(
      controller.events.map((GalHookEvent event) => event.code),
      contains('launch.japanese_locale_applied'),
      reason: '诊断里也要留痕，事后排障不必去猜 injector 命令行',
    );

    await harness.dispose(controller);
  });

  test('未转区的会话：不置位、也不记事件', () async {
    final _LocaleHarness harness = _LocaleHarness(localeApplied: false);
    final GalHookSessionController controller = harness.build();

    expect(
      (await controller.launchGame(r'D:\game\tenshi.exe')).launched,
      isTrue,
    );

    expect(controller.state.japaneseLocaleApplied, isFalse);
    expect(
      controller.events.map((GalHookEvent event) => event.code),
      isNot(contains('launch.japanese_locale_applied')),
      reason: '没转区还报「已转区」会把用户引到错误的排查方向',
    );

    await harness.dispose(controller);
  });

  test('会话停止后标记复位，不残留到下一局', () async {
    final _LocaleHarness harness = _LocaleHarness(localeApplied: true);
    final GalHookSessionController controller = harness.build();

    await controller.launchGame(r'D:\game\tenshi.exe');
    expect(controller.state.japaneseLocaleApplied, isTrue);

    await controller.stopCapture();

    expect(
      controller.state.japaneseLocaleApplied,
      isFalse,
      reason: '空闲状态还挂着上一局的「已转区」会让下一局的排查从错误前提开始',
    );

    await harness.dispose(controller);
  });

  test('copyWith：clearLaunchExe 复位转区标记（两者同属 launch 会话）', () {
    const GalHookSessionState applied =
        GalHookSessionState(japaneseLocaleApplied: true);

    expect(
        applied.copyWith(clearLaunchExe: true).japaneseLocaleApplied, isFalse);
    // 不清 launchExe 时保持原值，避免顺手把无关的 copyWith 也复位掉。
    expect(
        applied
            .copyWith(phase: GalHookSessionPhase.running)
            .japaneseLocaleApplied,
        isTrue);
  });
}

/// 把会话控制器的构造/清理收在一处，避免每个用例重复十几行替身接线。
class _LocaleHarness {
  _LocaleHarness({required this.localeApplied});

  final bool localeApplied;
  final TexthookerService service = TexthookerService.test();
  final ChangeNotifier endpoints = ChangeNotifier();

  GalHookSessionController build() {
    final _LocaleEngine engine = _LocaleEngine(localeApplied: localeApplied);
    return GalHookSessionController(
      textService: service,
      isWindows: true,
      exe32BitProbe: (_) async => true,
      injectorResolver: ({required bool is32Bit}) => 'injector.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
        List<String> launchArguments = const <String>[],
        String launchWorkdir = '',
        GalJapaneseLocaleMode japaneseLocaleMode =
            kGalDefaultJapaneseLocaleMode,
      }) =>
          engine,
      loopbackSourceFactory: _NoopLoopback.new,
      windowListLoader: () async => const <ExternalWindowInfo>[],
      windowPollAttempts: 1,
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );
  }

  Future<void> dispose(GalHookSessionController controller) async {
    await controller.close();
    endpoints.dispose();
  }
}

/// 只回答一个问题的引擎替身：本局转没转区。其余走基类默认，不引入额外行为。
class _LocaleEngine extends EngineHookGalAudioSource {
  _LocaleEngine({required this.localeApplied})
      : super(targetPid: 0, launchExe: 'fake.exe', injectorPath: 'fake.exe');

  final bool localeApplied;

  @override
  bool get japaneseLocaleApplied => localeApplied;

  @override
  int? get gamePid => 4242;

  @override
  bool get textHookReady => true;

  @override
  Future<PcmFormat?> start() async => const PcmFormat(
        sampleRate: 44100,
        channels: 1,
        bitsPerSample: 16,
        isFloat: false,
      );

  @override
  Future<void> stop() async {}
}

class _NoopLoopback extends LoopbackGalAudioSource {
  @override
  Future<PcmFormat?> start() async => null;

  @override
  Future<void> stop() async {}
}

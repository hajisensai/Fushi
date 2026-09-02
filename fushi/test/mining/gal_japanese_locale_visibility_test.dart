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
/// 背景：`auto` 以前的判据是「系统 ANSI 代码页 ≠ 932 且目标 exe 是 32 位」。中文系统
/// （ACP=936）上跑任何 32 位 galgame 都会命中它——包括自带多语言的版本和汉化版，而
/// 那些游戏的字符串本来就不是 Shift-JIS，套 CP932 反而会解坏（窗口标题乱码、脚本
/// 加载失败）。BUG-1691 让「本局到底转没转」进了会话状态；BUG-2047 把判据改成证据
/// 驱动的三态，于是「凭什么转 / 为什么没转」也必须一起进状态与事件，用户才够得着
/// `on` / `off` 两头的兜底。这组测试锁住这条信息通路。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('resolveJapaneseLocale auto 判据', () {
    test('判为需要 + 中文系统 + 32 位目标 => 转区', () {
      expect(
        resolveJapaneseLocale(
          mode: GalJapaneseLocaleMode.auto,
          launchMode: true,
          is32Bit: true,
          systemAnsiCodePage: 936,
          need: GalJapaneseLocaleNeed.needed,
        ),
        isTrue,
      );
    });

    test('证据不足 + 中文系统 + 32 位目标 => 不转区（BUG-2047：不再全转）', () {
      expect(
        resolveJapaneseLocale(
          mode: GalJapaneseLocaleMode.auto,
          launchMode: true,
          is32Bit: true,
          systemAnsiCodePage: 936,
        ),
        isFalse,
        reason: '多语言版 / 汉化版以前正是落在「32 位 ⇒ 转」这一格被误伤',
      );
    });

    test('日文系统 => 不转区（本来就是 932，转了纯属有害无益）', () {
      expect(
        resolveJapaneseLocale(
          mode: GalJapaneseLocaleMode.auto,
          launchMode: true,
          is32Bit: true,
          systemAnsiCodePage: 932,
          need: GalJapaneseLocaleNeed.needed,
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
          need: GalJapaneseLocaleNeed.needed,
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

  const GalJapaneseLocaleVerdict needed = GalJapaneseLocaleVerdict(
    need: GalJapaneseLocaleNeed.needed,
    evidence: <GalJapaneseLocaleEvidence>[
      GalJapaneseLocaleEvidence.versionInfoJapanese,
      GalJapaneseLocaleEvidence.exeShiftJisStrings,
    ],
  );
  const GalJapaneseLocaleVerdict notNeeded = GalJapaneseLocaleVerdict(
    need: GalJapaneseLocaleNeed.notNeeded,
    evidence: <GalJapaneseLocaleEvidence>[
      GalJapaneseLocaleEvidence.dirFileNameChinesePatch,
    ],
  );

  test('转区的会话：状态置位、判定入状态、事件带 need 与证据 key', () async {
    final _LocaleHarness harness = _LocaleHarness(
      localeApplied: true,
      verdict: needed,
    );
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
      controller.state.japaneseLocaleVerdict,
      same(needed),
      reason: '判据与「转没转」同源：UI 列的证据必须就是算出 --japanese-locale 的那份',
    );
    final GalHookEvent event = controller.events.firstWhere(
      (GalHookEvent event) => event.code == 'launch.japanese_locale_applied',
      orElse: () => throw StateError('缺 launch.japanese_locale_applied 事件'),
    );
    expect(event.details['mode'], 'auto');
    expect(event.details['need'], 'needed');
    expect(event.details['evidence'], <String>[
      'version_info_japanese',
      'exe_shift_jis_strings',
    ], reason: '事件里用稳定字面量 key，不用 enum.name/index');
    expect(
      controller.events.map((GalHookEvent event) => event.code),
      isNot(contains('launch.japanese_locale_skipped')),
    );

    await harness.dispose(controller);
  });

  test('auto 判为不需要而未转区：不置位、记 skipped 事件、判定入状态', () async {
    final _LocaleHarness harness = _LocaleHarness(
      localeApplied: false,
      verdict: notNeeded,
    );
    final GalHookSessionController controller = harness.build();

    expect(
      (await controller.launchGame(r'D:\game\tenshi.exe')).launched,
      isTrue,
    );

    expect(controller.state.japaneseLocaleApplied, isFalse);
    expect(controller.state.japaneseLocaleVerdict, same(notNeeded));
    expect(
      controller.events.map((GalHookEvent event) => event.code),
      isNot(contains('launch.japanese_locale_applied')),
      reason: '没转区还报「已转区」会把用户引到错误的排查方向',
    );
    final GalHookEvent event = controller.events.firstWhere(
      (GalHookEvent event) => event.code == 'launch.japanese_locale_skipped',
      orElse: () => throw StateError('缺 launch.japanese_locale_skipped 事件'),
    );
    expect(event.details['need'], 'not_needed');
    expect(event.details['evidence'], <String>[
      'dir_file_name_chinese_patch',
    ], reason: '事后排障得看到「当时为什么没转」');

    await harness.dispose(controller);
  });

  test('auto 证据不足而未转区：skipped 事件 need=unknown、证据为空', () async {
    final _LocaleHarness harness = _LocaleHarness(
      localeApplied: false,
      verdict: GalJapaneseLocaleVerdict.unknown,
    );
    final GalHookSessionController controller = harness.build();

    await controller.launchGame(r'D:\game\tenshi.exe');

    final GalHookEvent event = controller.events.firstWhere(
      (GalHookEvent event) => event.code == 'launch.japanese_locale_skipped',
      orElse: () => throw StateError('缺 launch.japanese_locale_skipped 事件'),
    );
    expect(event.details['need'], 'unknown');
    expect(event.details['evidence'], isEmpty);
    expect(
      controller.state.japaneseLocaleVerdict?.need,
      GalJapaneseLocaleNeed.unknown,
    );

    await harness.dispose(controller);
  });

  test('没有判定（on / off / attach）的未转区会话：不置位、不记任何转区事件', () async {
    final _LocaleHarness harness = _LocaleHarness(
      localeApplied: false,
      verdict: null,
    );
    final GalHookSessionController controller = harness.build();

    expect(
      (await controller.launchGame(
        r'D:\game\tenshi.exe',
        japaneseLocaleMode: GalJapaneseLocaleMode.off,
      )).launched,
      isTrue,
    );

    expect(controller.state.japaneseLocaleApplied, isFalse);
    expect(controller.state.japaneseLocaleVerdict, isNull);
    expect(
      controller.events.map((GalHookEvent event) => event.code),
      isNot(contains('launch.japanese_locale_applied')),
    );
    expect(
      controller.events.map((GalHookEvent event) => event.code),
      isNot(contains('launch.japanese_locale_skipped')),
      reason: '用户选了 off 不是「自动判定跳过」，不该假装有一份判定',
    );

    await harness.dispose(controller);
  });

  test('会话停止后标记与判定复位，不残留到下一局', () async {
    final _LocaleHarness harness = _LocaleHarness(
      localeApplied: true,
      verdict: needed,
    );
    final GalHookSessionController controller = harness.build();

    await controller.launchGame(r'D:\game\tenshi.exe');
    expect(controller.state.japaneseLocaleApplied, isTrue);
    expect(controller.state.japaneseLocaleVerdict, isNotNull);

    await controller.stopCapture();

    expect(
      controller.state.japaneseLocaleApplied,
      isFalse,
      reason: '空闲状态还挂着上一局的「已转区」会让下一局的排查从错误前提开始',
    );
    expect(controller.state.japaneseLocaleVerdict, isNull);

    await harness.dispose(controller);
  });

  test('copyWith：clearLaunchExe 一并复位转区标记与判定（同属 launch 会话）', () {
    const GalHookSessionState applied = GalHookSessionState(
      japaneseLocaleApplied: true,
      japaneseLocaleVerdict: needed,
    );

    final GalHookSessionState cleared = applied.copyWith(clearLaunchExe: true);
    expect(cleared.japaneseLocaleApplied, isFalse);
    expect(cleared.japaneseLocaleVerdict, isNull);
    // 不清 launchExe 时保持原值，避免顺手把无关的 copyWith 也复位掉。
    final GalHookSessionState kept = applied.copyWith(
      phase: GalHookSessionPhase.running,
    );
    expect(kept.japaneseLocaleApplied, isTrue);
    expect(kept.japaneseLocaleVerdict, same(needed));
    // 显式清判定（新一局没有判定时）不碰 launchExe。
    expect(
      applied.copyWith(clearJapaneseLocaleVerdict: true).japaneseLocaleVerdict,
      isNull,
    );
  });
}

/// 把会话控制器的构造/清理收在一处，避免每个用例重复十几行替身接线。
class _LocaleHarness {
  _LocaleHarness({required this.localeApplied, required this.verdict});

  final bool localeApplied;
  final GalJapaneseLocaleVerdict? verdict;
  final TexthookerService service = TexthookerService.test();
  final ChangeNotifier endpoints = ChangeNotifier();

  GalHookSessionController build() {
    final _LocaleEngine engine = _LocaleEngine(
      localeApplied: localeApplied,
      verdict: verdict,
    );
    return GalHookSessionController(
      textService: service,
      isWindows: true,
      exe32BitProbe: (_) async => true,
      injectorResolver: ({required bool is32Bit}) async => 'injector.exe',
      engineSourceFactory:
          ({
            required int targetPid,
            required String? launchExe,
            required String injectorPath,
            required bool lunaPcHooks,
            int? lunaCodepage,
            List<String> launchArguments = const <String>[],
            String launchWorkdir = '',
            GalJapaneseLocaleMode japaneseLocaleMode =
                kGalDefaultJapaneseLocaleMode,
            String? contentLanguage,
          }) => engine,
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

/// 只回答两个问题的引擎替身：本局转没转区、判定是什么。其余走基类默认。
class _LocaleEngine extends EngineHookGalAudioSource {
  _LocaleEngine({required this.localeApplied, required this.verdict})
    : super(targetPid: 0, launchExe: 'fake.exe', injectorPath: 'fake.exe');

  final bool localeApplied;
  final GalJapaneseLocaleVerdict? verdict;

  @override
  bool get japaneseLocaleApplied => localeApplied;

  @override
  GalJapaneseLocaleVerdict? get japaneseLocaleVerdict => verdict;

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

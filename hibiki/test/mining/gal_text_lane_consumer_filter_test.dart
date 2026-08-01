import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/mining/galgame_audio_encode.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/src/sync/texthooker_ws_client.dart';

/// IPC v13 消费期线程过滤守卫。
///
/// v13 把文本区改成按线程分道后，native 采集期**不再丢任何行**（每条线程写自己那条道，
/// 逐字重绘型 hook 物理上挤不掉别人的行）。代价是「只喂选定线程」这件事必须由消费方做，
/// 而这一步一旦做得和旧的 native 门控不等价，就是 BUG-1159 换个地方复发：
///
/// * 只按 threadId 精确匹配 → 同一 hook 面换了调用点（ctx 变）就整段台词消失；
/// * 不过滤 → 工作台被所有 hook 线程的文本灌满，配对也会拿错行。
///
/// 所以这里逐条钉死等价判据：未选定不放行、精确命中放行、同 hook 面放行、别的面不放行。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  GalHookSessionController build({
    required TexthookerService service,
    required Listenable endpoints,
    required EngineHookGalAudioSource engine,
  }) =>
      GalHookSessionController(
        textService: service,
        isWindows: true,
        targetWow64Probe: (_) async => false,
        injectorResolver: ({required bool is32Bit}) => 'injector.exe',
        engineSourceFactory: ({
          required int targetPid,
          required String? launchExe,
          required String injectorPath,
          required bool lunaPcHooks,
          int? lunaCodepage,
          List<String> launchArguments = const <String>[],
          String launchWorkdir = '',
        }) =>
            engine,
        textPollInterval: const Duration(milliseconds: 5),
        endpointListenable: endpoints,
        endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
      );

  Future<List<String>> run({
    required List<GalHookedLine> lines,
    required int? selectThreadId,
  }) async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final _LaneEngine engine = _LaneEngine(lines: lines);
    final GalHookSessionController controller =
        build(service: service, endpoints: endpoints, engine: engine);
    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 21, pid: 555, title: 'lane game'),
    );
    if (selectThreadId != null) {
      await controller.selectTextThread(selectThreadId);
    }
    // 轮询是定时的；给它足够的轮次把 lines 消费完（不依赖具体条数，只等到稳定）。
    for (int i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final List<String> texts =
        service.entries.map((TexthookerLineEntry e) => e.text).toList();
    await controller.close();
    endpoints.dispose();
    return texts;
  }

  // 同一 hook 面（face 相同）在不同剧情分支下 ctx 变化，thread_id 随之变——这正是
  // BUG-1159 的现场：真机上 textseq83 之后连续 16 句语音全都没有对应文本。
  const int kFace = 0xABCDEF;
  const List<GalHookedLine> kLines = <GalHookedLine>[
    GalHookedLine(
      seq: 1,
      timestampMs: 1000,
      text: '選定スレッドの台詞',
      threadId: 5,
      faceId: kFace,
      hookName: 'EmbedKrkrZ',
    ),
    GalHookedLine(
      seq: 2,
      timestampMs: 1100,
      text: 'メニュー用スレッドの文字',
      threadId: 77,
      faceId: 0x999999,
      hookName: 'TextRender',
    ),
    GalHookedLine(
      seq: 3,
      timestampMs: 1200,
      text: '同じフックの別呼び出し点',
      threadId: 6, // ctx 变 → thread_id 变，但 face 不变
      faceId: kFace,
      hookName: 'EmbedKrkrZ',
    ),
  ];

  test('未选定线程时一行都不喂（与 v12 起的 UX 一致，由预览区引导用户先挑）', () async {
    expect(await run(lines: kLines, selectThreadId: null), isEmpty);
  });

  test('只喂选定线程的行：别的线程即便同时在写，也不进工作台', () async {
    final List<String> texts = await run(lines: kLines, selectThreadId: 5);
    expect(texts, contains('選定スレッドの台詞'));
    expect(
      texts,
      isNot(contains('メニュー用スレッドの文字')),
      reason: 'v13 native 会把每条线程的行都送上来，消费期不过滤就会被灌满',
    );
  });

  test('同一 hook 面的兄弟线程照样放行（BUG-1159：ctx 一变 threadId 就变）', () async {
    final List<String> texts = await run(lines: kLines, selectThreadId: 5);
    expect(
      texts,
      contains('同じフックの別呼び出し点'),
      reason: '只按 threadId 精确匹配的话，这一句连同它后面整段台词都会被静默丢掉',
    );
  });

  test('换线程后把它此前留在自己那条道里的历史行补回来（v13 分道的直接收益）', () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final _LaneEngine engine = _LaneEngine(lines: kLines);
    final GalHookSessionController controller =
        build(service: service, endpoints: endpoints, engine: engine);
    await controller.startAttachedCapture(
      const ExternalWindowInfo(hwnd: 22, pid: 556, title: 'lane game'),
    );
    // 先什么都不选：这几行在 v12 会被 native 直接丢掉，v13 则进了各自的道。
    for (int i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(service.entries, isEmpty, reason: '未选定线程时不该有任何行进工作台');

    // 用户这时才挑中那条线程——漏掉的台词必须回得来，而不是要求他重打一遍剧情。
    await controller.selectTextThread(5);
    final List<String> texts =
        service.entries.map((TexthookerLineEntry e) => e.text).toList();
    expect(texts, contains('選定スレッドの台詞'));
    expect(texts, contains('同じフックの別呼び出し点'));
    expect(texts, isNot(contains('メニュー用スレッドの文字')),
        reason: '回捞只捞选定线程那条道，不是把所有道倒进来');
    await controller.close();
    endpoints.dispose();
  });

  test('face 为 0（GDI/Unity 等写者不提供）时退回精确匹配，不误放别的线程', () async {
    const List<GalHookedLine> lines = <GalHookedLine>[
      GalHookedLine(
        seq: 1,
        timestampMs: 1000,
        text: '選定スレッド',
        threadId: 5,
        hookName: 'TextRender',
      ),
      GalHookedLine(
        seq: 2,
        timestampMs: 1100,
        text: '別スレッド',
        threadId: 88,
        hookName: 'TextRender',
      ),
    ];
    final List<String> texts = await run(lines: lines, selectThreadId: 5);
    expect(texts, contains('選定スレッド'));
    expect(texts, isNot(contains('別スレッド')), reason: 'face 都是 0，不能因此互相放行');
  });
}

/// 只回一批固定文本行的桩引擎：本测试只关心「哪些行会被消费」。
class _LaneEngine extends EngineHookGalAudioSource {
  _LaneEngine({required this.lines})
      : super(targetPid: 0, launchExe: null, injectorPath: 'fake.exe');

  final List<GalHookedLine> lines;
  int _pollCalls = 0;

  @override
  int? get gamePid => 4242;

  @override
  Future<PcmFormat?> start() async => const PcmFormat(
        sampleRate: 44100,
        channels: 1,
        bitsPerSample: 16,
        isFloat: false,
      );

  @override
  Future<void> stop() async {}

  @override
  Future<bool> refreshReadiness() async => true;

  @override
  bool get textHookReady => true;

  @override
  Future<GalTextPoll?> pollText(int sinceSeq) async {
    // 真实 native 的语义：游标之后的新行按序交付；游标传 0 时把**各道里仍留着的**行
    // 全给出来（分道保留历史，正是换线程后能回捞的原因）。
    if (sinceSeq == 0) {
      return GalTextPoll(count: lines.length, lines: lines);
    }
    _pollCalls++;
    return GalTextPoll(
      count: lines.length,
      lines: _pollCalls == 1 ? lines : const <GalHookedLine>[],
    );
  }

  @override
  Future<bool> selectTextThread(int? threadId) async => true;

  @override
  Future<GalAudioSlice?> grabRecent(int backMs) async => null;
}

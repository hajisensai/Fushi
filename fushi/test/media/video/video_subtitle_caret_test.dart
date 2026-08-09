import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_player_shortcuts.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi_audio/fushi_audio.dart';

import '../../pages/video_fushi_page_source_corpus.dart';

/// videoEnterCaret：视频页手柄/键盘字级选词查词（用户诉求「视频支持手柄查词」——
/// 此前唯一非鼠标查词入口是 Shift+指针位置，纯手柄下完全无法查词）。
///
/// 分四层验证：
///  ① 纯移动函数 [moveSubtitleCaretEntry]（几何行移/跳行/跳过模糊/边界原地）；
///  ② overlay 真行为——caretEntryIndex 画光标环、模糊字符不画、caret 视图绑定
///     （entryCount / hitAt / anchorEntry 主字幕优先）；
///  ③ 键盘接管纯函数 [guardVideoShortcutsWithSubtitleCaret]（激活期无修饰方向键
///     改走光标、Ctrl 组合键放行、未激活零变化）；
///  ④ 默认键位——videoEnterCaret 桌面默认 Enter + 手柄 Select；
///  ⑤ [SubtitleCaretPauseTracker]「暂停→再播放」迁移（外部恢复播放自动退光标）。
/// 截取 [source] 中 [start] 标记到 [end] 标记之间的源码片段（含 [start]、不含 [end]）。
String _sliceSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}

AudioCue _cue(String text, int startMs, int endMs) => AudioCue()
  ..bookKey = 'b'
  ..chapterHref = 'ch'
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = text
  ..startMs = startMs
  ..endMs = endMs
  ..audioFileIndex = 0;

void main() {
  group('① moveSubtitleCaretEntry 纯移动', () {
    // 两行×3 字的规则网格：行内左右、跨行上下。
    final List<Rect> grid = <Rect>[
      const Rect.fromLTWH(0, 0, 10, 10),
      const Rect.fromLTWH(12, 0, 10, 10),
      const Rect.fromLTWH(24, 0, 10, 10),
      const Rect.fromLTWH(0, 14, 10, 10),
      const Rect.fromLTWH(12, 14, 10, 10),
      const Rect.fromLTWH(24, 14, 10, 10),
    ];

    test('行内右移/左移取水平紧邻字符', () {
      expect(moveSubtitleCaretEntry(grid, 0, SubtitleCaretMove.right), 1);
      expect(moveSubtitleCaretEntry(grid, 1, SubtitleCaretMove.left), 0);
    });

    test('行尽头原地不动（不绕圈、不消失）', () {
      expect(moveSubtitleCaretEntry(grid, 2, SubtitleCaretMove.right), 2);
      expect(moveSubtitleCaretEntry(grid, 0, SubtitleCaretMove.left), 0);
    });

    test('上下取最近行内水平中心最近字符', () {
      expect(moveSubtitleCaretEntry(grid, 1, SubtitleCaretMove.down), 4);
      expect(moveSubtitleCaretEntry(grid, 5, SubtitleCaretMove.up), 2);
    });

    test('顶行再上 / 底行再下原地不动', () {
      expect(moveSubtitleCaretEntry(grid, 1, SubtitleCaretMove.up), 1);
      expect(moveSubtitleCaretEntry(grid, 4, SubtitleCaretMove.down), 4);
    });

    test('模糊字符（Rect.zero）恒被跳过', () {
      final List<Rect> rects = <Rect>[
        const Rect.fromLTWH(0, 0, 10, 10),
        Rect.zero, // 模糊：右移必须跳过它落到下一个可见字符
        const Rect.fromLTWH(24, 0, 10, 10),
      ];
      expect(moveSubtitleCaretEntry(rects, 0, SubtitleCaretMove.right), 2);
    });

    test('非法输入原地不动', () {
      expect(moveSubtitleCaretEntry(grid, -1, SubtitleCaretMove.right), -1);
      expect(moveSubtitleCaretEntry(<Rect>[], 0, SubtitleCaretMove.right), 0);
    });
  });

  group('② overlay 光标环 + caret 视图绑定', () {
    Future<VideoSubtitleHitTester> pumpWithCaret(
      WidgetTester tester, {
      int? caretEntryIndex,
      bool blurEnabled = false,
      bool withSecondary = false,
    }) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue('あいう', 0, 6000)]);
      if (withSecondary) {
        c.setSecondaryCues(<AudioCue>[_cue('xy', 0, 6000)]);
      }
      c.debugUpdateCueForPosition(1000);
      final VideoSubtitleHitTester hitTester = VideoSubtitleHitTester();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: VideoSubtitleOverlay(
            controller: c,
            hitTester: hitTester,
            caretEntryIndex: caretEntryIndex,
            blurEnabled: blurEnabled,
          ),
        ),
      ));
      await tester.pump();
      return hitTester;
    }

    Finder caretRing() => find.byWidgetPredicate((Widget w) =>
        w is Container &&
        w.foregroundDecoration is BoxDecoration &&
        (w.foregroundDecoration as BoxDecoration?)?.border != null);

    testWidgets('caretEntryIndex 命中字符画光标环；null 不画', (tester) async {
      await pumpWithCaret(tester, caretEntryIndex: 1);
      expect(caretRing(), findsOneWidget, reason: '光标停在第 2 个字符上应画一圈环');

      await pumpWithCaret(tester, caretEntryIndex: null);
      expect(caretRing(), findsNothing, reason: '光标未激活不画环');
    });

    testWidgets('越界下标不画环（cue 切换后旧下标失效的兜底）', (tester) async {
      await pumpWithCaret(tester, caretEntryIndex: 99);
      expect(caretRing(), findsNothing);
    });

    testWidgets('caret 视图：entryCount / hitAt / anchorEntry 与登记表同源',
        (tester) async {
      final VideoSubtitleHitTester t2 = await pumpWithCaret(tester);
      expect(t2.caretEntryCount(), 3, reason: '「あいう」逐 grapheme 登记 3 条');
      final SubtitleCharHit? hit = t2.caretHitAt(1);
      expect(hit, isNotNull);
      expect(hit!.sentence, 'あいう');
      expect(hit.graphemeIndex, 1);
      expect(hit.charRect, isNot(Rect.zero));
      expect(t2.caretAnchorEntry(), 0, reason: '锚点=主字幕首个可见字符');
      expect(t2.caretEntryRects().length, 3);
    });

    testWidgets('主+副字幕同时在屏：锚点优先主字幕层（副层是翻译参考）', (tester) async {
      final VideoSubtitleHitTester t2 =
          await pumpWithCaret(tester, withSecondary: true);
      expect(t2.caretEntryCount(), 5, reason: '主 3 + 副 2');
      final int anchor = t2.caretAnchorEntry();
      final SubtitleCharHit? hit = t2.caretHitAt(anchor);
      expect(hit, isNotNull);
      expect(hit!.sentence, 'あいう', reason: '锚点必须落在主字幕句上');
      expect(hit.graphemeIndex, 0);
    });

    testWidgets('听力沉浸模糊开着但已暂停：字幕显形（BUG-199），锚点可用', (tester) async {
      // 进入选词光标前必暂停，而模糊只在播放中生效——暂停即显形，故听力沉浸
      // 模式下选词光标天然可用，不需要额外「先显形再选词」的特例分支。
      final VideoSubtitleHitTester t2 =
          await pumpWithCaret(tester, blurEnabled: true);
      expect(t2.caretAnchorEntry(), 0);
    });

    testWidgets('无字幕在屏：锚点 -1（页面据此拒绝进入并提示）', (tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      final VideoSubtitleHitTester hitTester = VideoSubtitleHitTester();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: VideoSubtitleOverlay(controller: c, hitTester: hitTester),
        ),
      ));
      await tester.pump();
      expect(hitTester.caretEntryCount(), 0);
      expect(hitTester.caretAnchorEntry(), -1);
    });
  });

  group('③ guardVideoShortcutsWithSubtitleCaret 键盘接管', () {
    Map<ShortcutActivator, VoidCallback> base(List<String> log) =>
        <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.arrowLeft,
              includeRepeats: true): () => log.add('seekBack'),
          const SingleActivator(LogicalKeyboardKey.arrowLeft,
              control: true, includeRepeats: true): () => log.add('prevCue'),
        };

    void runActivator(
      Map<ShortcutActivator, VoidCallback> map, {
      required bool ctrl,
    }) {
      for (final MapEntry<ShortcutActivator, VoidCallback> e in map.entries) {
        final SingleActivator a = e.key as SingleActivator;
        if (a.control == ctrl) e.value();
      }
    }

    test('激活期：无修饰方向键改走光标，Ctrl 组合键放行', () {
      final List<String> log = <String>[];
      final List<LogicalKeyboardKey> caretKeys = <LogicalKeyboardKey>[];
      final Map<ShortcutActivator, VoidCallback> guarded =
          guardVideoShortcutsWithSubtitleCaret(
        base(log),
        isCaretActive: () => true,
        runCaretKey: (LogicalKeyboardKey key, {required bool shift}) {
          caretKeys.add(key);
          return true;
        },
      );
      runActivator(guarded, ctrl: false);
      expect(log, isEmpty, reason: '裸 ← 在光标激活期不得 seek');
      expect(caretKeys, <LogicalKeyboardKey>[LogicalKeyboardKey.arrowLeft]);

      runActivator(guarded, ctrl: true);
      expect(log, <String>['prevCue'], reason: 'Ctrl+← 上一句照常放行');
    });

    test('未激活：零行为变化', () {
      final List<String> log = <String>[];
      final Map<ShortcutActivator, VoidCallback> guarded =
          guardVideoShortcutsWithSubtitleCaret(
        base(log),
        isCaretActive: () => false,
        runCaretKey: (LogicalKeyboardKey key, {required bool shift}) {
          fail('未激活不得进光标路由');
        },
      );
      runActivator(guarded, ctrl: false);
      expect(log, <String>['seekBack']);
    });
  });

  /// PR#632 审查 C1：光标必须在暂停下工作，所以「外部恢复播放」= 用户不想选词了
  /// ⇒ 自动退出光标。判据是「先见过暂停，再见到播放」，要害在**初值**——视频本来
  /// 就是暂停态时进光标，不会调 pause、播放态不翻转、播放器也不再通知，标记若恒
  /// 初始化成 false 就永远置不上位，自动退出在这条路径上**永久失效**（用户按空格
  /// 续播后光标还活着、方向键继续被吞）。
  group('⑤ SubtitleCaretPauseTracker 暂停→再播放迁移', () {
    test('播放中进光标：pause 未落地那几个 tick 不得自退，落地后再播放才退', () {
      final SubtitleCaretPauseTracker t =
          SubtitleCaretPauseTracker(playingAtEntry: true);
      expect(t.sawPaused, isFalse);
      // fire-and-forget pause 还没落地：仍是 playing，不能当场自退。
      expect(t.onTick(playing: true), isFalse);
      // pause 落地。
      expect(t.onTick(playing: false), isFalse);
      expect(t.sawPaused, isTrue);
      // 外部恢复播放（空格 / 点画面 / 连播）→ 退光标。
      expect(t.onTick(playing: true), isTrue);
    });

    test('本来就暂停时进光标：外部恢复播放**必须**退光标（C1 主诉）', () {
      final SubtitleCaretPauseTracker t =
          SubtitleCaretPauseTracker(playingAtEntry: false);
      expect(t.sawPaused, isTrue, reason: '进入时已暂停 = 暂停已生效，不能等一个永远不会来的暂停通知');
      // 暂停下的 tick（跳句 / seek 重锚）不退。
      expect(t.onTick(playing: false), isFalse);
      // 用户按空格续播 → 必须退光标，否则光标僵尸化、方向键继续被吞。
      expect(t.onTick(playing: true), isTrue, reason: '本就暂停进光标后按空格续播，光标必须自动退出');
    });

    test('退出后再进入是全新会话（旧标记不串场）', () {
      final SubtitleCaretPauseTracker first =
          SubtitleCaretPauseTracker(playingAtEntry: false);
      expect(first.onTick(playing: true), isTrue);
      final SubtitleCaretPauseTracker second =
          SubtitleCaretPauseTracker(playingAtEntry: true);
      expect(second.onTick(playing: true), isFalse,
          reason: '新会话在播放中进入，pause 未落地前不得自退');
    });
  });

  /// PR#632 审查「顺带项」：两条只活在 page state 私有 extension 上的接线（没有
  /// 可落地的 widget 层，故守在源码接线层；断言全部落在**切出来的方法体**内，
  /// 不做全文件模糊 contains）。
  group('⑥ 光标会话收尾 / 扳机放行 源码接线守卫', () {
    final String src = readVideoFushiSource();

    test('_exitSubtitleCaret 与「surface 被悄悄清空」共用同一个收尾出口', () {
      final String exit = _sliceSource(
        src,
        'void _exitSubtitleCaret({required bool resume}) {',
        '/// 光标会话收尾的**唯一出口**',
      );
      expect(exit, contains('_finishSubtitleCaretSession(resume: resume)'),
          reason: '退出必须走唯一收尾出口，不得各写一份');

      final String finish = _sliceSource(
        src,
        'void _finishSubtitleCaretSession({required bool resume}) {',
        '/// 光标会话期间监听播放器',
      );
      // 收尾三件事必须绑在一起，少做任何一件就是僵尸态。
      expect(finish, contains('removeListener(_onCaretControllerTick)'),
          reason: '不摘监听器 → 下次进光标重复注册');
      expect(finish, contains('_caretPauseTracker = null'),
          reason: '不清追踪器 → 旧会话的暂停迁移状态串进下一次会话');
      expect(finish, contains('_subtitleCaretEntry = null'),
          reason: '不清锚点 → 字幕上留一圈光标环');

      final String popup = _sliceSource(
        src,
        'Future<void> _runPopupSurfaceCaretAction(CaretAction action) async {',
        '_videoCaret.busy = true;',
      );
      expect(popup, contains('_videoCaret.resumePopupCaretForHardwareNav()'));
      expect(
        popup,
        contains('if (!_videoCaretActive) _finishSubtitleCaretSession('),
        reason: 'resumePopupCaretForHardwareNav 在弹窗已消失时把 surface 直接清成'
            ' none 且不经 caretSetState；不在此补收尾就会留下光标环 + 未摘监听器 +'
            ' 未复位暂停的僵尸态',
      );
    });

    test('主面 LT/RT 不被 caret 路由吞掉，整体交回注册表', () {
      final String gp = _sliceSource(
        src,
        'bool _handleCaretGamepadButton(GamepadButton button) {',
        '/// 键盘光标键执行',
      );
      expect(
        gp,
        contains('final CaretAction? caretAction = shoulderOnSubtitleSurface'),
      );
      expect(
        gp,
        contains('? null'),
      );
      expect(
        gp,
        contains(': ReaderCaretRouter.decideGamepad(button);'),
        reason: '主面无词典段语义：LT/RT 走 decideGamepad 会被映射成 jumpDict* 并'
            '静默 return（用户按 RT 全屏 / LT 重听毫无反应）',
      );
      expect(
        gp,
        contains('(shoulderOnSubtitleSurface ||'),
        reason: '主面的放行白名单必须把这两个扳机算进去，否则末尾的 return true'
            '仍会把它们吞掉',
      );
    });
  });

  group('④ videoEnterCaret 默认键位', () {
    test('桌面默认 Enter + 手柄 Select', () {
      final Map<ShortcutAction, ShortcutBindingSet> desktop =
          ShortcutDefaults.forPlatform(TargetPlatform.windows);
      final ShortcutBindingSet? set = desktop[ShortcutAction.videoEnterCaret];
      expect(set, isNotNull, reason: 'videoEnterCaret 必须有默认绑定');
      expect(
        set!.keyboardBindings.map((InputBinding b) => b.key),
        contains(LogicalKeyboardKey.enter),
      );
      expect(
        set.gamepadBindings.map((GamepadBinding b) => b.button),
        contains(GamepadButton.select),
      );
    });
  });
}

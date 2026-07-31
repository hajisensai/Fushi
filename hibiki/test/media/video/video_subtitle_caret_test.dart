import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_player_shortcuts.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_defaults.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// videoEnterCaret：视频页手柄/键盘字级选词查词（用户诉求「视频支持手柄查词」——
/// 此前唯一非鼠标查词入口是 Shift+指针位置，纯手柄下完全无法查词）。
///
/// 分四层验证：
///  ① 纯移动函数 [moveSubtitleCaretEntry]（几何行移/跳行/跳过模糊/边界原地）；
///  ② overlay 真行为——caretEntryIndex 画光标环、模糊字符不画、caret 视图绑定
///     （entryCount / hitAt / anchorEntry 主字幕优先）；
///  ③ 键盘接管纯函数 [guardVideoShortcutsWithSubtitleCaret]（激活期无修饰方向键
///     改走光标、Ctrl 组合键放行、未激活零变化）；
///  ④ 默认键位——videoEnterCaret 桌面默认 Enter + 手柄 Select。
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

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/links/theme_song/theme_song_plan.dart';
import 'package:fushi/src/media/video/theme_song/video_theme_song_overlay.dart';
import 'package:material_ui/material_ui.dart';

/// 视频页「跳过片头 / 片尾」与 OP 期间的曲名角标（作品图谱 L2）。
///
/// 钉：① 位置进 OP / ED 才出跳过按钮，插入曲只出角标不给跳过；② 点跳过落点 = 段尾
/// 前 0.5 s，同一段不再出按钮；③ 自动跳过只在刚进段的窗口里触发一次，用户拖回段中
/// 不被再次弹走；④ 角标开关；⑤ 整层不进焦点——点按钮后正文焦点不丢（焦点所有权规则）。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  const ThemeSongSpan op = ThemeSongSpan(
    trackUid: 'op',
    title: '夜明けの窓',
    role: ThemeSongRole.op,
    startMs: 60000,
    endMs: 150000,
    confidence: 0.95,
  );
  const ThemeSongSpan insert = ThemeSongSpan(
    trackUid: 'ins',
    title: '挿入歌',
    role: ThemeSongRole.insert,
    startMs: 600000,
    endMs: 660000,
    confidence: 0.9,
  );
  const ThemeSongSpan ed = ThemeSongSpan(
    trackUid: 'ed',
    title: 'ED 曲',
    role: ThemeSongRole.ed,
    startMs: 1300000,
    endMs: 1390000,
    confidence: 0.9,
  );

  group('VideoThemeSongTracker', () {
    test('进段出按钮；插入曲不可跳过；离段清空', () {
      final VideoThemeSongTracker tracker = VideoThemeSongTracker(
        autoSkip: () => false,
        onAutoSkip: (_) => fail('auto skip off'),
      )..setSpans(const <ThemeSongSpan>[op, insert, ed]);
      tracker.onPosition(30000);
      expect(tracker.active.value, isNull);
      tracker.onPosition(61000);
      expect(tracker.active.value?.span.trackUid, 'op');
      expect(tracker.active.value?.skippable, isTrue);
      tracker.onPosition(610000);
      expect(tracker.active.value?.span.trackUid, 'ins');
      expect(tracker.active.value?.skippable, isFalse);
      tracker.onPosition(1300500);
      expect(tracker.active.value?.span.role, ThemeSongRole.ed);
      tracker.onPosition(1400000);
      expect(tracker.active.value, isNull);
      tracker.dispose();
    });

    test('手动跳过：落点 = 段尾前 0.5 s，之后这段不再自动处理', () {
      final List<int> autoTargets = <int>[];
      bool auto = false;
      final VideoThemeSongTracker tracker = VideoThemeSongTracker(
        autoSkip: () => auto,
        onAutoSkip: autoTargets.add,
      )..setSpans(const <ThemeSongSpan>[op]);
      tracker.onPosition(61000);
      expect(tracker.skip(op), 149500);
      expect(tracker.active.value, isNull);
      auto = true;
      tracker.onPosition(60500);
      expect(autoTargets, isEmpty, reason: '已处理过的段不再自动跳');
      tracker.dispose();
    });

    test('自动跳过只在刚进段的 3 s 窗口内触发一次；拖回段中不再弹走', () {
      final List<int> autoTargets = <int>[];
      final VideoThemeSongTracker tracker = VideoThemeSongTracker(
        autoSkip: () => true,
        onAutoSkip: autoTargets.add,
      )..setSpans(const <ThemeSongSpan>[op, insert]);
      tracker.onPosition(60200);
      expect(autoTargets, <int>[149500]);
      tracker.onPosition(60300);
      expect(autoTargets, hasLength(1));
      expect(tracker.active.value?.skippable, isTrue, reason: '按钮仍在，可手动跳');
      // 换集重置。
      tracker.setSpans(const <ThemeSongSpan>[op]);
      tracker.onPosition(90000);
      expect(autoTargets, hasLength(1), reason: '段中途进入（拖进度条）不自动跳');
      // 插入曲永不自动跳。
      tracker.setSpans(const <ThemeSongSpan>[insert]);
      tracker.onPosition(600100);
      expect(autoTargets, hasLength(1));
      tracker.dispose();
    });

    test('跟位置源：attach 后位置事件驱动判定，换源自动解绑旧源', () {
      final ValueNotifier<int?> a = ValueNotifier<int?>(null);
      final ValueNotifier<int?> b = ValueNotifier<int?>(null);
      final VideoThemeSongTracker tracker = VideoThemeSongTracker(
        autoSkip: () => false,
        onAutoSkip: (_) {},
      )..setSpans(const <ThemeSongSpan>[op]);
      tracker.attach(a);
      a.value = 70000;
      expect(tracker.active.value?.span.trackUid, 'op');
      tracker.attach(b);
      b.value = 10;
      expect(tracker.active.value, isNull);
      a.value = 80000;
      expect(tracker.active.value, isNull, reason: '旧源已解绑');
      tracker.dispose();
      a.dispose();
      b.dispose();
    });
  });

  group('VideoThemeSongOverlay', () {
    Future<
      ({
        VideoThemeSongTracker tracker,
        List<ThemeSongSpan> skipped,
        List<ThemeSongSpan> opened,
        FocusNode body,
      })
    >
    pump(WidgetTester tester, {bool showNowPlaying = true}) async {
      final VideoThemeSongTracker tracker = VideoThemeSongTracker(
        autoSkip: () => false,
        onAutoSkip: (_) {},
      )..setSpans(const <ThemeSongSpan>[op, insert, ed]);
      final List<ThemeSongSpan> skipped = <ThemeSongSpan>[];
      final List<ThemeSongSpan> opened = <ThemeSongSpan>[];
      final FocusNode body = FocusNode(debugLabel: 'video-body');
      addTearDown(() {
        tracker.dispose();
        body.dispose();
      });
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: Focus(
                focusNode: body,
                autofocus: true,
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(
                      child: VideoThemeSongOverlay(
                        tracker: tracker,
                        showNowPlaying: showNowPlaying,
                        onSkip: (ThemeSongSpan s) {
                          skipped.add(s);
                          tracker.skip(s);
                        },
                        onOpenTrack: opened.add,
                        surfaceColor: Colors.black54,
                        textColor: Colors.white,
                        skipBottomInset: 80,
                        nowPlayingTopInset: 60,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return (tracker: tracker, skipped: skipped, opened: opened, body: body);
    }

    testWidgets('OP 里：「跳过片头」+ 曲名角标；点跳过走回调且正文焦点不丢', (WidgetTester tester) async {
      final ({
        VideoThemeSongTracker tracker,
        List<ThemeSongSpan> skipped,
        List<ThemeSongSpan> opened,
        FocusNode body,
      })
      h = await pump(tester);
      expect(find.text('跳过片头'), findsNothing);
      h.tracker.onPosition(65000);
      await tester.pumpAndSettle();
      expect(find.text('跳过片头'), findsOneWidget);
      expect(find.text('♪ 夜明けの窓 · 在音乐库打开'), findsOneWidget);
      expect(h.body.hasPrimaryFocus, isTrue);

      await tester.tap(find.text('跳过片头'));
      await tester.pumpAndSettle();
      expect(h.skipped.single.trackUid, 'op');
      expect(find.text('跳过片头'), findsNothing);
      expect(h.body.hasPrimaryFocus, isTrue, reason: '覆盖层不进焦点，正文焦点不被夺走');

      // Tab 遍历也走不进覆盖层。
      h.tracker.onPosition(1300500);
      await tester.pumpAndSettle();
      expect(find.text('跳过片尾'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
      expect(
        focused?.findAncestorWidgetOfExactType<VideoThemeSongOverlay>(),
        isNull,
        reason: 'Tab 不能把焦点送进覆盖层',
      );
    });

    testWidgets('插入曲：只有角标、没有跳过；点角标走「在音乐库打开」', (WidgetTester tester) async {
      final ({
        VideoThemeSongTracker tracker,
        List<ThemeSongSpan> skipped,
        List<ThemeSongSpan> opened,
        FocusNode body,
      })
      h = await pump(tester);
      h.tracker.onPosition(620000);
      await tester.pumpAndSettle();
      expect(find.text('跳过片头'), findsNothing);
      expect(find.text('跳过片尾'), findsNothing);
      await tester.tap(find.text('♪ 挿入歌 · 在音乐库打开'));
      await tester.pumpAndSettle();
      expect(h.opened.single.trackUid, 'ins');
    });

    testWidgets('角标开关关掉时只剩跳过按钮', (WidgetTester tester) async {
      final ({
        VideoThemeSongTracker tracker,
        List<ThemeSongSpan> skipped,
        List<ThemeSongSpan> opened,
        FocusNode body,
      })
      h = await pump(tester, showNowPlaying: false);
      h.tracker.onPosition(65000);
      await tester.pumpAndSettle();
      expect(find.text('跳过片头'), findsOneWidget);
      expect(find.textContaining('在音乐库打开'), findsNothing);
    });
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_lyrics_view.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_page.dart'
    show debugMusicAppleLyricsCover, musicAppleLyricsAppearance;
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart'
    show ShelfCoverFrame;
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart'
    show FushiGlassScope;
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart'
    show FushiAppleMenuCheck, FushiMenuAnchor;
import 'package:fushi/src/utils/components/fushi_m3e_player.dart'
    show FushiPlaybackClock, fushiAppleTrackPlayedColor;
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

// 用户 2026-11-24：Cupertino 下歌词 / 正在播放页照 macOS Apple Music 全屏歌词排版
// （左列：封面 → 标题 + ☆⋯ → 进度 + 时间 → 五键传输；右列 Apple 式歌词）。

class _Clock implements FushiPlaybackClock {
  int ms = 0;

  @override
  Duration get position => Duration(milliseconds: ms);

  @override
  Duration get duration => const Duration(minutes: 4);
}

LyricLine _line(int start, String text) => LyricLine(
  startMs: start,
  endMs: start + 900,
  syllables: <LyricSyllable>[
    LyricSyllable(text: text, startMs: start, endMs: start + 900),
  ],
);

LyricTimeline _timeline() => LyricTimeline(
  format: 'ttml',
  timingQuality: LyricTimingQuality.syllable,
  lines: <LyricLine>[
    for (int i = 0; i < 10; i++) _line(1000 + i * 1000, 'line$i'),
  ],
);

String _part() => File(
  'lib/src/pages/implementations/music/music_lyrics_page_apple.part.dart',
).readAsStringSync();

String _page() => File(
  'lib/src/pages/implementations/music/music_lyrics_page.dart',
).readAsStringSync();

/// [src] 里从 [start] 起、到下一个同级方法（两空格缩进的 `Widget _`）为止的片段。
String _method(String src, String start) {
  final int from = src.indexOf(start);
  expect(from, isNonNegative, reason: start);
  final int to = src.indexOf('\n  Widget _', from + start.length);
  return src.substring(from, to < 0 ? src.length : to);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 用户 2026-11-24：「专辑的3d斜视差没了而且光面没了」——Apple 大封面要挂着原来的
  // FushiHoverLift（3D 倾斜）+ 专辑光面材质框；小封面不倾斜。
  for (final (double size, bool big) in <(double, bool)>[
    (320, true),
    (56, false),
  ]) {
    testWidgets('Apple cover $size: tilt + sheen = $big', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(
              seedColor: Colors.teal,
              brightness: Brightness.dark,
            ),
            textTheme: Typography.material2021().white,
            glass: FushiGlassMaterial.minimal,
            glassDesign: true,
            eink: false,
          ),
          home: FushiGlassScope(
            child: Scaffold(
              body: Center(child: debugMusicAppleLyricsCover(null, size)),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(FushiHoverLift), big ? findsOneWidget : findsNothing);
      expect(find.byType(ShelfCoverFrame), big ? findsOneWidget : findsNothing);
    });
  }

  // 用户 2026-11-24「右上角那三个点改为下拉框吧别用panel」：Apple 下歌词页右上「⋯」
  // 的来源动作走顶栏 menu（锚在按钮下的下拉菜单），不弹对话框 / 面板。
  testWidgets('Apple top-bar ⋯ opens a pull-down, not a panel', (
    WidgetTester tester,
  ) async {
    int fired = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFushiThemeData(
          scheme: ColorScheme.fromSeed(
            seedColor: Colors.teal,
            brightness: Brightness.dark,
          ),
          textTheme: Typography.material2021().white,
          glass: FushiGlassMaterial.minimal,
          glassDesign: true,
          eink: false,
        ),
        home: FushiGlassScope(
          child: Scaffold(
            body: SizedBox(
              width: 1200,
              child: FushiFloatingTopBar(
                bare: true,
                overflowKey: const ValueKey<String>('music_lyrics_more'),
                actions: <List<FushiToolbarItem>>[
                  <FushiToolbarItem>[
                    FushiToolbarItem(
                      icon: FushiIcons.search,
                      label: 'Search',
                      onPressed: () {},
                    ),
                  ],
                ],
                menu: <FushiToolbarItem>[
                  FushiToolbarItem(
                    key: const ValueKey<String>('music_lyrics_more_0'),
                    icon: FushiIcons.lyrics,
                    label: 'Choose lyrics source',
                    onPressed: () => fired++,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('music_lyrics_more')));
    await tester.pumpAndSettle();
    expect(find.text('Choose lyrics source'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
    await tester.tap(find.text('Choose lyrics source'));
    await tester.pumpAndSettle();
    expect(fired, 1);
    expect(find.text('Choose lyrics source'), findsNothing, reason: '选完收起');
  });

  test('lyrics page wires its Apple ⋯ to the top-bar pull-down', () {
    final String page = _page();
    expect(page, contains('menu: apple'));
    expect(page, contains('_sourceActionOptions()'));
    expect(page, contains("? const ValueKey<String>('music_lyrics_more')"));
  });

  // 用户 2026-11-24「还有点问题」：标题旁「⋯」的菜单要是 Apple 菜单——开着的项 ✓、
  // 行带图标（宽屏 macOS 按 11-24 拍板不画行内图标）、下方放不下翻到上方。
  Widget appleHost(Widget child, {Size size = const Size(800, 600)}) =>
      MediaQuery(
        data: MediaQueryData(size: size),
        child: MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(
              seedColor: Colors.teal,
              brightness: Brightness.dark,
            ),
            textTheme: Typography.material2021().white,
            glass: FushiGlassMaterial.minimal,
            glassDesign: true,
            eink: false,
          ),
          home: FushiGlassScope(child: Scaffold(body: child)),
        ),
      );

  Widget moreMenu() => FushiMenuAnchor(
    reservedPadding: const EdgeInsets.all(16),
    menuChildren: <Widget>[
      MenuItemButton(
        key: const ValueKey<String>('earlier'),
        closeOnActivate: false,
        leadingIcon: const Icon(FushiIcons.remove),
        onPressed: () {},
        child: const Text('Delay lyrics'),
      ),
      CheckboxMenuButton(
        key: const ValueKey<String>('loop'),
        value: true,
        onChanged: (_) {},
        child: const Text('Loop current line'),
      ),
      CheckboxMenuButton(
        key: const ValueKey<String>('desktop'),
        value: false,
        onChanged: (_) {},
        child: const Text('Desktop lyrics'),
      ),
      for (int i = 0; i < 6; i++)
        MenuItemButton(
          leadingIcon: const Icon(FushiIcons.playlist),
          onPressed: () {},
          child: Text('Row $i'),
        ),
    ],
    builder: (BuildContext context, MenuController menu, Widget? _) =>
        TextButton(
          key: const ValueKey<String>('more'),
          onPressed: menu.open,
          child: const Text('...'),
        ),
  );

  testWidgets('Apple ⋯ menu: active rows get ✓, inactive do not', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(appleHost(Center(child: moreMenu())));
    await tester.tap(find.byKey(const ValueKey<String>('more')));
    await tester.pumpAndSettle();
    Iterable<FushiAppleMenuCheck> checks(String key) =>
        tester.widgetList<FushiAppleMenuCheck>(
          find.descendant(
            of: find.byKey(ValueKey<String>(key)),
            matching: find.byType(FushiAppleMenuCheck),
          ),
        );
    expect(checks('loop').single.checked, isTrue);
    expect(checks('desktop').single.checked, isFalse);
    // 同组有勾选项：普通行也让出 ✓ 列（未勾），文字左缘对齐。
    expect(checks('earlier').single.checked, isFalse);
  });

  testWidgets('Apple ⋯ menu flips above the button when room below is short', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      appleHost(
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 40),
            child: moreMenu(),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey<String>('more')));
    await tester.pumpAndSettle();
    final Rect button = tester.getRect(
      find.byKey(const ValueKey<String>('more')),
    );
    final Rect first = tester.getRect(
      find.byKey(const ValueKey<String>('earlier')),
    );
    final Rect last = tester.getRect(find.text('Row 5'));
    expect(first.top, lessThan(button.top), reason: '翻到按钮上方');
    expect(last.bottom, lessThanOrEqualTo(button.top));
  });

  test(
    'lyrics ⋯ menu uses check rows + trailing values; volume track is label',
    () {
      final String more = _method(_part(), 'Widget _buildAppleMoreMenu(');
      expect(more, contains('CheckboxMenuButton('));
      expect(more, contains('reservedPadding:'));
      expect(more, contains('t.music_quality_title'));
      expect(more, contains('trailing: quality'));
      expect(more, contains('trailing: effects'));
      expect(more, isNot(contains('music_quality_chip_semantics')));
      final String part = _part();
      // 音量轨与进度条同一份配色函数（静止 secondaryLabel、拖动 label）。
      expect(part, contains('activeColor: fushiAppleTrackPlayedColor(apple,'));
      expect(
        File(
          'lib/src/utils/components/fushi_m3e_player.dart',
        ).readAsStringSync(),
        contains(
          'final Color played = fushiAppleTrackPlayedColor(apple, drag);',
        ),
      );
      expect(part, isNot(contains('adaptiveSlider(')));
    },
  );

  test('Apple track colour: secondaryLabel at rest, label while dragging', () {
    final FushiAppleColors apple = FushiAppleColors.of(
      Brightness.dark,
      const Color(0xFF0A84FF),
    );
    expect(fushiAppleTrackPlayedColor(apple, 0), apple.secondaryLabel);
    expect(fushiAppleTrackPlayedColor(apple, 1), apple.label);
  });

  test('Apple lyrics appearance: label colours, anchor at 1/3, blur on', () {
    final FushiAppleColors apple = FushiAppleColors.of(
      Brightness.dark,
      const Color(0xFF0A84FF),
    );
    final KaraokeLyricsAppearance a = musicAppleLyricsAppearance(
      apple,
      blur: true,
    );
    expect(a.activeColor, apple.label);
    expect(a.secondaryColor, apple.secondaryLabel);
    expect(a.anchor, closeTo(1 / 3, 1e-9));
    expect(a.blurInactive, isTrue);
    expect(a.fontWeight, FontWeight.w800);
    expect(
      musicAppleLyricsAppearance(apple, blur: false).blurInactive,
      isFalse,
      reason: '跟随「非当前行模糊」偏好',
    );
  });

  testWidgets('Apple lyrics: current line sharp, other lines blurred', (
    WidgetTester tester,
  ) async {
    final _Clock clock = _Clock()..ms = 3100; // line2 正在唱
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: KaraokeLyricsView(
              timeline: _timeline(),
              clock: clock,
              playing: false,
              appearance: musicAppleLyricsAppearance(
                FushiAppleColors.of(Brightness.dark, const Color(0xFF0A84FF)),
                blur: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    ImageFiltered filterOf(String text) => tester.widget<ImageFiltered>(
      find
          .ancestor(
            of: find.byWidgetPredicate(
              (Widget w) => w is Semantics && w.properties.label == text,
            ),
            matching: find.byType(ImageFiltered),
          )
          .first,
    );
    expect(filterOf('line2').enabled, isFalse, reason: '当前行不模糊');
    expect(filterOf('line1').enabled, isTrue);
    expect(filterOf('line3').enabled, isTrue);
    expect(filterOf('line5').enabled, isTrue);
  });

  test(
    'Apple wide left column order: cover → title + ☆⋯ → seek → transport',
    () {
      final String wide = _method(_part(), 'Widget _buildAppleWide(');
      final List<String> order = <String>[
        '_AppleLyricsCover(',
        '_buildAppleTitleRow(',
        '_buildSeek()',
        '_buildAppleTransport(',
      ];
      final List<int> at = <int>[for (final String s in order) wide.indexOf(s)];
      for (int i = 0; i < at.length; i++) {
        expect(at[i], isNonNegative, reason: order[i]);
        if (i > 0) expect(at[i], greaterThan(at[i - 1]), reason: order[i]);
      }
      // 标题行：标题列在左，☆ 与 ⋯ 在最右。
      final String title = _method(_part(), 'Widget _buildAppleTitleRow(');
      expect(
        title.indexOf('_buildAppleStarButton()'),
        lessThan(title.indexOf('_buildAppleMoreMenu(')),
      );
      // 五键：随机 · 上一首 · 播放 · 下一首 · 循环。
      final String transport = _method(_part(), 'Widget _buildAppleTransport(');
      final List<String> keys = <String>[
        "'music_lyrics_shuffle'",
        "'music_lyrics_previous'",
        "'music_lyrics_play_pause'",
        "'music_lyrics_next'",
        "'music_lyrics_repeat'",
      ];
      final List<int> k = <int>[
        for (final String s in keys) transport.indexOf(s),
      ];
      for (int i = 0; i < k.length; i++) {
        expect(k[i], isNonNegative, reason: keys[i]);
        if (i > 0) expect(k[i], greaterThan(k[i - 1]), reason: keys[i]);
      }
    },
  );

  test('every secondary action is reachable from ⋯', () {
    final String more = _method(_part(), 'Widget _buildAppleMoreMenu(');
    for (final String key in <String>[
      'music_lyrics_offset_earlier',
      'music_lyrics_offset_later',
      'music_lyrics_ab_loop',
      'music_lyrics_ab_loop_extend',
      'music_lyrics_quality',
      'music_lyrics_effects',
      'music_lyrics_desktop_menu',
      'music_lyrics_queue',
    ]) {
      expect(more, contains("'$key'"), reason: key);
    }
    expect(more, contains('t.music_lyrics_offset_value('));
  });

  test('M3E layouts are untouched and Apple is gated on isGlassDesign', () {
    final String page = _page();
    expect(page, contains('when apple && l != MusicLyricsLayout.disc'));
    for (final String m3e in <String>[
      '(MusicLyricsLayout.split, true) => _buildSplit(',
      '(MusicLyricsLayout.stage, true) => _buildStage(',
      '(MusicLyricsLayout.disc, _) => _buildDisc(',
      '(_, false) => _buildNarrow(context, item)',
      'FushiExpressivePlayButton(',
      'color: liked ? const Color(0xFFFF4D6D) : null',
    ]) {
      expect(page, contains(m3e), reason: m3e);
    }
    expect(page, contains('final bool apple = isGlassDesign(context);'));
  });
}

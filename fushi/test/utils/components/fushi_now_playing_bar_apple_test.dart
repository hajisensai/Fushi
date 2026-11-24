import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi/src/media/audiobook/audiobook_play_bar.dart'
    show AudiobookPlayFab;
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_apple_glyph_button.dart';
import 'package:fushi/src/utils/components/fushi_continue_card_row.dart'
    show coverColorSchemeCache;
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart'
    show FushiToolbarFab;
import 'package:fushi/src/utils/components/fushi_m3e_player.dart';
import 'package:fushi/src/utils/components/fushi_now_playing_bar.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassContainer;
import 'package:material_ui/material_ui.dart';

import '../../helpers/fake_just_audio.dart';

/// Apple 设计系统（`isGlassDesign`）下的 [FushiNowPlayingBar]：Apple Music
/// iOS 27 / macOS 27 迷你播放器。中性玻璃、方形小圆角封面、全部裸字形；iOS 档只留
/// 播放 / 下一首（其余进长按菜单 / 全屏页），macOS 档全套平铺。另含有声书播放键的
/// Apple 裸字形分支。
class _Clock implements FushiPlaybackClock {
  @override
  Duration get position => const Duration(seconds: 25);

  @override
  Duration get duration => const Duration(seconds: 100);
}

void main() {
  const Key barKey = ValueKey<String>('bar');
  const Key playKey = ValueKey<String>('play');
  const Key actionKey = ValueKey<String>('action');

  late int taps;
  late int plays;
  late int mores;
  late int prevs;
  late int nexts;
  late bool Function() originalShaderSupport;

  setUp(() {
    taps = 0;
    plays = 0;
    mores = 0;
    prevs = 0;
    nexts = 0;
    originalShaderSupport = debugShaderFilterSupported;
    debugShaderFilterSupported = () => true;
  });
  tearDown(() => debugShaderFilterSupported = originalShaderSupport);

  Widget bar({
    bool withMore = true,
    FushiPlaybackClock? clock,
    ImageProvider? tintImage,
  }) => FushiNowPlayingBar(
    barKey: barKey,
    playButtonKey: playKey,
    title: 'Song Title',
    subtitle: 'Singer · Album',
    coverBuilder: (BuildContext context, double size) =>
        const ColoredBox(color: Colors.orange),
    tintImage: tintImage,
    clock: clock,
    isPlaying: false,
    onPlayPause: () => plays++,
    onTap: () => taps++,
    previous: FushiNowPlayingSkip(
      icon: FushiIcons.skipPrevious,
      tooltip: 'Previous',
      onPressed: () => prevs++,
    ),
    next: FushiNowPlayingSkip(
      icon: FushiIcons.skipNext,
      tooltip: 'Next',
      onPressed: () => nexts++,
    ),
    actions: <Widget>[
      Builder(
        builder: (BuildContext context) => isGlassDesign(context)
            ? FushiAppleGlyphButton(
                key: actionKey,
                icon: FushiIcons.playlist,
                tooltip: 'Queue',
                secondary: false,
                extent: kFushiNowPlayingAppleGlyphExtent,
                onPressed: () {},
              )
            : FushiIconButtonControl(
                key: actionKey,
                tooltip: 'Queue',
                onPressed: () {},
                icon: const FushiIcon(FushiIcons.playlist),
              ),
      ),
    ],
    onMore: withMore ? () => mores++ : null,
  );

  ThemeData theme({
    required bool glass,
    required TargetPlatform platform,
    bool solid = false,
  }) => buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    glass: glass && !solid
        ? FushiGlassMaterial.minimal
        : FushiGlassMaterial.off,
    glassDesign: glass,
    eink: false,
  ).copyWith(platform: platform);

  Future<void> pump(
    WidgetTester tester, {
    required double width,
    required Widget child,
    TargetPlatform platform = TargetPlatform.iOS,
    bool glass = true,
    bool solid = false,
    bool? collapsed,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme(glass: glass, platform: platform, solid: solid),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: FushiGlassScope(
          child: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: collapsed == null
                  ? child
                  : FushiNowPlayingCollapse(collapsed: collapsed, child: child),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
  }

  /// Apple 外观契约：无取色底、无水印、无饼干形封面圆环、方形封面，所有字形
  /// 无着色无底（label / secondaryLabel / 禁用 tertiaryLabel，按下高亮静止为 0）。
  void expectAppleLook(WidgetTester tester) {
    final Finder root = find.byType(FushiNowPlayingBar);
    expect(
      find.descendant(
        of: root,
        matching: find.byWidgetPredicate(
          (Widget w) =>
              w is CustomPaint &&
              w.painter.runtimeType.toString() == '_WatermarkPainter',
        ),
      ),
      findsNothing,
      reason: '不压出血标题水印',
    );
    expect(
      find.descendant(of: root, matching: find.byType(AnimatedContainer)),
      findsNothing,
      reason: '没有 M3E 取色色块底',
    );
    expect(
      find.descendant(
        of: root,
        matching: find.byType(FushiWavyCircularProgress),
      ),
      findsNothing,
    );
    expect(
      find.descendant(of: root, matching: find.byType(ClipPath)),
      findsNothing,
      reason: '封面不裁饼干形',
    );
    final Finder cover = find.byKey(
      const ValueKey<String>('now-playing-apple-cover'),
    );
    expect(cover, findsWidgets);
    final ClipRSuperellipse clip = tester.widget<ClipRSuperellipse>(
      cover.first,
    );
    expect(clip.borderRadius, BorderRadius.circular(7));
    final Size coverSize = tester.getSize(cover.first);
    expect(coverSize.width, coverSize.height, reason: '方形封面');

    expect(
      find.descendant(of: root, matching: find.byType(FushiIconButtonControl)),
      findsNothing,
    );
    final FushiAppleColors apple = appleColorsOf(tester.element(root));
    final Set<Color> neutral = <Color>{
      apple.label,
      apple.secondaryLabel,
      apple.tertiaryLabel,
    };
    final Finder glyphs = find.descendant(
      of: root,
      matching: find.byType(FushiAppleGlyphButton),
    );
    expect(glyphs, findsWidgets);
    for (final Element e in glyphs.evaluate()) {
      final Finder g = find.byElementPredicate((Element x) => x == e);
      for (final FushiIcon icon in tester.widgetList<FushiIcon>(
        find.descendant(of: g, matching: find.byType(FushiIcon)),
      )) {
        expect(neutral, contains(icon.color), reason: '字形不染强调色');
      }
      for (final AnimatedOpacity o in tester.widgetList<AnimatedOpacity>(
        find.descendant(of: g, matching: find.byType(AnimatedOpacity)),
      )) {
        expect(o.opacity, 0, reason: '静止无底，按下才出高亮圆');
      }
    }
  }

  group('iOS tier', () {
    testWidgets('capsule keeps play + next only; rest goes to long-press', (
      WidgetTester tester,
    ) async {
      await pump(tester, width: 400, child: bar());
      expectAppleLook(tester);
      expect(find.text('Song Title'), findsOneWidget);
      expect(find.text('Singer · Album'), findsOneWidget);
      expect(find.byKey(playKey), findsOneWidget);
      expect(find.byTooltip('Next'), findsOneWidget);
      expect(find.byTooltip('Previous'), findsNothing);
      expect(find.byKey(actionKey), findsNothing);
      // 下一首是 forward.fill 实心字形（Apple Music）。
      final FushiAppleGlyphButton nextButton = tester
          .widget<FushiAppleGlyphButton>(
            find.ancestor(
              of: find.byTooltip('Next'),
              matching: find.byType(FushiAppleGlyphButton),
            ),
          );
      expect(nextButton.icon, FushiIcons.fastForward);
      expect(nextButton.prominent, isTrue);
      expect(
        tester.getSize(find.byKey(playKey)).width,
        greaterThanOrEqualTo(44),
      );

      await tester.tap(find.byKey(playKey));
      await tester.tap(find.byTooltip('Next'));
      await tester.tap(find.text('Song Title'));
      await tester.pump();
      expect(plays, 1);
      expect(nexts, 1);
      expect(taps, 1, reason: '点条身进全屏播放页');

      await tester.longPress(find.text('Song Title'));
      await tester.pump();
      expect(mores, 1, reason: '长按菜单入口仍在');
    });

    testWidgets('without a more menu the actions stay inline', (
      WidgetTester tester,
    ) async {
      await pump(tester, width: 400, child: bar(withMore: false));
      expect(find.byKey(actionKey), findsOneWidget);
      expectAppleLook(tester);
    });

    testWidgets('collapsed shrinks to cover + play; first tap peeks', (
      WidgetTester tester,
    ) async {
      await pump(tester, width: 400, child: bar(), collapsed: true);
      expect(find.text('Song Title'), findsNothing);
      expect(find.byKey(playKey), findsOneWidget);
      await tester.tap(find.byKey(barKey), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 600));
      expect(taps, 0, reason: '收起时第一下只展开');
      expect(find.text('Song Title'), findsOneWidget);
    });

    testWidgets('focus + Enter opens the player and toggles play', (
      WidgetTester tester,
    ) async {
      await pump(tester, width: 400, child: bar());
      Focus.of(tester.element(find.byKey(barKey))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(taps, 1);

      Focus.of(
        tester.element(
          find
              .descendant(
                of: find.byKey(playKey),
                matching: find.byType(GestureDetector),
              )
              .first,
        ),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(plays, 1);
      expect(taps, 1);
    });
  });

  group('macOS tier', () {
    testWidgets('full transport + actions inline, thin progress line', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        width: 1200,
        platform: TargetPlatform.macOS,
        child: bar(clock: _Clock()),
      );
      expectAppleLook(tester);
      expect(find.text('Singer · Album'), findsOneWidget);
      expect(find.byTooltip('Previous'), findsOneWidget);
      expect(find.byTooltip('Next'), findsOneWidget);
      expect(find.byKey(actionKey), findsOneWidget);
      final FushiAppleGlyphButton prev = tester.widget<FushiAppleGlyphButton>(
        find.ancestor(
          of: find.byTooltip('Previous'),
          matching: find.byType(FushiAppleGlyphButton),
        ),
      );
      expect(prev.icon, FushiIcons.fastRewind);
      final FractionallySizedBox line = tester.widget<FractionallySizedBox>(
        find.descendant(
          of: find.byType(FushiNowPlayingBar),
          matching: find.byType(FractionallySizedBox),
        ),
      );
      expect(line.widthFactor, closeTo(0.25, 1e-9));

      await tester.tap(find.byTooltip('Previous'));
      await tester.pump();
      expect(prevs, 1);
    });

    testWidgets('collapsed: title + play, first tap pins it open', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        width: 1200,
        platform: TargetPlatform.macOS,
        child: bar(),
        collapsed: true,
      );
      expect(find.text('Song Title'), findsOneWidget);
      expect(find.text('Singer · Album'), findsNothing);
      expect(find.byKey(actionKey), findsNothing);
      await tester.tap(find.text('Song Title'));
      await tester.pump(const Duration(milliseconds: 600));
      expect(taps, 0, reason: '收起时第一下只展开');
      expect(find.byKey(actionKey), findsOneWidget);
      await tester.tap(find.text('Singer · Album'));
      await tester.pump();
      expect(taps, 1);
    });
  });

  group('cover tint', () {
    const ImageProvider tinted = AssetImage('apple-tint-test-cover.png');
    const Color seed = Color(0xFFD04020);
    setUp(() => coverColorSchemeCache.debugStoreSeed(tinted, seed.toARGB32()));
    final Finder surface = find.byKey(
      const ValueKey<String>('now-playing-apple-surface'),
    );

    testWidgets('glass is tinted with the shared cover colour, low chroma', (
      WidgetTester tester,
    ) async {
      await pump(tester, width: 400, child: bar(tintImage: tinted));
      expectAppleLook(tester);
      final Color hue = buildFushiColorScheme(
        seedColor: seed,
        brightness: Brightness.light,
      ).primary;
      final Color glass = tester
          .widget<GlassContainer>(surface)
          .settings!
          .glassColor;
      expect(glass, fushiNowPlayingAppleGlassTint(hue, dark: false));
      final HSLColor hsl = HSLColor.fromColor(glass.withValues(alpha: 1));
      expect(hsl.saturation, lessThanOrEqualTo(0.32 + 1e-6));
      expect(hsl.lightness, closeTo(0.90, 0.01), reason: '浅色底保住 label 对比度');
    });

    testWidgets('no cover falls back to the neutral bar glass', (
      WidgetTester tester,
    ) async {
      await pump(tester, width: 400, child: bar());
      final Color neutral = fushiGlassButtonRestSettings(
        fushiClearGlassSettings(tester.element(surface), bar: true),
      ).glassColor;
      expect(
        tester.widget<GlassContainer>(surface).settings!.glassColor,
        neutral,
      );
    });

    testWidgets('solid material tier uses the tinted system material', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        width: 400,
        solid: true,
        child: bar(tintImage: tinted),
      );
      final Color hue = buildFushiColorScheme(
        seedColor: seed,
        brightness: Brightness.light,
      ).primary;
      final DecoratedBox box = tester.widget<DecoratedBox>(surface);
      expect(
        (box.decoration as ShapeDecoration).color,
        fushiNowPlayingAppleSolidTint(hue, dark: false),
      );
      expect(find.byType(GlassContainer), findsNothing);
    });
  });

  testWidgets('M3E keeps the cover-tinted block (no Apple parts)', (
    WidgetTester tester,
  ) async {
    await pump(tester, width: 400, glass: false, child: bar());
    final Finder root = find.byType(FushiNowPlayingBar);
    expect(
      find.descendant(of: root, matching: find.byType(FushiAppleGlyphButton)),
      findsNothing,
    );
    expect(
      find.descendant(
        of: root,
        matching: find.byType(FushiWavyCircularProgress),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('now-playing-apple-cover')),
      findsNothing,
    );
    expect(find.byTooltip('Previous'), findsOneWidget);
  });

  group('audiobook play button', () {
    for (final bool glass in <bool>[true, false]) {
      testWidgets('glass: $glass', (WidgetTester tester) async {
        installFakeJustAudio();
        final AudiobookPlayerController controller =
            AudiobookPlayerController();
        addTearDown(controller.dispose);
        await pump(
          tester,
          width: 400,
          glass: glass,
          child: AudiobookPlayFab(controller: controller, size: 52),
        );
        final Finder key = find.byKey(
          const ValueKey<String>('audiobook_play_fab'),
        );
        expect(key, findsOneWidget);
        if (!glass) {
          expect(tester.widget(key), isA<FushiToolbarFab>());
          return;
        }
        expect(tester.widget(key), isA<FushiApplePlayPauseButton>());
        expect(find.byType(FushiToolbarFab), findsNothing);
        expect(tester.getSize(key).width, greaterThanOrEqualTo(48));
        final FushiAppleColors apple = appleColorsOf(tester.element(key));
        final FushiIcon icon = tester.widget<FushiIcon>(
          find.descendant(of: key, matching: find.byType(FushiIcon)),
        );
        expect(icon.color, apple.label, reason: 'label 色，不染强调色');
        for (final AnimatedOpacity o in tester.widgetList<AnimatedOpacity>(
          find.descendant(of: key, matching: find.byType(AnimatedOpacity)),
        )) {
          expect(o.opacity, 0, reason: '无圆形底');
        }
        for (final Material m in tester.widgetList<Material>(
          find.descendant(of: key, matching: find.byType(Material)),
        )) {
          expect(
            m.type == MaterialType.transparency || (m.color?.a ?? 0) == 0,
            isTrue,
          );
        }
      });
    }
  });
}

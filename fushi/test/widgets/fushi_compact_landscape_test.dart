// 拍板台 MANKlxTTpV：横屏手机上浮层（对话框 / 设置弹窗外框 / 宽屏浮动弹层）不再
// 按竖屏规则留一大圈空白——竖向留白收到 8、屏高比例封顶取消、宽度上限放宽到 720；
// 竖屏 / 桌面尺寸行为不变；iOS 纯文字 alert 宽度固定不放宽。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_compact_landscape.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_page_title_metrics.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:material_ui/material_ui.dart';

/// 横屏手机（Xiaomi 2311DRK48C 横放，反馈设备 407x904 转 90°）。
const Size _phoneLandscape = Size(904, 407);
const Size _phonePortrait = Size(407, 904);

const String _longText =
    'Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod '
    'tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim '
    'veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea '
    'commodo consequat. Duis aute irure dolor in reprehenderit in voluptate.';

Future<BuildContext> _pumpHost(
  WidgetTester tester, {
  required Size size,
  bool apple = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late BuildContext hostContext;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        extensions: <ThemeExtension<dynamic>>[
          FushiGlassTheme(FushiGlassMaterial.off, glassDesign: apple),
        ],
      ).copyWith(platform: TargetPlatform.android),
      themeAnimationDuration: Duration.zero,
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) {
            hostContext = context;
            return const SizedBox.expand();
          },
        ),
      ),
    ),
  );
  return hostContext;
}

Future<Size> _dialogSize(
  WidgetTester tester, {
  required Size screen,
  required Widget dialog,
  required Finder surface,
  bool apple = false,
}) async {
  final BuildContext context = await _pumpHost(
    tester,
    size: screen,
    apple: apple,
  );
  showDialog<void>(context: context, builder: (_) => dialog);
  await tester.pumpAndSettle();
  final Size size = tester.getSize(surface);
  Navigator.of(context, rootNavigator: true).pop();
  await tester.pumpAndSettle();
  return size;
}

/// Material [Dialog] 自身铺满屏幕（外边距在它内部），面板是它里面的第一个 [Material]。
final Finder _dialogSurface = find
    .descendant(of: find.byType(Dialog), matching: find.byType(Material))
    .first;

void main() {
  group('policy (pure)', () {
    test('only a wide-and-short window counts as compact landscape', () {
      expect(isFushiCompactLandscape(_phoneLandscape), isTrue);
      expect(isFushiCompactLandscape(_phonePortrait), isFalse);
      expect(isFushiCompactLandscape(const Size(1600, 900)), isFalse);
      expect(isFushiCompactLandscape(const Size(400, 400)), isFalse);
      // 近方形小窗（桌面最小窗口）两侧没有空地，不算横屏。
      expect(isFushiCompactLandscape(const Size(360, 320)), isFalse);
    });

    test('insets only shrink, and only in compact landscape', () {
      const EdgeInsets base = EdgeInsets.symmetric(
        horizontal: 40,
        vertical: 24,
      );
      expect(
        fushiCompactLandscapeInset(_phoneLandscape, base),
        const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      );
      expect(fushiCompactLandscapeInset(_phonePortrait, base), base);
      expect(
        fushiCompactLandscapeInset(_phoneLandscape, const EdgeInsets.all(4)),
        const EdgeInsets.all(4),
      );
    });

    test('max width only widens; height fraction lifts to 1', () {
      expect(fushiCompactLandscapeMaxWidth(_phoneLandscape, 420), 720);
      expect(fushiCompactLandscapeMaxWidth(_phoneLandscape, 900), 900);
      expect(fushiCompactLandscapeMaxWidth(_phonePortrait, 420), 420);
      expect(fushiCompactLandscapeHeightFraction(_phoneLandscape, 0.82), 1.0);
      expect(fushiCompactLandscapeHeightFraction(_phonePortrait, 0.82), 0.82);
    });
  });

  group('MD3 AlertDialog (FushiAlertDialog)', () {
    final Finder surface = _dialogSurface;

    testWidgets('landscape phone: long content widens past 560', (
      WidgetTester tester,
    ) async {
      final Size landscape = await _dialogSize(
        tester,
        screen: _phoneLandscape,
        dialog: const FushiAlertDialog(
          title: Text('T'),
          content: Text(_longText),
        ),
        surface: surface,
      );
      expect(landscape.width, greaterThan(560));
      expect(landscape.width, lessThanOrEqualTo(720));
    });

    testWidgets('desktop: still capped at the MD3 560 spec', (
      WidgetTester tester,
    ) async {
      final Size desktop = await _dialogSize(
        tester,
        screen: const Size(1600, 900),
        dialog: const FushiAlertDialog(
          title: Text('T'),
          content: Text(_longText),
        ),
        surface: surface,
      );
      expect(desktop.width, 560);
    });

    testWidgets('landscape phone: vertical inset shrinks to 8', (
      WidgetTester tester,
    ) async {
      final BuildContext context = await _pumpHost(
        tester,
        size: _phoneLandscape,
      );
      showDialog<void>(
        context: context,
        builder: (_) => const FushiAlertDialog(
          title: Text('T'),
          content: SizedBox(height: 2000, child: Text(_longText)),
          scrollable: true,
        ),
      );
      await tester.pumpAndSettle();
      final Rect rect = tester.getRect(surface);
      expect(rect.top, 8);
      expect(rect.bottom, _phoneLandscape.height - 8);
    });
  });

  group('FushiDialogFrame', () {
    Future<Size> frameSize(WidgetTester tester, Size screen) async {
      final BuildContext context = await _pumpHost(tester, size: screen);
      showDialog<void>(
        context: context,
        builder: (_) => FushiDialogFrame(
          child: Container(
            key: const ValueKey<String>('frame-body'),
            height: 2000,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final Size size = tester.getSize(_dialogSurface);
      Navigator.of(context, rootNavigator: true).pop();
      await tester.pumpAndSettle();
      return size;
    }

    testWidgets('landscape phone: wider than 420, nearly full height', (
      WidgetTester tester,
    ) async {
      final Size size = await frameSize(tester, _phoneLandscape);
      expect(size.width, 720);
      // 旧：min(407 × 0.82, 407 − 48) ≈ 334。
      expect(size.height, _phoneLandscape.height - 16);
    });

    testWidgets('portrait phone: unchanged (420 × 0.82 cap)', (
      WidgetTester tester,
    ) async {
      final Size size = await frameSize(tester, _phonePortrait);
      expect(size.width, lessThanOrEqualTo(420));
      expect(size.height, closeTo(_phonePortrait.height * 0.82, 0.01));
    });
  });

  group('Apple design', () {
    testWidgets('text-only alert keeps the fixed iOS width in landscape', (
      WidgetTester tester,
    ) async {
      final Size size = await _dialogSize(
        tester,
        screen: _phoneLandscape,
        apple: true,
        dialog: FushiAlertDialog(
          title: const Text('T'),
          content: const Text(_longText),
          actions: <Widget>[
            TextButton(onPressed: () {}, child: const Text('OK')),
          ],
        ),
        surface: find.byType(FushiAppleDialogPanel),
      );
      expect(size.width, lessThanOrEqualTo(300));
    });
  });

  group('wide floating sheet', () {
    testWidgets('landscape phone: wider than 640 and not capped at 86%', (
      WidgetTester tester,
    ) async {
      final BuildContext context = await _pumpHost(
        tester,
        size: _phoneLandscape,
      );
      adaptiveModalSheet<void>(
        context: context,
        builder: (_) => const SizedBox(width: 2000, height: 2000),
      );
      await tester.pumpAndSettle();
      final Finder panel = find
          .descendant(
            of: find.byType(FushiM3eFloatingSheet),
            matching: find.byType(Material),
          )
          .first;
      final Size size = tester.getSize(panel);
      expect(size.width, 720);
      expect(size.height, _phoneLandscape.height - 16);
    });
  });

  // 横屏巡检 2026-11-26：横屏手机宽 ~900 落进 expanded 档，外壳按宽取档就给了
  // 桌面的 84 号页名和展开侧栏，页头吃掉三分之一高、侧栏吃掉四分之一宽。
  group('shell chrome on a landscape phone', () {
    testWidgets('MD3 page title takes the phone tier', (
      WidgetTester tester,
    ) async {
      BuildContext context = await _pumpHost(tester, size: _phoneLandscape);
      expect(isFushiCompactLandscapeWindow(context), isTrue);
      expect(FushiPageTitleMetrics.isCompact(context), isTrue);

      context = await _pumpHost(tester, size: const Size(1280, 800));
      expect(isFushiCompactLandscapeWindow(context), isFalse);
      expect(FushiPageTitleMetrics.isCompact(context), isFalse);
    });

    testWidgets('Apple keeps its single-row inline title', (
      WidgetTester tester,
    ) async {
      // Apple 的手机档是「导航行 + 大标题行」两行；iPhone 横屏本就是内联标题。
      final BuildContext context = await _pumpHost(
        tester,
        size: _phoneLandscape,
        apple: true,
      );
      expect(FushiPageTitleMetrics.isCompact(context), isFalse);
    });

    testWidgets('nav rail defaults to collapsed, user choice still wins', (
      WidgetTester tester,
    ) async {
      BuildContext context = await _pumpHost(tester, size: _phoneLandscape);
      expect(
        adaptiveNavRailExtended(context, sizeClass: WindowSizeClass.expanded),
        isFalse,
      );
      expect(
        adaptiveNavRailExtended(
          context,
          sizeClass: WindowSizeClass.expanded,
          userExpanded: true,
        ),
        isTrue,
      );

      context = await _pumpHost(tester, size: const Size(1280, 800));
      expect(
        adaptiveNavRailExtended(context, sizeClass: WindowSizeClass.expanded),
        isTrue,
      );
    });
  });
}
